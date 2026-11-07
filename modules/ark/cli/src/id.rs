//! `ark id`: your ssh key on a YubiKey. One resident FIDO2 credential that
//! signs commits and logs in everywhere (Kanidm serves it to the hosts, comin
//! trusts commits it signed).
//!
//! Waits for the YubiKey if it is not plugged in and reads the ssh keys
//! resident on it (its PIN). With one, sets up what is missing: the handle
//! and public half at ~/.ssh/id_ed25519_sk[.pub], OpenSSH's own place for an
//! ed25519 security key, so ssh tries it unasked and git signs with it; and
//! the key's line in modules/keys/<name>.pub, the list of your keys, where
//! nix reads them. The handle is useless without the YubiKey, and the YubiKey
//! can always write it again.
//!
//! `ark id new` makes one on a YubiKey that has none, asking for your name
//! and the key's: the name is kept on the YubiKey (the credential's user), so
//! any machine knows whose it is. The key's name is only a label for you
//! (its comment, <name>@<key>, on GitHub and in Kanidm); no path depends on it.
use std::fs;
use std::io::{self, ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

use anyhow::{bail, Context, Result};

use crate::service::Ctx;
use crate::util;

/// OpenSSH's default identity for an ed25519 security key: ssh tries it unasked.
const HANDLE: &str = "id_ed25519_sk";

struct Paths {
    /// Scratch directory for what ssh-keygen writes.
    tmp: PathBuf,
    /// ~/.ssh, where the handle goes as <key>.
    ssh: PathBuf,
}

impl Paths {
    fn new() -> Result<Paths> {
        let ssh = PathBuf::from(std::env::var("HOME").context("HOME is not set")?).join(".ssh");
        Ok(Paths { tmp: ssh.join(".ark-id"), ssh })
    }

    /// Runs `f` with an empty scratch directory, removed after.
    fn scratch<T>(&self, f: impl FnOnce(&Path) -> Result<T>) -> Result<T> {
        if self.tmp.exists() {
            fs::remove_dir_all(&self.tmp)?;
        }
        fs::create_dir_all(&self.tmp)?;
        let result = f(&self.tmp);
        fs::remove_dir_all(&self.tmp)?;
        result
    }
}

/// `ark id`: the id on the YubiKey, set up on this machine and in the repo.
pub fn show(ctx: &Ctx) -> Result<()> {
    let p = Paths::new()?;
    wait_for_yubikey()?;
    // `ssh-keygen -K` writes id_<type>_sk_rk[_<user>] files into the working
    // directory: read them into the scratch one.
    p.scratch(|tmp| match resident_keys(tmp)?.as_slice() {
        [] => {
            eprintln!("No id on key");
            Ok(())
        }
        [one] => install(ctx, one, &owner(one)?, None, &p),
        keys => {
            for k in keys {
                eprintln!("  {}", fs::read_to_string(k.with_extension("pub"))?.trim());
            }
            bail!("the YubiKey holds several ids (above); `ark id` expects one");
        }
    })
}

/// `ark id new`: makes the id on a YubiKey that has none.
pub fn new(ctx: &Ctx) -> Result<()> {
    let p = Paths::new()?;
    wait_for_yubikey()?;
    p.scratch(|tmp| {
        if !resident_keys(tmp)?.is_empty() {
            bail!("the YubiKey has an id already; `ark id` shows it");
        }
        let login = std::env::var("USER").unwrap_or_default();
        let name = ask(ctx, "Your name", &login, "lowercase letters, digits and . _ - only", |s| {
            s.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "._-".contains(c))
        })?;
        let key = ask_key_name(ctx)?;
        let made = create(&tmp.join(HANDLE), &name, &key)?;
        install(ctx, &made, &name, Some(key), &p)
    })
}

/// Waits until a FIDO2 device answers, the way decrypting waits for the
/// yubikey's age identity (crate::service): a USB watch, then retries while
/// the key initialises.
fn wait_for_yubikey() -> Result<()> {
    if fido_devices()? > 0 {
        return Ok(());
    }
    eprint!("Plug in the YubiKey (Ctrl-C to stop)... ");
    io::stderr().flush()?;
    let watch = crate::usb::Watch::new();
    loop {
        match &watch {
            Some(watch) => watch.wait_for_device(),
            None => thread::sleep(Duration::from_secs(1)),
        }
        for _ in 0..25 {
            if fido_devices()? > 0 {
                eprintln!("found it.");
                return Ok(());
            }
            thread::sleep(Duration::from_millis(200));
        }
    }
}

/// How many FIDO2 devices are plugged in: `fido2-token -L`, no PIN needed.
fn fido_devices() -> Result<usize> {
    match Command::new("fido2-token").arg("-L").stderr(Stdio::null()).output() {
        Ok(out) => Ok(String::from_utf8_lossy(&out.stdout).lines().filter(|l| !l.trim().is_empty()).count()),
        Err(e) if e.kind() == ErrorKind::NotFound => {
            bail!("fido2-token is not on PATH; the dev shell (nix develop, or direnv in the repo) has it")
        }
        Err(e) => Err(e).context("running fido2-token"),
    }
}

