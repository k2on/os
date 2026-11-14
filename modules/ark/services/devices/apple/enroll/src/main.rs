//! apple-enroll: the enrollment URL of the household's ADE profile
//! (../default.nix), behind nginx at apple.devices.<mainDomain>/enroll.
//!
//!   apple-enroll <listen> <profile> <serials>
//!
//! In Setup Assistant a device enrolled in Apple Business Manager POSTs its
//! MachineInfo, a plist signed by the device (machine_info.rs), and wants
//! the enrollment profile back. That profile carries the SCEP challenge, so
//! it goes only to a serial number in <serials> (one per line, read on
//! every request, so a deploy changes it without a restart); anyone else
//! gets 403. <profile> is nanohub's built profile, also read each time.
//!
//! The device's signature is checked for integrity but not chained to
//! Apple, so the serial number is what admits a device: someone who knew
//! one could get the profile, and with it an MDM enrollment of their own,
//! no further.
//!
//! Not by address: the device itself makes this request, from whatever
//! network it is on (Apple's servers only give it the URL), and through
//! the vps's TLS passthrough every request reaches ark from the vps anyway.
//!
//! To chain it to Apple, later: Apple says MachineInfo "is CMS-signed with
//! the device identity certificate. The system includes the device's
//! certificate and all necessary intermediate certificates. The
//! certificate chain should validate against the Apple Root CA"
//! (developer.apple.com/documentation/devicemanagement/machineinfo). So
//! only the root is needed: Apple Root CA,
//! https://www.apple.com/appleca/AppleIncRootCertificate.cer, SHA-256
//! B0:B1:73:0E:CB:C7:FF:45:05:14:2C:49:F1:29:5E:6E:DA:6B:CA:ED:7E:2C:68:C5:BE:91:B5:A1:10:01:F0:24.
//! Two things refuse every real device unless allowed for, as
//! github.com/korylprince/dep-webview-oidc (header/header.go) does:
//!   - the device's chain is expired (Apple's guidance is not to check its
//!     dates): `openssl cms -verify -no_check_time`;
//!   - it is SHA-1 with RSA, which OpenSSL 3 refuses by default:
//!     `-auth_level 0`.
//! With `-CAfile <root> -purpose any` in place of `-noverify`. Mirror both
//! in the check (a stand-in root, an expired SHA-1 intermediate), and log
//! for a while before refusing, until a real enrollment shows "verified".
use std::collections::HashSet;
use std::path::PathBuf;

mod http;
mod machine_info;

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

pub struct Config {
    pub profile: PathBuf,
    pub serials: PathBuf,
}

impl Config {
    fn allowed(&self) -> Result<HashSet<String>> {
        let text = std::fs::read_to_string(&self.serials)
            .map_err(|e| format!("reading {}: {e}", self.serials.display()))?;
        Ok(parse_serials(&text))
    }
}

/// One serial per line; blank lines and `#` comments ignored, case folded.
pub fn parse_serials(text: &str) -> HashSet<String> {
    text.lines()
        .map(|l| l.split('#').next().unwrap_or("").trim().to_ascii_uppercase())
        .filter(|l| !l.is_empty())
        .collect()
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [listen, profile, serials] = args.as_slice() else {
        eprintln!("usage: apple-enroll <listen> <profile> <serials>");
        std::process::exit(2);
    };
    let config = Config {
        profile: profile.into(),
        serials: serials.into(),
    };
    if let Err(e) = http::serve(listen, config) {
        eprintln!("apple-enroll: {e}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serials_ignore_blanks_and_comments() {
        let s = parse_serials("KN2QHVKC9J\n\n  abc123  # the iPad\n# nobody\n");
        assert_eq!(s.len(), 2);
        assert!(s.contains("KN2QHVKC9J"));
        assert!(s.contains("ABC123"));
    }
}
