//! `ark push`: ship the signed commit on main to every host and device, and
//! watch it roll out.
//!
//! It pushes to both remotes comin deploys from (aspects/deploy.nix: Gitea
//! and GitHub, which it refuses to follow once they part), the secrets
//! submodule's new commits too, then works out what each host should end up
//! running: the system its configuration builds at this commit (nix eval,
//! nothing built here). Then it watches every host's own exporters over the
//! tailnet, nothing else, so it works with monitoring down or being
//! deployed itself:
//!
//!   - node                    Some(0) => State::Done(started.elapsed()),exporter (:9100) has `ark_system_info`, the system the host runs
//!     (aspects/metrics.nix): when that is the expected one, the host is done.
//!     A commit that leaves a host unchanged makes it done at once; comin
//!     skipping a system it deployed before is done too.
//!   - comin (:4243) says when its evaluation, build or deployment failed.
//!   - the host running devices-apple has its devices' metrics among its
//!     node_exporter's (services/devices/apple/metrics): once that host is
//!     done and the metrics are newer than that, each device is done when it
//!     has caught up with all its declarations.
use std::collections::BTreeMap;
use std::io::{IsTerminal, Write};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{bail, Result};

use crate::hosts::Host;
use crate::prom::{self, Sample};
use crate::service::Ctx;
use crate::util;

const POLL: Duration = Duration::from_secs(5);
const GIVE_UP: Duration = Duration::from_secs(45 * 60);
/// A host whose exporters don't answer for this long is reported offline.
const OFFLINE_AFTER: Duration = Duration::from_secs(60);
const NODE_PORT: u16 = 9100;
const COMIN_PORT: u16 = 4243;

#[derive(Clone, PartialEq)]
enum State {
    Pending(String),
    Done(Duration),
    Failed(String),
    Offline,
}

impl State {
    fn settled(&self) -> bool {
        !matches!(self, State::Pending(_))
    }
    fn show(&self) -> String {
        match self {
            State::Pending(why) => format!("pending   {why}"),
            State::Done(t) => format!("done      {}", clock(*t)),
            State::Failed(why) => format!("FAILED    {why}"),
            State::Offline => "offline   it deploys when it's back".into(),
        }
    }
}

fn clock(t: Duration) -> String {
    format!("{}m{:02}s", t.as_secs() / 60, t.as_secs() % 60)
}

fn git(ctx: &Ctx, args: &[&str]) -> Result<String> {
    Ok(util::run(Command::new("git").args(args).current_dir(&ctx.root), &format!("git {}", args[0]))?.trim().to_string())
}

/// Where a host's exporters answer: its tailnet name, from arkHosts' ssh target.
fn address(host: &Host) -> Option<&str> {
    let ssh = host.ssh.as_deref()?;
    Some(ssh.rsplit_once('@').map_or(ssh, |(_, a)| a))
}

fn scrape(agent: &ureq::Agent, address: &str, port: u16) -> Option<Vec<Sample>> {
    let text = agent.get(&format!("http://{address}:{port}/metrics")).call().ok()?.into_string().ok()?;
    Some(prom::parse(&text))
}

fn flag(samples: &[Sample], name: &str) -> bool {
    prom::named(samples, name).any(|s| s.value == 1.0)
}

/// comin's failure flags, by stage.
fn failures(comin: &[Sample]) -> Vec<&'static str> {
    [("evaluation", "comin_last_eval_failed"), ("build", "comin_last_build_failed"), ("deployment", "comin_last_deployment_failed")]
        .into_iter()
        .filter(|(_, m)| flag(comin, m))
        .map(|(stage, _)| stage)
        .collect()
}

struct Watched<'a> {
    host: &'a Host,
    expected: Result<String>,
    state: State,
    /// comin's failure flags when the watch began: one already set says
    /// nothing about this commit.
    failed_before: Option<Vec<&'static str>>,
    last_seen: Instant,
    done_at: Option<SystemTime>,
}

