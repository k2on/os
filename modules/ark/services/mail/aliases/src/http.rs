//! Two listeners on one database.
//!
//! Public (behind nginx at alias.<domain>), what Bitwarden's addy.io
//! forwarder calls, with a person's token:
//!
//!   POST /api/v1/aliases  {"domain": ..., "description": ...}
//!     -> 201 {"data": {"email": ..., ...}}
//!
//! Internal (the tailnet only), with the internal key, for pass-vaults on
//! adam and for `ark service mail`:
//!
//!   GET  /aliases                  every alias
//!   PUT  /aliases/<address>        {"active": bool}
//!   PUT  /targets                  {"groups": {"<group>": [addresses in its vault]}}
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::convert::Infallible;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use http_body_util::{BodyExt, Full, Limited};
use hyper::body::{Bytes, Incoming};
use hyper::header::{HeaderValue, AUTHORIZATION, CONTENT_TYPE};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::net::TcpListener;

use crate::db::Db;
use crate::names;

pub struct State {
    pub db: Mutex<Db>,
    pub domain: String,
    /// People's and groups' own addresses, which no alias may take.
    pub taken: BTreeSet<String>,
    /// The configured groups, the only ones an alias may move to.
    pub groups: BTreeSet<String>,
    /// Touched on every change; Stalwart restarts on it.
    pub changed_file: PathBuf,
    /// (token, person)
    pub tokens: Vec<(String, String)>,
    pub internal_key: String,
}

type Reply = Response<Full<Bytes>>;

