//! What a service's cli/mod.rs registers, and the context its commands get.
use std::cell::{OnceCell, RefCell};
use std::collections::BTreeMap;
use std::io::{self, BufRead, ErrorKind, Write};
use std::path::PathBuf;
use std::process::Command;
use std::thread;
use std::time::Duration;

use anyhow::{bail, Context, Result};

/// A service's entry in the CLI: `pub static SERVICE: Service` in its cli/mod.rs.
pub struct Service {
    pub name: &'static str,
    pub about: &'static str,
    /// The clap command for `ark service <name>`, with the service's
    /// subcommands and their arguments. Its name and about are filled in from
    /// the fields above.
    pub command: fn() -> clap::Command,
    /// Runs whatever `command` matched.
    pub run: fn(&Ctx, &clap::ArgMatches) -> Result<()>,
}

/// The repository the command runs against, plus terminal helpers.
pub struct Ctx {
    /// Checkout root (where flake.nix is); nix is always run from here.
    pub root: PathBuf,
    /// The age identity for decrypting, once it has been asked for:
    /// Some(key) to put in SOPS_AGE_KEY, None when the environment already
    /// carries one.
    age_key: OnceCell<Option<String>>,
    /// Plaintext of the sops files decrypted (or written) during this run,
    /// by file name: each file costs one yubikey touch, so it is paid once.
    pub decrypted: RefCell<BTreeMap<String, serde_json::Map<String, serde_json::Value>>>,
}

impl Ctx {
    pub fn discover() -> Result<Ctx> {
        let top = Command::new("git").args(["rev-parse", "--show-toplevel"]).output();
        let root = match top {
            Ok(out) if out.status.success() => PathBuf::from(String::from_utf8_lossy(&out.stdout).trim()),
            _ => std::env::current_dir()?,
        };
        if !root.join("flake.nix").is_file() {
            bail!("run ark from inside the os repository (no flake.nix in {})", root.display());
        }
        Ok(Ctx { root, age_key: OnceCell::new(), decrypted: RefCell::new(BTreeMap::new()) })
    }

    /// `nix eval --json .?submodules=1#<attr>`, parsed. The secrets submodule is
    /// a module root, so the flake is only complete with `?submodules=1`.
    pub fn nix_eval(&self, attr: &str) -> Result<serde_json::Value> {
        let out = crate::util::run(
            Command::new("nix")
                .args(["eval", "--json", &format!(".?submodules=1#{attr}")])
                .current_dir(&self.root),
            &format!("nix eval {attr}"),
        )?;
        serde_json::from_str(&out).with_context(|| format!("reading the output of nix eval {attr}"))
    }

    /// `git <args>` in the secrets submodule, which is its own repository;
    /// paths are relative to secrets/. Output goes to the terminal.
    pub fn git_secrets(&self, args: &[&str]) -> Result<()> {
        crate::util::status(Command::new("git").args(args).current_dir(self.root.join("secrets")), "git (secrets)")
    }

    /// `sops` able to decrypt: with the age identity in its environment. The
    /// identity is the yubikey's, waited for (once per run) until the key is
    /// plugged in, unless SOPS_AGE_KEY or SOPS_AGE_KEY_FILE is already set.
    /// Encrypting needs none of this, so plain `Command::new("sops")` is right
    /// for that and never waits for the key.
    pub fn sops_decrypting(&self) -> Result<Command> {
        if self.age_key.get().is_none() {
            let key = self.yubikey_identity()?;
            let _ = self.age_key.set(key);
        }
        let mut cmd = Command::new("sops");
        if let Some(Some(key)) = self.age_key.get() {
            cmd.env("SOPS_AGE_KEY", key);
        }
        Ok(cmd)
    }

    /// The yubikey's age identity, waiting for the key to be plugged in if it
    /// is not: a USB watch wakes us the moment a device appears (crate::usb),
    /// then the plugin is retried while the key initialises.
    fn yubikey_identity(&self) -> Result<Option<String>> {
        for var in ["SOPS_AGE_KEY", "SOPS_AGE_KEY_FILE"] {
            if std::env::var_os(var).is_some_and(|v| !v.is_empty()) {
                return Ok(None);
            }
        }
        let (identity, why) = probe_yubikey()?;
        if let Some(identity) = identity {
            return Ok(Some(identity));
        }
        // Unplugged, the plugin exits 0 and prints nothing; anything else is worth showing.
        if why.is_empty() {
            eprint!("The yubikey is needed to decrypt this. Plug it in (Ctrl-C to stop)... ");
        } else {
            eprint!("The yubikey is needed to decrypt this, and none was found ({why}). Waiting (Ctrl-C to stop)... ");
        }
        io::stderr().flush()?;

        let watch = crate::usb::Watch::new();
        loop {
            match &watch {
                Some(watch) => watch.wait_for_device(),
                None => thread::sleep(Duration::from_secs(1)),
            }
            // A freshly plugged key takes a moment to be usable through pcscd.
            for _ in 0..25 {
                if let (Some(identity), _) = probe_yubikey()? {
                    eprintln!("found it.");
                    return Ok(Some(identity));
                }
                thread::sleep(Duration::from_millis(200));
            }
        }
    }

}

/// One try at `age-plugin-yubikey --identity`: the identity if a key answered,
/// plus whatever the plugin said on stderr.
fn probe_yubikey() -> Result<(Option<String>, String)> {
    let out = match Command::new("age-plugin-yubikey").arg("--identity").output() {
        Ok(out) => out,
        Err(e) if e.kind() == ErrorKind::NotFound => {
            bail!("age-plugin-yubikey is not on PATH; the dev shell (nix develop, or direnv in the repo) has it")
        }
        Err(e) => return Err(e).context("running age-plugin-yubikey"),
    };
    let identity = String::from_utf8_lossy(&out.stdout);
    let why = String::from_utf8_lossy(&out.stderr).trim().to_string();
    let found = out.status.success() && identity.contains("AGE-PLUGIN-YUBIKEY-");
    Ok((found.then(|| identity.into_owned()), why))
}

impl Ctx {
    /// One line from the terminal.
    pub fn prompt(&self, label: &str) -> Result<String> {
        eprint!("{label}: ");
        io::stderr().flush()?;
        let mut line = String::new();
        if io::stdin().lock().read_line(&mut line)? == 0 {
            bail!("no more input (stdin closed) while asking for: {label}");
        }
        Ok(line.trim_end_matches(['\n', '\r']).to_string())
    }

    /// One line from the terminal without echo, for secrets. Read from the
    /// tty when there is one; without one (answers piped in) from stdin.
    pub fn prompt_hidden(&self, label: &str) -> Result<String> {
        if let Ok(value) = rpassword::prompt_password(format!("{label}: ")) {
            return Ok(value);
        }
        // Nothing is echoing on a pipe, so a plain read is as hidden as it gets.
        self.prompt(label)
    }
}
