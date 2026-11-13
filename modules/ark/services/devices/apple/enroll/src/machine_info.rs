//! The MachineInfo a device sends from Setup Assistant: a plist (UDID,
//! SERIAL, PRODUCT, VERSION, ...) in a CMS signature by the device. openssl
//! takes it out of the signature, which also checks the signature against
//! the certificate in it (not that Apple issued that certificate: see
//! main.rs).
use std::io::Write;
use std::process::{Command, Stdio};

use crate::Result;

/// The plist inside a DER-encoded CMS SignedData.
pub fn unwrap(body: &[u8]) -> Result<String> {
    let mut child = Command::new("openssl")
        .args(["cms", "-verify", "-noverify", "-inform", "DER"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("running openssl: {e}"))?;
    child.stdin.take().expect("piped").write_all(body)?;
    let out = child.wait_with_output()?;
    if !out.status.success() {
        return Err(format!("not a signed MachineInfo: {}", String::from_utf8_lossy(&out.stderr).trim()).into());
    }
    Ok(String::from_utf8(out.stdout)?)
}

/// The string under `key` in a flat plist dict, as Apple's XML writes it.
pub fn string(plist: &str, key: &str) -> Option<String> {
    let tag = format!("<key>{key}</key>");
    let rest = &plist[plist.find(&tag)? + tag.len()..];
    let rest = rest.trim_start().strip_prefix("<string>")?;
    let value = &rest[..rest.find("</string>")?];
    Some(value.trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const INFO: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>PRODUCT</key>
	<string>iPhone16,1</string>
	<key>SERIAL</key>
	<string>KN2QHVKC9J</string>
	<key>UDID</key>
	<string>00008130-00064C5E0003401C</string>
</dict>
</plist>"#;

    #[test]
    fn reads_keys() {
        assert_eq!(string(INFO, "SERIAL").as_deref(), Some("KN2QHVKC9J"));
        assert_eq!(string(INFO, "PRODUCT").as_deref(), Some("iPhone16,1"));
        assert_eq!(string(INFO, "LANGUAGE"), None);
    }

    #[test]
    fn key_without_string_is_none() {
        assert_eq!(string("<key>SERIAL</key><integer>1</integer>", "SERIAL"), None);
    }
}