pub async fn serve(state: Arc<State>, listen: &str, internal: bool) -> std::io::Result<()> {
    let listener = TcpListener::bind(listen).await?;
    eprintln!("mail-aliases: {} on {}", if internal { "internal" } else { "public" }, listener.local_addr()?);
    loop {
        let stream = match listener.accept().await {
            Ok((stream, _)) => stream,
            Err(e) => {
                eprintln!("mail-aliases: accept: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            }
        };
        let state = state.clone();
        tokio::spawn(async move {
            let service = service_fn(move |req| {
                let state = state.clone();
                async move {
                    Ok::<_, Infallible>(if internal { internal_route(&state, req).await } else { public_route(&state, req).await })
                }
            });
            let _ = http1::Builder::new().serve_connection(TokioIo::new(stream), service).await;
        });
    }
}

fn reply(status: StatusCode, body: Value) -> Reply {
    let mut response = Response::new(Full::new(Bytes::from(body.to_string())));
    *response.status_mut() = status;
    let headers = response.headers_mut();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    // Bitwarden's web vault calls from a page; the token is the protection.
    headers.insert("access-control-allow-origin", HeaderValue::from_static("*"));
    headers.insert("access-control-allow-headers", HeaderValue::from_static("authorization, content-type, accept"));
    headers.insert("access-control-allow-methods", HeaderValue::from_static("POST, OPTIONS"));
    response
}

/// Says an alias changed, for Stalwart to pick it up.
fn changed(state: &State) {
    if let Err(e) = std::fs::write(&state.changed_file, names::random(8)) {
        eprintln!("mail-aliases: writing {}: {e}", state.changed_file.display());
    }
}

fn error(status: StatusCode, message: &str) -> Reply {
    reply(status, json!({ "message": message }))
}

/// Comparing secrets without telling how much of them matched.
fn same(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn bearer(req: &Request<Incoming>) -> Option<String> {
    let value = req.headers().get(AUTHORIZATION)?.to_str().ok()?;
    Some(value.strip_prefix("Bearer ")?.trim().to_string())
}

async fn body<T: for<'a> Deserialize<'a>>(req: Request<Incoming>) -> Result<T, Reply> {
    let bytes = Limited::new(req.into_body(), 64 * 1024)
        .collect()
        .await
        .map_err(|_| error(StatusCode::PAYLOAD_TOO_LARGE, "too large"))?
        .to_bytes();
    serde_json::from_slice(&bytes).map_err(|e| error(StatusCode::UNPROCESSABLE_ENTITY, &format!("bad request: {e}")))
}

#[derive(Deserialize)]
struct NewAlias {
    domain: String,
    #[serde(default)]
    description: String,
}

async fn public_route(state: &State, req: Request<Incoming>) -> Reply {
    if req.method() == Method::OPTIONS {
        return reply(StatusCode::NO_CONTENT, Value::Null);
    }
    if req.method() != Method::POST || req.uri().path() != "/api/v1/aliases" {
        return error(StatusCode::NOT_FOUND, "not found");
    }
    let token = bearer(&req).unwrap_or_default();
    let Some(person) = state.tokens.iter().find(|(t, _)| same(t, &token)).map(|(_, p)| p.clone()) else {
        return error(StatusCode::UNAUTHORIZED, "unknown token");
    };
    let new: NewAlias = match body(req).await {
        Ok(new) => new,
        Err(reply) => return reply,
    };
    if !new.domain.eq_ignore_ascii_case(&state.domain) {
        return error(StatusCode::UNPROCESSABLE_ENTITY, &format!("aliases are at {}", state.domain));
    }
    let site = names::site(&new.description);
    let created = state.db.lock().unwrap().create(&person, &state.domain, site.as_deref(), &state.taken);
    match created {
        Ok(email) => {
            eprintln!("mail-aliases: {person} made {email}");
            changed(state);
            let (local_part, domain) = email.split_once('@').unwrap_or((&email, ""));
            reply(
                StatusCode::CREATED,
                json!({ "data": {
                    "id": email, "email": email, "local_part": local_part, "domain": domain,
                    "description": new.description, "active": true,
                }}),
            )
        }
        Err(e) => error(StatusCode::INTERNAL_SERVER_ERROR, &e.to_string()),
    }
}

#[derive(Deserialize)]
struct Active {
    active: bool,
}

#[derive(Deserialize)]
struct Targets {
    groups: BTreeMap<String, Vec<String>>,
}

async fn internal_route(state: &State, req: Request<Incoming>) -> Reply {
    if !bearer(&req).is_some_and(|key| same(&key, &state.internal_key)) {
        return error(StatusCode::UNAUTHORIZED, "unknown key");
    }
    let path = req.uri().path().to_string();
    let result = match (req.method().clone(), path.as_str()) {
        (Method::GET, "/aliases") => state.db.lock().unwrap().list().map(|list| json!(list)),
        (Method::PUT, "/targets") => {
            let targets: Targets = match body(req).await {
                Ok(t) => t,
                Err(reply) => return reply,
            };
            state.db.lock().unwrap().retarget(&targets.groups, &state.groups).map(|moved| {
                for m in &moved {
                    eprintln!("mail-aliases: {} now goes to {} (was {})", m.address, m.to, m.from);
                }
                if !moved.is_empty() {
                    changed(state);
                }
                json!({ "moved": moved })
            })
        }
        (Method::PUT, p) if p.starts_with("/aliases/") => {
            let address = p["/aliases/".len()..].replace("%40", "@");
            let active: Active = match body(req).await {
                Ok(a) => a,
                Err(reply) => return reply,
            };
            match state.db.lock().unwrap().set_active(&address, active.active) {
                Ok(true) => {
                    eprintln!("mail-aliases: {address} turned {}", if active.active { "on" } else { "off" });
                    changed(state);
                    Ok(json!({ "address": address, "active": active.active }))
                }
                Ok(false) => return error(StatusCode::NOT_FOUND, &format!("no alias {address}")),
                Err(e) => Err(e),
            }
        }
        _ => return error(StatusCode::NOT_FOUND, "not found"),
    };
    match result {
        Ok(body) => reply(StatusCode::OK, body),
        Err(e) => error(StatusCode::INTERNAL_SERVER_ERROR, &e.to_string()),
    }
}
