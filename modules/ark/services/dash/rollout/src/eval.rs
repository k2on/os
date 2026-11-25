//! git and nix: main's commit, and what each host builds at it. The flake
//! is fetched by nix from the remote at that commit, its secrets submodule
//! too (as root, through the host's own key: aspects/defaults/deploy.nix).
use std::process::Command;

use crate::Result;

fn run(cmd: &mut Command, what: &str) -> Result<String> {
    let out = cmd.output().map_err(|e| format!("running {what}: {e}"))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        // nix ends with the line that says what went wrong.
        let last = err.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("").trim();
        return Err(format!("{what} failed: {last}").into());
    }
    Ok(String::from_utf8(out.stdout)?.trim().to_string())
}

pub fn main_commit(remote: &str) -> Result<String> {
    let out = run(Command::new("git").args(["ls-remote", remote, "refs/heads/main"]), "git ls-remote")?;
    let commit = out.split_whitespace().next().ok_or("main isn't there")?;
    if commit.len() != 40 || !commit.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err(format!("odd commit {commit:?}").into());
    }
    Ok(commit.to_string())
}

fn flake(remote: &str, commit: &str) -> String {
    format!("git+{remote}?rev={commit}&submodules=1")
}

pub fn hosts(remote: &str, commit: &str) -> Result<Vec<String>> {
    let out = run(
        Command::new("nix").args([
            "eval",
            "--raw",
            &format!("{}#arkHosts", flake(remote, commit)),
            "--apply",
            r#"h: builtins.concatStringsSep "\n" (builtins.attrNames h)"#,
        ]),
        "nix eval arkHosts",
    )?;
    Ok(out.lines().map(str::to_string).filter(|l| !l.is_empty()).collect())
}

pub fn system(remote: &str, commit: &str, host: &str) -> Result<String> {
    run(
        Command::new("nix").args([
            "eval",
            "--raw",
            &format!("{}#nixosConfigurations.{host}.config.system.build.toplevel.outPath", flake(remote, commit)),
        ]),
        &format!("nix eval {host}"),
    )
}
