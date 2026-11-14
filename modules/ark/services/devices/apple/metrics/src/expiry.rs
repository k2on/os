//! When the three things Apple makes us renew yearly expire, as Unix
//! seconds: the MDM push certificate (its notAfter, via openssl), the ABM
//! token (NanoDEP keeps its expiry with it) and the Apps and Books content
//! token (the .vpptoken is base64 JSON with its expDate).
use std::path::Path;
use std::process::Command;

use serde_json::Value;

use crate::{base64, time, Config, Result};

pub fn push_certificate(path: &Path) -> Result<i64> {
    let out = Command::new("openssl")
        .args(["x509", "-noout", "-enddate", "-dateopt", "iso_8601", "-in"])
        .arg(path)
        .output()
        .map_err(|e| format!("running openssl: {e}"))?;
    let text = String::from_utf8(out.stdout)?;
    let date = text.trim().strip_prefix("notAfter=").ok_or("no notAfter")?;
    Ok(time::parse(date).ok_or_else(|| format!("unreadable notAfter {date:?}"))?)
}

pub fn vpp_token(path: &Path) -> Result<i64> {
    let text = std::fs::read_to_string(path)?;
    vpp_token_expiry(&text)
}

pub fn vpp_token_expiry(token: &str) -> Result<i64> {
    let json = base64::decode(token.trim()).ok_or("the content token isn't base64")?;
    let v: Value = serde_json::from_slice(&json)?;
    let date = v.get("expDate").and_then(Value::as_str).ok_or("no expDate in the content token")?;
    Ok(time::parse(date).ok_or_else(|| format!("unreadable expDate {date:?}"))?)
}

pub fn abm_token(config: &Config, name: &str) -> Result<i64> {
    let (Some(url), Some(key)) = (&config.depserver, &config.depserver_key) else {
        return Err("no depserver".into());
    };
    let key = std::fs::read_to_string(key)?;
    let v: Value = ureq::get(&format!("{url}/v1/tokens/{name}"))
        .set("Authorization", &format!("Basic {}", base64::encode(format!("depserver:{}", key.trim()).as_bytes())))
        .call()?
        .into_json()?;
    let date = v.get("access_token_expiry").and_then(Value::as_str).ok_or("no access_token_expiry")?;
    Ok(time::parse(date).ok_or_else(|| format!("unreadable access_token_expiry {date:?}"))?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn content_token() {
        let token = base64::encode(br#"{"token":"x","expDate":"2027-11-13T13:43:06-0600","orgName":"KoonFamily"}"#);
        assert_eq!(vpp_token_expiry(&token).unwrap(), time::parse("2027-11-13T19:43:06Z").unwrap());
        assert!(vpp_token_expiry("not json").is_err());
    }
}
