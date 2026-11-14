//! `ark push`: ship the signed commit on main, and watch it reach every
//! host and device (./rollout).
//!
//! It pushes to both remotes comin deploys from (aspects/deploy.nix: Gitea
//! and GitHub, which it refuses to follow once they part), the secrets
//! submodule's new commits too, then watches the rollout from adam's
//! Prometheus and Loki when they answer (what Grafana shows), or from the
//! hosts themselves when they don't (no adam yet, or monitoring is what's
//! being deployed). `--server` or `--direct` picks one; `--no-push` only
//! watches.
use std::process::Command;

use anyhow::{bail, Result};
use serde_json::Value;

use crate::rollout::{self, direct::Direct, server::Server, Source};
use crate::service::Ctx;
use crate::util;

pub enum Via {
    Auto,
    Server,
    Direct,
}

fn git(ctx: &Ctx, args: &[&str]) -> Result<String> {
    Ok(util::run(Command::new("git").args(args).current_dir(&ctx.root), &format!("git {}", args[0]))?.trim().to_string())
}

pub fn run(ctx: &Ctx, via: Via, push: bool) -> Result<()> {
    if git(ctx, &["rev-parse", "--abbrev-ref", "HEAD"])? != "main" {
        bail!("not on main: comin deploys main");
    }
    let commit = git(ctx, &["rev-parse", "HEAD"])?;
    let short = &commit[..7];
    let subject = git(ctx, &["log", "-1", "--format=%s"])?;
    if git(ctx, &["log", "-1", "--format=%G?"])? != "G" {
        bail!(
            "{short} isn't signed by a key comin trusts (modules/keys): it would never deploy. \
             `git log --show-signature -1` says why"
        );
    }
    if push {
        if !git(ctx, &["status", "--porcelain"])?.is_empty() {
            eprintln!("ark: there are uncommitted changes; they aren't part of {short}");
        }
        eprintln!("ark: pushing {short} {subject}");
        // Gitea (origin) with the secrets submodule's commits, then GitHub.
        util::status(
            Command::new("git").args(["push", "--recurse-submodules=on-demand", "origin", "main"]).current_dir(&ctx.root),
            "git push origin",
        )?;
        util::status(Command::new("git").args(["push", "github", "main"]).current_dir(&ctx.root), "git push github")?;
    }

    let hosts = ctx.hosts()?;
    let monitoring = ctx.nix_eval("arkMonitoring").ok();
    let url = |k: &str| monitoring.as_ref().and_then(|m| m.get(k)).and_then(Value::as_str).map(str::to_string);
    let server = match (url("prometheus"), url("loki")) {
        (Some(p), Some(l)) => Some(Server::new(p, l, ctx.root.clone(), &hosts)),
        _ => None,
    };
    let mut source: Box<dyn Source> = match (via, server) {
        (Via::Direct, _) => Box::new(Direct::new(ctx.root.clone(), &hosts)),
        (Via::Server, Some(s)) => Box::new(s),
        (Via::Server, None) => bail!("no monitoring to watch from (the arkMonitoring flake output: services/dash)"),
        (Via::Auto, Some(s)) if s.answers() => Box::new(s),
        (Via::Auto, _) => {
            eprintln!("ark: adam's monitoring isn't answering; watching the hosts directly");
            Box::new(Direct::new(ctx.root.clone(), &hosts))
        }
    };
    rollout::watch(source.as_mut(), &hosts, &commit, &subject)
}
