//! Phone sign-in: the phone gets an access token from Kanidm (public client
//! `sivrad`, PKCE) and presents it as a bearer token. We check it by asking
//! the client's userinfo endpoint who it belongs to, and remember positive
//! answers for five minutes. Verifying the JWT locally against the issuer's
//! JWKS (and its audience) would save the round trip; that is a follow-up.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::Value;

const CACHE_TTL: Duration = Duration::from_secs(5 * 60);

#[derive(Debug, PartialEq)]
pub enum AuthError {
    /// The identity provider rejected the token.
    Unauthorized,
    /// No issuer configured.
    NotConfigured,
    /// The identity provider could not be asked.
    Unavailable(String),
}

pub struct Oidc {
    pub issuer: Option<String>,
    pub client_id: Option<String>,
    cache: Mutex<HashMap<[u8; 32], (String, Instant)>>,
}

impl Oidc {
    pub fn new(issuer: Option<String>, client_id: Option<String>) -> Self {
        Oidc {
            issuer: issuer.map(|i| i.trim_end_matches('/').to_owned()),
            client_id,
            cache: Mutex::new(HashMap::new()),
        }
    }

    /// The Kanidm username the token belongs to.
    pub async fn username(&self, token: &str) -> Result<String, AuthError> {
        let key = digest(token);
        if let Some(user) = self.cached(&key, Instant::now()) {
            return Ok(user);
        }
        let issuer = self.issuer.clone().ok_or(AuthError::NotConfigured)?;
        let token = token.to_owned();
        let user = tokio::task::spawn_blocking(move || userinfo(&issuer, &token))
            .await
            .map_err(|e| AuthError::Unavailable(e.to_string()))??;
        self.remember(key, &user, Instant::now());
        Ok(user)
    }

    fn cached(&self, key: &[u8; 32], now: Instant) -> Option<String> {
        let cache = self.cache.lock().unwrap();
        match cache.get(key) {
            Some((user, expires)) if *expires > now => Some(user.clone()),
            _ => None,
        }
    }

    fn remember(&self, key: [u8; 32], user: &str, now: Instant) {
        let mut cache = self.cache.lock().unwrap();
        cache.retain(|_, (_, expires)| *expires > now);
        cache.insert(key, (user.to_owned(), now + CACHE_TTL));
    }
}

/// SHA-256, so the cache never holds a usable token.
fn digest(token: &str) -> [u8; 32] {
    let d = ring::digest::digest(&ring::digest::SHA256, token.as_bytes());
    d.as_ref().try_into().expect("32 bytes")
}

fn userinfo(issuer: &str, token: &str) -> Result<String, AuthError> {
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(10))
        .build();
    let response = agent
        .get(&format!("{issuer}/userinfo"))
        .set("Authorization", &format!("Bearer {token}"))
        .call();
    match response {
        Ok(r) => {
            let claims: Value = r
                .into_json()
                .map_err(|e| AuthError::Unavailable(format!("userinfo: {e}")))?;
            preferred_username(&claims)
                .ok_or_else(|| AuthError::Unavailable("userinfo has no preferred_username".into()))
        }
        Err(ureq::Error::Status(401 | 403, _)) => Err(AuthError::Unauthorized),
        Err(ureq::Error::Status(code, _)) => {
            Err(AuthError::Unavailable(format!("userinfo answered {code}")))
        }
        Err(e) => Err(AuthError::Unavailable(e.to_string())),
    }
}

fn preferred_username(claims: &Value) -> Option<String> {
    claims["preferred_username"]
        .as_str()
        .filter(|u| !u.is_empty())
        .map(str::to_owned)
}

/// The token from an `Authorization: Bearer ...` header value.
pub fn bearer(header: Option<&str>) -> Option<&str> {
    let value = header?.strip_prefix("Bearer ")?.trim();
    (!value.is_empty()).then_some(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn cache_expires() {
        let oidc = Oidc::new(Some("https://id.example.org/".into()), None);
        assert_eq!(oidc.issuer.as_deref(), Some("https://id.example.org"));
        let t0 = Instant::now();
        let key = digest("good");
        assert_eq!(oidc.cached(&key, t0), None);
        oidc.remember(key, "alice", t0);
        assert_eq!(
            oidc.cached(&key, t0 + Duration::from_secs(299)).as_deref(),
            Some("alice")
        );
        assert_eq!(oidc.cached(&key, t0 + CACHE_TTL), None);
        assert_eq!(oidc.cached(&digest("other"), t0), None);
        // expired entries are dropped on the next insert
        oidc.remember(digest("other"), "bob", t0 + CACHE_TTL);
        assert_eq!(oidc.cache.lock().unwrap().len(), 1);
    }

    #[test]
    fn username_claim() {
        assert_eq!(
            preferred_username(&json!({ "preferred_username": "alice" })).as_deref(),
            Some("alice")
        );
        assert_eq!(
            preferred_username(&json!({ "preferred_username": "" })),
            None
        );
        assert_eq!(preferred_username(&json!({ "sub": "x" })), None);
    }

    #[test]
    fn bearer_header() {
        assert_eq!(bearer(Some("Bearer abc")), Some("abc"));
        assert_eq!(bearer(Some("Bearer ")), None);
        assert_eq!(bearer(Some("Basic abc")), None);
        assert_eq!(bearer(None), None);
    }

    #[tokio::test]
    async fn no_issuer_no_entry() {
        let oidc = Oidc::new(None, None);
        assert_eq!(oidc.username("t").await, Err(AuthError::NotConfigured));
    }
}
