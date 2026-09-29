//! Process helpers shared by the whole CLI.
use std::process::{Command, Stdio};

use anyhow::{bail, Context, Result};

/// Runs a command, returning its stdout; its stderr is kept for the error.
/// For tools that are quiet on success (nix, git).
pub fn run(cmd: &mut Command, what: &str) -> Result<String> {
    let out = cmd.stderr(Stdio::piped()).output().with_context(|| format!("starting {what}"))?;
    if !out.status.success() {
        bail!("{what} failed ({}):\n{}", out.status, String::from_utf8_lossy(&out.stderr).trim_end());
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Runs a command, returning its stdout; its stderr goes to the terminal as
/// it happens. For sops decrypting, whose yubikey plugin asks for a PIN or a
/// touch there.
pub fn capture(cmd: &mut Command, what: &str) -> Result<String> {
    let out = cmd.stderr(Stdio::inherit()).output().with_context(|| format!("starting {what}"))?;
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
