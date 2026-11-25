//! `ark push`: ship the signed commit on main, and watch it reach every
//! host and device (./rollout).
//!
//! It pushes to both remotes comin deploys from (aspects/defaults/deploy.nix: Gitea
//! and GitHub, which it refuses to follow once they part), the secrets
//! submodule's new commits too, then watches the rollout from the monitoring host's
//! Prometheus and Loki when they answer (what Grafana shows), or from the
//! hosts themselves when they don't (no monitoring yet, or it is what's
//! being deployed). `--server` or `--direct` picks one; `--no-push` only
//! watches.
//!
//! Having pushed, it asks for a resync so nobody waits for comin's next
//! poll: the monitoring host's (services/dash), which makes every host fetch now, or with
//! the direct source each host's comin-fetch itself (aspects/defaults/deploy.nix).
use std::cell::OnceCell;
use std::process::Command;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use serde_json::Value;

use crate::rollout::{
    self,
    direct::{self, Direct, Ports},
    eval::Evaluation,
    server::Server,
    Source,
};
use crate::service::Ctx;
use crate::util;

pub enum Via {
    Auto,
    Server,
    Direct,
}

fn git(ctx: &Ctx, args: &[&str]) -> Result<String> {
    Ok(util::run(
        Command::new("git").args(args).current_dir(&ctx.root),
        &format!("git {}", args[0]),
    )?
    .trim()
    .to_string())
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
    let hosts = ctx.hosts()?;
    let names: Vec<String> = hosts.0.keys().cloned().collect();
    let evaluate = || Evaluation::start(ctx.root.clone(), names.clone(), commit.clone());
    let mut evaluation = None;
    if push {
        if !git(ctx, &["status", "--porcelain"])?.is_empty() {
            eprintln!("ark: there are uncommitted changes; they aren't part of {short}");
        }
        eprintln!("ark: pushing {short} {subject}");
        // Gitea (origin) with the secrets submodule's commits; GitHub too,
        // unless Gitea mirrors there itself (services/git/_mirror.nix), which
        // saves signing in to it.
        util::status(
            Command::new("git")
                .args(["push", "--recurse-submodules=on-demand", "origin", "main"])
                .current_dir(&ctx.root),
            "git push origin",
        )?;
        // What each host builds at the commit, meanwhile (rollout/eval.rs).
        // Not before: its fetch of the secrets submodule signs in to Gitea
        // too, and after the push it reuses that connection (one touch).
        evaluation = Some(evaluate());
        let mirrored = ctx
            .nix_eval("arkPush")
            .ok()
            .and_then(|v| v.get("githubMirror")?.as_bool())
            .unwrap_or(false);
        if !mirrored {
            util::status(
                Command::new("git")
                    .args(["push", "github", "main"])
                    .current_dir(&ctx.root),
                "git push github",
            )?;
        }
    }

    let monitoring = ctx.nix_eval("arkMonitoring").ok();
    // The hosts' own ports: with monitoring's output when it has them, else
    // evaluated only when the hosts are dialled directly, and once.
    let agent_ports = OnceCell::new();
    if let Some(p) = monitoring
        .as_ref()
        .and_then(|m| serde_json::from_value::<Ports>(m.get("agentPorts")?.clone()).ok())
    {
        let _ = agent_ports.set(p);
    }
    let ports = || -> Result<Ports> {
        if let Some(p) = agent_ports.get() {
            return Ok(*p);
        }
        let p: Ports = serde_json::from_value(ctx.nix_eval("arkAgentPorts")?)
            .context("reading the arkAgentPorts flake output (lib/agents.nix)")?;
        Ok(*agent_ports.get_or_init(|| p))
    };
    let url = |k: &str| {
        monitoring
            .as_ref()
            .and_then(|m| m.get(k))
            .and_then(Value::as_str)
            .map(str::to_string)
    };
    let server = match (url("prometheus"), url("loki")) {
        (Some(p), Some(l)) => hosts
            .running("dash")
            .ok()
            .map(|h| Server::new(h.name.clone(), p, l, agent_ports.get().copied(), &hosts)),
        _ => None,
    };
    let server = match (via, server) {
        (Via::Direct, _) => None,
        (Via::Server, Some(s)) => Some(s),
        (Via::Server, None) => {
            bail!("no monitoring to watch from (the arkMonitoring flake output: services/dash)")
        }
        (Via::Auto, Some(s)) if s.answers() => Some(s),
        (Via::Auto, _) => {
            eprintln!("ark: monitoring isn't answering; watching the hosts directly");
            None
        }
    };
    if push {
        // Through the monitoring host when it's there to ask; each host itself when it isn't,
        // or doesn't take it (a resync it doesn't serve yet).
        let through_monitoring =
            server.is_some() && url("resync").is_some_and(|u| resync_through(&u));
        if !through_monitoring {
            let missed = direct::resync(&hosts, ports()?);
            if !missed.is_empty() {
                eprintln!(
                    "ark: {} didn't take the resync; it deploys at its next poll",
                    missed.join(", ")
                );
            }
        }
    }
    let evaluation = evaluation.unwrap_or_else(evaluate);
    let mut source: Box<dyn Source> = match server {
        Some(s) => Box::new(s.evaluating(evaluation)),
        None => Box::new(Direct::new(&hosts, ports()?, evaluation)),
    };
    rollout::watch(source.as_mut(), &hosts, &commit, &subject)
}

/// Asks the monitoring host to make every host fetch now (services/dash's ark-resync).
fn resync_through(url: &str) -> bool {
    ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(15))
        .build()
        .post(url)
        .call()
        .is_ok()
}