pub fn run(ctx: &Ctx) -> Result<()> {
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

    let hosts = ctx.hosts()?;
    eprintln!("ark: working out what {} hosts should run at {short} (nix eval)", hosts.0.len());
    let expected: BTreeMap<String, Result<String>> = std::thread::scope(|s| {
        let jobs: Vec<_> = hosts
            .0
            .keys()
            .map(|name| {
                let root = &ctx.root;
                (
                    name.clone(),
                    s.spawn(move || {
                        let attr = format!(".?submodules=1#nixosConfigurations.{name}.config.system.build.toplevel.outPath");
                        util::run(Command::new("nix").args(["eval", "--raw", &attr]).current_dir(root), &format!("nix eval {name}"))
                            .map(|p| p.trim().to_string())
                    }),
                )
            })
            .collect();
        jobs.into_iter().map(|(n, j)| (n, j.join().unwrap_or_else(|_| Err(anyhow::anyhow!("panicked"))))).collect()
    });

    let devices_host = hosts.running("devices-apple").ok().map(|h| h.name.clone());
    let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(3)).build();
    let started = Instant::now();
    let mut watched: Vec<Watched> = hosts
        .0
        .values()
        .map(|host| {
            let expected = expected.get(&host.name).map_or_else(|| Err(anyhow::anyhow!("not evaluated")), |r| {
                r.as_ref().map(String::clone).map_err(|e| anyhow::anyhow!("{e:#}"))
            });
            let state = match &expected {
                Err(e) => State::Failed(format!("doesn't evaluate: {}", e.to_string().lines().last().unwrap_or(""))),
                Ok(_) => State::Pending("waiting for comin".into()),
            };
            Watched { host, expected, state, failed_before: None, last_seen: Instant::now(), done_at: None }
        })
        .collect();

    let tty = std::io::stdout().is_terminal();
    let mut drawn = 0;
    let mut last_text = String::new();
    loop {
        for w in watched.iter_mut().filter(|w| !w.state.settled()) {
            let Some(address) = address(w.host) else {
                w.state = State::Failed("no tailnet name to reach it by".into());
                continue;
            };
            let (node, comin) = (scrape(&agent, address, NODE_PORT), scrape(&agent, address, COMIN_PORT));
            if node.is_none() && comin.is_none() {
                if w.last_seen.elapsed() > OFFLINE_AFTER {
                    w.state = State::Offline;
                }
                continue;
            }
            w.last_seen = Instant::now();
            let running = node.as_deref().and_then(|n| prom::named(n, "ark_system_info").next()).map(|s| s.labels["path"].clone());
            let expected = w.expected.as_deref().unwrap_or_default();
            if running.as_deref() == Some(expected) {
                w.state = State::Done(started.elapsed());
                w.done_at = Some(SystemTime::now());
                continue;
            }
            let comin = comin.unwrap_or_default();
            let failed_now = failures(&comin);
            let before = w.failed_before.get_or_insert_with(|| failed_now.clone());
            let deployed_failed = prom::named(&comin, "comin_deployment_info")
                .any(|s| s.labels.get("commit_id").map(String::as_str) == Some(commit.as_str()) && s.labels.get("status").map(String::as_str) == Some("failed"));
            if let Some(stage) = failed_now.iter().find(|f| !before.contains(f)) {
                w.state = State::Failed(format!("comin: its {stage} failed (journalctl -u comin)"));
            } else if deployed_failed {
                w.state = State::Failed("comin: deploying it failed (journalctl -u comin)".into());
            } else {
                let fetch = if flag(&comin, "comin_last_fetch_failed") { ", a fetch failing" } else { "" };
                let note = if before.is_empty() { "" } else { ", its last deploy had failed" };
                let what = if running.is_none() { "no ark_system_info yet (switching to this adds it)" } else { "deploying" };
                w.state = State::Pending(format!("{what}{fetch}{note}"));
            }
        }

        let devices = devices_host.as_ref().and_then(|name| {
            let w = watched.iter().find(|w| &w.host.name == name)?;
            Some(device_states(&agent, w, started))
        });

        let mut text = format!("ark push  {short} {subject}\n");
        for w in &watched {
            text += &format!("  {:<14} {}\n", w.host.name, w.state.show());
        }
        if let Some(devices) = &devices {
            for (device, state) in devices {
                text += &format!("  {:<14} {}\n", device, state.show());
            }
        }
        if tty {
            if drawn > 0 {
                print!("\x1b[{drawn}A\x1b[J");
            }
            print!("{text}");
            drawn = text.lines().count();
        } else if text != last_text {
            println!("{text}");
        }
        let _ = std::io::stdout().flush();
        last_text = text;

        let devices_settled = devices.as_ref().is_none_or(|d| d.iter().all(|(_, s)| s.settled()));
        if watched.iter().all(|w| w.state.settled()) && devices_settled {
            break;
        }
        if started.elapsed() > GIVE_UP {
            bail!("still not everywhere after {}: see above", clock(GIVE_UP));
        }
        std::thread::sleep(POLL);
    }

    let failed: Vec<String> = watched
        .iter()
        .filter_map(|w| matches!(w.state, State::Failed(_)).then(|| w.host.name.clone()))
        .collect();
    if !failed.is_empty() {
        bail!("{short} failed on {}", failed.join(", "));
    }
    Ok(())
}

/// The devices, once their host is done and its devices' metrics were
/// written after that (they're refreshed every few minutes).
fn device_states(agent: &ureq::Agent, host: &Watched, started: Instant) -> Vec<(String, State)> {
    let Some(address) = address(host.host) else { return vec![] };
    let Some(node) = scrape(agent, address, NODE_PORT) else { return vec![] };
    let names: Vec<String> = prom::named(&node, "apple_device_up").filter_map(|s| s.labels.get("device").cloned()).collect();
    let Some(done_at) = host.done_at else {
        return names.into_iter().map(|d| (d, State::Pending(format!("after {}", host.host.name)))).collect();
    };
    let done_secs = done_at.duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
    let written = prom::named(&node, "apple_devices_metrics_timestamp_seconds").next().map_or(0.0, |s| s.value);
    names
        .into_iter()
        .map(|device| {
            let of = |s: &&Sample| s.labels.get("device") == Some(&device);
            let state = if written < done_secs {
                State::Pending("waiting for its status to be read".into())
            } else if let Some(bad) = prom::named(&node, "apple_device_declaration_valid").filter(of).find(|s| s.value == 0.0) {
                State::Failed(format!("rejects {}", bad.labels.get("declaration").map_or("a declaration", String::as_str)))
            } else {
                match prom::named(&node, "apple_device_declarations_pending").filter(of).next().map(|s| s.value as u64) {
                    Some(0) => State::Done(started.elapsed()),
                    Some(n) => State::Pending(format!("{n} declarations to fetch")),
                    None => State::Pending("no status yet".into()),
                }
            };
            (device, state)
        })
        .collect()
}
