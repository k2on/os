//! `ark-dav … | ark-thunderbird <config.json>`: readies a Thunderbird
//! profile before it starts (a launcher runs it, then Thunderbird).
//!
//! - Passwords: each login in the config, from its file, into logins.json
//!   (./logins.rs, ./nss.rs), whenever the file's differs from the saved
//!   one: a changed secret reaches Thunderbird at its next start.
//! - Calendars: every calendar ark-dav found on stdin, into prefs.js
//!   (./prefs.rs), so the groups' calendars appear and go without a list.
//!   With nothing on stdin (Radicale didn't answer), the calendars stay as
//!   they were, and Radicale's password is still brought up to date.
//!
//! The config (written by Nix):
//!
//!   {"profile": "/home/max/.thunderbird/default",
//!    "logins": [{"origins": ["imap://mail…", "smtp://mail…"],
//!                "user": "max", "passwordFile": "/run/secrets/…"}],
//!    "dav": {"origin": "https://radicale…", "user": "max",
//!            "passwordFile": "/run/secrets/…"}}
//!
//! Never stops Thunderbird starting: it says what it couldn't do and exits 0.
//! Does nothing while Thunderbird runs, which would write over it.
mod logins;
mod nss;
mod prefs;

use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use serde_json::Value;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Config {
    profile: PathBuf,
    #[serde(default)]
    logins: Vec<Logins>,
    dav: Option<Dav>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Logins {
    origins: Vec<String>,
    user: String,
    password_file: PathBuf,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Dav {
    origin: String,
    user: String,
    password_file: PathBuf,
}

/// ark-dav's output.
#[derive(Deserialize)]
struct Found {
    realm: Option<String>,
    collections: Vec<Collection>,
}

#[derive(Deserialize)]
struct Collection {
    url: String,
    kind: String,
    name: String,
    color: Option<String>,
}

fn main() {
    let Some(path) = std::env::args().nth(1) else {
        eprintln!("usage: ark-dav … | ark-thunderbird <config.json>");
        std::process::exit(2);
    };
    if let Err(e) = run(Path::new(&path)) {
        eprintln!("ark-thunderbird: {e}");
    }
}

fn run(path: &Path) -> Result<(), String> {
    let config: Config = serde_json::from_str(&read(path)?).map_err(|e| format!("{}: {e}", path.display()))?;
    let profile = &config.profile;
    if running(profile) {
        eprintln!("ark-thunderbird: Thunderbird is running; leaving its profile be");
        return Ok(());
    }
    std::fs::create_dir_all(profile).map_err(|e| format!("{}: {e}", profile.display()))?;

    let mut stdin = String::new();
    let _ = std::io::stdin().read_to_string(&mut stdin);
    let found: Option<Found> = (!stdin.trim().is_empty())
        .then(|| serde_json::from_str(&stdin))
        .transpose()
        .map_err(|e| format!("reading ark-dav's answer: {e}"))?;

    if let (Some(found), Some(dav)) = (&found, &config.dav) {
        calendars(profile, found, &dav.user)?;
    }
    passwords(profile, &config, found.as_ref().and_then(|f| f.realm.as_deref()))
}

fn calendars(profile: &Path, found: &Found, user: &str) -> Result<(), String> {
    let file = profile.join("prefs.js");
    let before = std::fs::read_to_string(&file).unwrap_or_default();
    let calendars: Vec<prefs::Calendar> = found
        .collections
        .iter()
        .filter(|c| c.kind == "calendar")
        .map(|c| prefs::Calendar {
            url: &c.url,
            name: &c.name,
            color: c.color.as_deref(),
        })
        .collect();
    let (after, changed) = prefs::with_calendars(&before, &calendars, user);
    if changed {
        write(&file, &after)?;
    }
    Ok(())
}

fn passwords(profile: &Path, config: &Config, realm: Option<&str>) -> Result<(), String> {
    // Every login, with its password and where it's filed.
    let mut wanted: Vec<(String, Option<String>, String, String)> = Vec::new();
    for l in &config.logins {
        let password = secret(&l.password_file)?;
        for origin in &l.origins {
            wanted.push((origin.clone(), Some(origin.clone()), l.user.clone(), password.clone()));
        }
    }
    if let Some(d) = &config.dav {
        let password = secret(&d.password_file)?;
        wanted.push((d.origin.clone(), realm.map(str::to_string), d.user.clone(), password));
    }
    if wanted.is_empty() {
        return Ok(());
    }

    let file = profile.join("logins.json");
    let mut store: Value = match std::fs::read_to_string(&file) {
        Ok(text) => serde_json::from_str(&text).map_err(|e| format!("{}: {e}", file.display()))?,
        Err(_) => logins::empty(),
    };
    let nss = nss::Nss::open(profile)?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as i64);
    let mut changed = false;
    for (origin, realm, user, password) in &wanted {
        let login = logins::Login {
            origin,
            realm: realm.as_deref(),
            user,
            password,
        };
        match logins::seed(&mut store, &nss, &login, now, guid)? {
            logins::Outcome::Current => {}
            logins::Outcome::Changed | logins::Outcome::Added => changed = true,
            logins::Outcome::Skipped => {
                eprintln!("ark-thunderbird: {origin} didn't answer; its password waits for the next start");
            }
        }
    }
    drop(nss);
    if changed {
        write(&file, &serde_json::to_string(&store).expect("plain data"))?;
    }
    Ok(())
}

/// Whether a Thunderbird holds the profile: its `lock` link names
/// `<address>:+<pid>`, of a process that's still there.
fn running(profile: &Path) -> bool {
    let Ok(target) = std::fs::read_link(profile.join("lock")) else {
        return false;
    };
    let target = target.to_string_lossy();
    match target.rsplit_once('+') {
        Some((_, pid)) if pid.chars().all(|c| c.is_ascii_digit()) => {
            Path::new("/proc").join(pid).exists()
        }
        _ => true,
    }
}

fn read(path: &Path) -> Result<String, String> {
    std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))
}

/// A password file's contents, without its final newline.
fn secret(path: &Path) -> Result<String, String> {
    Ok(read(path)?.trim_end_matches(['\r', '\n']).to_string())
}

/// Written aside, private, and moved in place: Thunderbird never reads half.
fn write(file: &Path, text: &str) -> Result<(), String> {
    use std::os::unix::fs::OpenOptionsExt;
    let tmp = file.with_extension("ark-tmp");
    let fail = |e: std::io::Error| format!("{}: {e}", file.display());
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)
        .map_err(fail)?;
    std::io::Write::write_all(&mut f, text.as_bytes()).map_err(fail)?;
    std::fs::rename(&tmp, file).map_err(fail)
}

/// A new entry's id, `{8-4-4-4-12}` hex from the kernel's randomness.
fn guid() -> String {
    let mut b = [0u8; 16];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = f.read_exact(&mut b);
    }
    b[6] = b[6] & 0x0f | 0x40;
    b[8] = b[8] & 0x3f | 0x80;
    let h: String = b.iter().map(|x| format!("{x:02x}")).collect();
    format!("{{{}-{}-{}-{}-{}}}", &h[..8], &h[8..12], &h[12..16], &h[16..20], &h[20..])
}
