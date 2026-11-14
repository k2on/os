//! Process helpers shared by the whole CLI.
use std::process::{Command, Stdio};

use anyhow::{bail, Context, Result};

/// Runs a command, returning its stdout; its stderr is kept for the error.
/// For tools that are quiet on success (nix, git).
pub fn run(cmd: &mut Command, what: &str) -> Result<String> {
    let out = cmd
        .stderr(Stdio::piped())
        .output()
        .with_context(|| format!("starting {what}"))?;
    if !out.status.success() {
        bail!(
            "{what} failed ({}):\n{}",
            out.status,
            String::from_utf8_lossy(&out.stderr).trim_end()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Runs a command, returning its stdout; its stderr goes to the terminal as
/// it happens. For sops decrypting, whose yubikey plugin asks for a PIN or a
/// touch there.
pub fn capture(cmd: &mut Command, what: &str) -> Result<String> {
    let out = cmd
        .stderr(Stdio::inherit())
        .output()
        .with_context(|| format!("starting {what}"))?;
    if !out.status.success() {
        bail!("{what} failed ({})", out.status);
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Runs a command with the terminal as its stdio; fails if it does.
pub fn status(cmd: &mut Command, what: &str) -> Result<()> {
    let status = cmd.status().with_context(|| format!("starting {what}"))?;
    if !status.success() {
        bail!("{what} failed ({status})");
    }
    Ok(())
}

/// ssh options that share one connection per server (OpenSSH's
/// ControlMaster), kept 10 minutes after its last use: everything ark runs
/// that signs in somewhere (git push, nix fetching the secrets submodule,
/// ssh to a host) does it once, so the YubiKey is touched once per server,
/// and not again for a second ark command soon after. The socket is the one
/// a plain `ssh` uses too (host/cale/development/ssh.nix), so either one's
/// touch covers the other.
pub fn ssh_sharing() -> Vec<String> {
    // The runtime directory is already private; elsewhere, a private one.
    let dir = std::env::var_os("XDG_RUNTIME_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            let dir = std::env::temp_dir().join("ark-ssh");
            let _ = std::fs::create_dir_all(&dir);
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
            }
            dir
        });
    vec![
        "-o".into(),
        "ControlMaster=auto".into(),
        "-o".into(),
        format!("ControlPath={}/ssh-%C", dir.display()),
        "-o".into(),
        "ControlPersist=10m".into(),
    ]
}

/// Has git, and nix's git fetches, go through `ssh_sharing`: set for this
/// process, so every command ark runs inherits it. A GIT_SSH_COMMAND
/// already set is left alone.
pub fn share_ssh() {
    if std::env::var_os("GIT_SSH_COMMAND").is_none() {
        let opts = ssh_sharing().join(" ");
        // SAFETY: set before any thread is started.
        unsafe { std::env::set_var("GIT_SSH_COMMAND", format!("ssh {opts}")) };
    }
}
