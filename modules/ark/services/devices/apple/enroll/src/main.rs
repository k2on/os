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