/// The handles of the ssh keys resident on the YubiKey, written into `dir`.
/// ssh-keygen asks for the PIN on the tty; its messages are kept, to tell "no
/// keys" from a real failure.
fn resident_keys(dir: &Path) -> Result<Vec<PathBuf>> {
    eprintln!("Reading the ssh keys on the YubiKey: enter its PIN, and touch it if it blinks.");
    let out = Command::new("ssh-keygen")
        .args(["-K", "-N", ""])
        .current_dir(dir)
        .stdin(Stdio::inherit())
        .output()
        .context("starting ssh-keygen")?;
    let said = String::from_utf8_lossy(&out.stderr);
    let mut keys: Vec<PathBuf> = fs::read_dir(dir)?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_none() && p.file_name().is_some_and(|n| n.to_string_lossy().contains("_sk_rk")))
        .collect();
    keys.sort();
    if !out.status.success() && keys.is_empty() && !said.contains("No keys") && !said.contains("not found") {
        bail!("ssh-keygen -K failed ({}):\n{}", out.status, said.trim_end());
    }
    Ok(keys)
}

/// Makes a resident ed25519-sk credential on the YubiKey (firmware 5.2.3 or
/// later), with `name` as its user, so any machine reading it back knows whose
/// it is. Its comment is <name>@<key>: the label you know it by.
fn create(path: &Path, name: &str, key: &str) -> Result<PathBuf> {
    eprintln!("Making the key: enter the PIN, then touch the YubiKey.");
    let out = Command::new("ssh-keygen")
        .args(["-t", "ed25519-sk", "-O", "resident", "-O", &format!("user={name}"), "-C", &format!("{name}@{key}")])
        .args(["-N", "", "-q", "-f"])
        .arg(path)
        .stdin(Stdio::inherit())
        .output()
        .context("starting ssh-keygen")?;
    if !out.status.success() {
        let said = String::from_utf8_lossy(&out.stderr);
        if said.contains("not supported") {
            bail!("this YubiKey has no ed25519-sk (firmware before 5.2.3)");
        }
        bail!("ssh-keygen failed ({}):\n{}", out.status, said.trim_end());
    }
    Ok(path.to_path_buf())
}

/// A line from the terminal, `default` when left empty, asked again until
/// `valid` takes it.
fn ask(ctx: &Ctx, label: &str, default: &str, rule: &str, valid: impl Fn(&str) -> bool) -> Result<String> {
    loop {
        let answer = ctx.prompt(&format!("{label} [{default}]"))?;
        let answer = if answer.trim().is_empty() { default.to_string() } else { answer.trim().to_string() };
        if !answer.is_empty() && valid(&answer) {
            return Ok(answer);
        }
        eprintln!("{label}: {rule}.");
    }
}

fn ask_key_name(ctx: &Ctx) -> Result<String> {
    ask(ctx, "Key name", "yubikey", "no spaces or @", |s| !s.chars().any(|c| c.is_whitespace() || c == '@'))
}

/// Whose a resident key is: the user `ark id new` stored with it, which
/// `ssh-keygen -K` puts at the end of the file name (id_<type>_sk_rk_<user>);
/// your login name for a key made without one.
fn owner(handle: &Path) -> Result<String> {
    let file = handle.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    match file.split_once("_sk_rk_") {
        Some((_, user)) if !user.is_empty() => Ok(user.to_string()),
        _ => std::env::var("USER").context("USER is not set"),
    }
}

/// The key without its comment: type and base64, which is what identifies it.
fn key_part(line: &str) -> String {
    line.split_whitespace().take(2).collect::<Vec<_>>().join(" ")
}

/// Adds the key to modules/keys/<name>.pub, the list of your keys, unless it
/// is there already (a key read back off the YubiKey comes without its
/// comment, so the label is asked for then); and puts the handle and public
/// half at ~/.ssh/id_ed25519_sk[.pub], OpenSSH's own place for it, unless they
/// are there. Then says where everything stands.
fn install(ctx: &Ctx, from: &Path, name: &str, key: Option<String>, p: &Paths) -> Result<()> {
    let repo = ctx.root.join("modules/keys").join(format!("{name}.pub"));
    let resident = fs::read_to_string(from.with_extension("pub")).context("reading the public key ssh-keygen wrote")?;
    let ours = key_part(&resident);
    let have = fs::read_to_string(&repo).unwrap_or_default();
    let listed = have.lines().find(|l| key_part(l) == ours).map(|l| l.trim().to_string());

    let line = match listed.clone() {
        Some(line) => line,
        None => {
            let key = match key {
                Some(key) => key,
                None => ask_key_name(ctx)?,
            };
            format!("{ours} {name}@{key}")
        }
    };
    println!("{line}");

    let handle = p.ssh.join(HANDLE);
    let public = handle.with_extension("pub");
    if handle.exists() {
        let there = util::run(Command::new("ssh-keygen").arg("-y").arg("-f").arg(&handle), "ssh-keygen -y")?;
        if key_part(&there) != ours {
            bail!("{} holds another key; move it away and run `ark id` again", handle.display());
        }
        eprintln!("{}: already here.", handle.display());
    } else {
        fs::rename(from, &handle)?;
        eprintln!("{}: written.", handle.display());
    }
    if fs::read_to_string(&public).map(|have| key_part(&have) != ours).unwrap_or(true) {
        fs::write(&public, format!("{line}\n"))?;
        eprintln!("{}: written.", public.display());
    }

    let shown = repo.strip_prefix(&ctx.root).unwrap_or(&repo).display().to_string();
    if listed.is_some() {
        eprintln!("{shown}: lists it already.");
    } else {
        fs::create_dir_all(repo.parent().expect("has a parent"))?;
        let mut all = have.trim_end().to_string();
        if !all.is_empty() {
            all.push('\n');
        }
        fs::write(&repo, format!("{all}{line}\n"))?;
        util::run(Command::new("git").arg("-C").arg(&ctx.root).arg("add").arg(&repo), "git add")?;
        eprintln!("{shown}: added it.");
        eprintln!("Next: `just rebuild`, then add it to GitHub and Gitea as a signing key.");
    }
    Ok(())
}
