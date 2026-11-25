//! A commit's rollout to every host and device: the plumbing `ark push`
//! (../push.rs) and anything later (CI, a bootstrap) share.
//!
//! A rollout is the same wherever its facts come from. A `Source` reports,
//! moment by moment, what each host should run at the commit and what it
//! runs, how its comin is doing, and how each device is catching up; `watch`
//! turns that into states (pending, done, failed, offline) and draws them.
//! Sources:
//!   - `server` (./server.rs): the monitoring host's Prometheus and Loki, what Grafana
//!     shows, with what ark-rollout (services/dash/rollout) works out there;
//!   - `direct` (./direct.rs): every host's own exporters, for when there is
//!     no monitoring host (or it's what is being deployed).
pub mod direct;
pub mod eval;
pub mod server;

use std::collections::BTreeMap;
use std::io::{IsTerminal, Write};
use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{bail, Result};

use crate::hosts::{Host, Hosts};
use crate::util;

#[cfg(not(test))]
const POLL: Duration = Duration::from_secs(5);
#[cfg(test)]
const POLL: Duration = Duration::from_millis(1);
const GIVE_UP: Duration = Duration::from_secs(45 * 60);
/// A host not seen for this long is reported offline.
const OFFLINE_AFTER: Duration = Duration::from_secs(90);

/// What a host should run at the commit.
#[derive(Clone)]
pub enum Expected {
    /// Not known yet, and why.
    Unknown(String),
    Path(String),
    /// Its configuration doesn't evaluate at the commit.
    Failed(String),
}

/// One host, as a source sees it now.
#[derive(Default)]
pub struct HostSeen {
    pub reachable: bool,
    /// The system it runs (`ark_system_info`, aspects/defaults/metrics.nix).
    pub running: Option<String>,
    /// When it switched to that system (unix seconds): when activation last
    /// wrote ark_system_info, as node_exporter reports the file.
    pub switched: Option<f64>,
    /// comin's stages whose last run failed: evaluation, build, deployment.
    pub failed: Vec<&'static str>,
    /// comin's last deployment: commit and status.
    pub deployed: Option<(String, String)>,
    pub fetch_failed: bool,
    /// comin's latest log line.
    pub log: Option<String>,
}

pub struct DeviceSeen {
    pub name: String,
    /// Declarations it hasn't caught up with; None if it hasn't reported.
    pub pending: Option<u64>,
    /// A declaration it rejects.
    pub rejects: Option<String>,
}

/// The devices (services/devices/apple/metrics), and when what is known of
/// them was last written, Unix seconds.
pub struct DevicesSeen {
    pub written: f64,
    pub devices: Vec<DeviceSeen>,
}

pub trait Source {
    /// What it is, for the heading.
    fn name(&self) -> String;
    /// Called once per round, before the questions below.
    fn refresh(&mut self) {}
    fn expected(&mut self, commit: &str) -> BTreeMap<String, Expected>;
    fn host(&mut self, host: &Host) -> HostSeen;
    /// The devices of the host running devices-apple.
    fn devices(&mut self, host: &Host) -> Option<DevicesSeen>;
}

/// What the named hosts build at a commit, evaluated here: the commit by its
/// revision, not the working tree, whose uncommitted changes would make a
/// system no host ever runs. In the background and remembered: ./eval.rs.
pub fn evaluate_these(root: &Path, names: &[String], commit: &str) -> BTreeMap<String, Expected> {
    // All at once: one nix, one fetch of the secrets submodule (so one
    // YubiKey touch). If any host fails that, one by one, to say which.
    let flake = format!(
        "git+file://{}?submodules=1&rev={commit}#nixosConfigurations",
        root.display()
    );
    let wanted = names
        .iter()
        .map(|n| format!("{n:?} = true;"))
        .collect::<String>();
    let apply = format!("cs: builtins.mapAttrs (_: c: c.config.system.build.toplevel.outPath) (builtins.intersectAttrs {{ {wanted} }} cs)");
    if let Ok(out) = util::run(
        Command::new("nix")
            .args(["eval", "--json", &flake, "--apply", &apply])
            .current_dir(root),
        "nix eval",
    ) {
        if let Ok(paths) = serde_json::from_str::<BTreeMap<String, String>>(&out) {
            return names
                .iter()
                .map(|n| {
                    let e = paths.get(n).map_or_else(
                        || Expected::Failed("no such nixosConfiguration".into()),
                        |p| Expected::Path(p.clone()),
                    );
                    (n.clone(), e)
                })
                .collect();
        }
    }
    std::thread::scope(|s| {
        let jobs: Vec<_> = names
            .iter()
            .map(|name| {
                (
                    name.clone(),
                    s.spawn(move || {
                        let attr = format!(
                            "git+file://{}?submodules=1&rev={commit}#nixosConfigurations.{name}.config.system.build.toplevel.outPath",
                            root.display()
                        );
                        util::run(Command::new("nix").args(["eval", "--raw", &attr]).current_dir(root), &format!("nix eval {name}"))
                    }),
                )
            })
            .collect();
        jobs.into_iter()
            .map(|(n, j)| {
                let e = match j.join() {
                    Ok(Ok(p)) => Expected::Path(p.trim().to_string()),
                    Ok(Err(e)) => {
                        Expected::Failed(format!("{e:#}").lines().last().unwrap_or("").to_string())
                    }
                    Err(_) => Expected::Failed("nix eval panicked".into()),
                };
                (n, e)
            })
            .collect()
    })
}

#[derive(Clone, PartialEq)]
enum State {
    Pending(String),
    Done(Duration),
    /// Running it before the watch began.
    Already,
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
            State::Already => "done      already running it".into(),
            State::Failed(why) => format!("FAILED    {why}"),
            State::Offline => "offline   it deploys when it's back".into(),
        }
    }
}

/// A host seen running its expected system: how long it took from the watch
/// beginning (`begun`) to its switch (unix seconds), or already running it
/// if it switched before; and when it was done. Without a switch time, how
/// long the watch has run (`waited`).
fn done(switched: Option<f64>, begun: SystemTime, waited: Duration) -> (State, SystemTime) {
    let Some(at) = switched.map(|t| UNIX_EPOCH + Duration::from_secs_f64(t.max(0.0))) else {
        return (State::Done(waited), SystemTime::now());
    };
    match at.duration_since(begun) {
        Ok(t) => (State::Done(t), at),
        Err(_) => (State::Already, at),
    }
}

fn clock(t: Duration) -> String {
    format!("{}m{:02}s", t.as_secs() / 60, t.as_secs() % 60)
}

/// At most `max` characters, the end elided.
fn shorten(s: &str, max: usize) -> String {
    let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if s.chars().count() <= max {
        s
    } else {
        format!("{}…", s.chars().take(max - 1).collect::<String>())
    }
}

/// At most `max` characters, spacing kept, the end elided.
fn fit(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        format!(
            "{}…",
            s.chars().take(max.saturating_sub(1)).collect::<String>()
        )
    }
}

/// The terminal's width in columns (`stty size`), 80 when it won't say.
fn width() -> usize {
    std::fs::File::open("/dev/tty")
        .ok()
        .and_then(|tty| {
            std::process::Command::new("stty")
                .arg("size")
                .stdin(tty)
                .output()
                .ok()
        })
        .and_then(|o| {
            String::from_utf8(o.stdout)
                .ok()?
                .split_whitespace()
                .nth(1)?
                .parse()
                .ok()
        })
        .filter(|&w: &usize| w > 0)
        .unwrap_or(80)
}

struct Watched<'a> {
    host: &'a Host,
    state: State,
    /// comin's failed stages when the watch began: one already failed says
    /// nothing about this commit.
    failed_before: Option<Vec<&'static str>>,
    last_seen: Instant,
    done_at: Option<SystemTime>,
    log: Option<String>,
}

/// Watches `commit` reach every host and device, drawing it as it goes,
/// until each has settled; fails if any failed.
pub fn watch(source: &mut dyn Source, hosts: &Hosts, commit: &str, subject: &str) -> Result<()> {
    let short = &commit[..7.min(commit.len())];
    let devices_host = hosts.running("devices-apple").ok();
    let started = Instant::now();
    let begun = SystemTime::now();
    let mut watched: Vec<Watched> = hosts
        .0
        .values()
        .map(|host| Watched {
            host,
            state: State::Pending("waiting for comin".into()),
            failed_before: None,
            last_seen: Instant::now(),
            done_at: None,
            log: None,
        })
        .collect();
    let tty = std::io::stdout().is_terminal();
    let (mut drawn, mut last_text) = (0, String::new());

    loop {
        source.refresh();
        let expected = source.expected(commit);
        for w in watched.iter_mut().filter(|w| !w.state.settled()) {
            let path = match expected.get(&w.host.name) {
                Some(Expected::Path(p)) => p.clone(),
                Some(Expected::Failed(e)) => {
                    w.state = State::Failed(format!("doesn't evaluate: {e}"));
                    continue;
                }
                Some(Expected::Unknown(why)) => {
                    // Not known yet what it should run, but it may well be
                    // deploying it already: its comin log says how far.
                    let seen = source.host(w.host);
                    w.log = seen.log.or(w.log.take());
                    w.state = State::Pending(why.clone());
                    continue;
                }
                None => {
                    w.state = State::Pending("not evaluated yet".into());
                    continue;
                }
            };
            let seen = source.host(w.host);
            w.log = seen.log.clone().or(w.log.take());
            if !seen.reachable {
                if w.last_seen.elapsed() > OFFLINE_AFTER {
                    w.state = State::Offline;
                }
                continue;
            }
            w.last_seen = Instant::now();
            if seen.running.as_deref() == Some(path.as_str()) {
                // Timed from when it switched, not from when this noticed: a
                // host can be seen done well after (its expected system only
                // just known), and one that switched before the watch began
                // was already running it (a commit that leaves it as it was).
                let (state, at) = done(seen.switched, begun, started.elapsed());
                w.state = state;
                w.done_at = Some(at);
                continue;
            }
            let before = w.failed_before.get_or_insert_with(|| seen.failed.clone());
            let deploy_failed = seen
                .deployed
                .as_ref()
                .is_some_and(|(c, s)| c == commit && s == "failed");
            w.state = if let Some(stage) = seen.failed.iter().find(|f| !before.contains(f)) {
                State::Failed(format!("comin: its {stage} failed"))
            } else if deploy_failed {
                State::Failed("comin: deploying it failed".into())
            } else {
                let what = if seen.running.is_none() {
                    "no ark_system_info yet (switching to this adds it)"
                } else {
                    "deploying"
                };
                let fetch = if seen.fetch_failed {
                    ", a fetch failing"
                } else {
                    ""
                };
                let note = if before.is_empty() {
                    ""
                } else {
                    ", its last deploy had failed"
                };
                State::Pending(format!("{what}{fetch}{note}"))
            };
        }

        let devices = devices_host.and_then(|host| {
            let w = watched.iter().find(|w| w.host.name == host.name)?;
            Some(device_states(source.devices(host)?, w, started))
        });

        let mut text = format!("ark push  {short} {subject}   ({})\n", source.name());
        for w in &watched {
            text += &format!("  {:<14} {}\n", w.host.name, w.state.show());
            if let (State::Pending(_) | State::Failed(_), Some(log)) = (&w.state, &w.log) {
                text += &format!("  {:<14} └ {}\n", "", shorten(log, 96));
            }
        }
        for (device, state) in devices.iter().flatten() {
            text += &format!("  {:<14} {}\n", device, state.show());
        }
        if tty {
            // Cut to the terminal's width: a line that wrapped would take two
            // rows, and moving up by line count would leave the top of the
            // last frame behind.
            let width = width();
            let fitted: String = text.lines().map(|l| fit(l, width) + "\n").collect();
            if drawn > 0 {
                print!("\x1b[{drawn}A\x1b[J");
            }
            print!("{fitted}");
            drawn = fitted.lines().count();
        } else if text != last_text {
            println!("{text}");
        }
        let _ = std::io::stdout().flush();
        last_text = text;

        let devices_settled = devices
            .as_ref()
            .is_none_or(|d| d.iter().all(|(_, s)| s.settled()));
        if watched.iter().all(|w| w.state.settled()) && devices_settled {
            break;
        }
        if started.elapsed() > GIVE_UP {
            bail!("still not everywhere after {}: see above", clock(GIVE_UP));
        }
        std::thread::sleep(POLL);
    }

    let failed: Vec<&str> = watched
        .iter()
        .filter(|w| matches!(w.state, State::Failed(_)))
        .map(|w| w.host.name.as_str())
        .collect();
    if !failed.is_empty() {
        bail!("{short} failed on {}", failed.join(", "));
    }
    Ok(())
}

/// The devices, once their host is done and what's known of them was
/// written after that (it's refreshed every few minutes).
fn device_states(seen: DevicesSeen, host: &Watched, started: Instant) -> Vec<(String, State)> {
    let Some(done_at) = host.done_at else {
        return seen
            .devices
            .into_iter()
            .map(|d| (d.name, State::Pending(format!("after {}", host.host.name))))
            .collect();
    };
    let done_secs = done_at
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    seen.devices
        .into_iter()
        .map(|d| {
            let state = if seen.written < done_secs {
                State::Pending("waiting for its status to be read".into())
            } else if let Some(declaration) = d.rejects {
                State::Failed(format!("rejects {declaration}"))
            } else {
                match d.pending {
                    Some(0) => State::Done(started.elapsed()),
                    Some(n) => State::Pending(format!("{n} declarations to fetch")),
                    None => State::Pending("no status yet".into()),
                }
            };
            (d.name, state)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;

    /// Each round's view of every host (by name), the last repeated.
    struct Scripted {
        expected: BTreeMap<String, Expected>,
        rounds: VecDeque<BTreeMap<&'static str, HostSeen>>,
        round: BTreeMap<&'static str, HostSeen>,
        devices: VecDeque<Option<(f64, Option<u64>)>>,
    }

    impl Source for Scripted {
        fn name(&self) -> String {
            "scripted".into()
        }
        fn refresh(&mut self) {
            if let Some(r) = self.rounds.pop_front() {
                self.round = r;
            }
        }
        fn expected(&mut self, _: &str) -> BTreeMap<String, Expected> {
            self.expected.clone()
        }
        fn host(&mut self, host: &Host) -> HostSeen {
            let s = &self.round[host.name.as_str()];
            HostSeen {
                reachable: s.reachable,
                running: s.running.clone(),
                failed: s.failed.clone(),
                ..Default::default()
            }
        }
        fn devices(&mut self, _: &Host) -> Option<DevicesSeen> {
            let d = if self.devices.len() > 1 {
                self.devices.pop_front()?
            } else {
                *self.devices.front()?
            };
            let (written, pending) = d?;
            Some(DevicesSeen {
                written,
                devices: vec![DeviceSeen {
                    name: "phone".into(),
                    pending,
                    rejects: None,
                }],
            })
        }
    }

    fn hosts(names: &[&str]) -> Hosts {
        Hosts(
            names
                .iter()
                .map(|n| {
                    let services = if *n == "server" {
                        vec!["devices-apple".to_string()]
                    } else {
                        vec![]
                    };
                    (
                        n.to_string(),
                        Host {
                            name: n.to_string(),
                            host_name: n.to_string(),
                            ssh: None,
                            services,
                        },
                    )
                })
                .collect(),
        )
    }

    fn seen(running: &str, failed: &[&'static str]) -> HostSeen {
        HostSeen {
            reachable: true,
            running: Some(running.into()),
            failed: failed.to_vec(),
            ..Default::default()
        }
    }

    fn expected(pairs: &[(&str, Expected)]) -> BTreeMap<String, Expected> {
        pairs
            .iter()
            .map(|(n, e)| (n.to_string(), e.clone()))
            .collect()
    }

    fn now() -> f64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs_f64()
    }

    #[test]
    fn times_a_host_from_its_switch() {
        let begun = UNIX_EPOCH + Duration::from_secs(1000);
        let waited = Duration::from_secs(25);
        // Switched 40s into the watch, though only seen done later.
        let (state, at) = done(Some(1040.0), begun, waited);
        assert!(state == State::Done(Duration::from_secs(40)));
        assert_eq!(at, UNIX_EPOCH + Duration::from_secs(1040));
        // Switched before the watch: the commit left it as it was.
        assert!(done(Some(900.0), begun, waited).0 == State::Already);
        // No switch time: how long the watch took to see it.
        assert!(done(None, begun, waited).0 == State::Done(waited));
    }

    #[test]
    fn done_when_running_the_expected_system() {
        let mut s = Scripted {
            expected: expected(&[("benj", Expected::Path("new".into()))]),
            rounds: [
                BTreeMap::from([("benj", seen("old", &[]))]),
                BTreeMap::from([("benj", seen("new", &[]))]),
            ]
            .into(),
            round: BTreeMap::new(),
            devices: VecDeque::new(),
        };
        assert!(watch(&mut s, &hosts(&["benj"]), "abcdef0", "x").is_ok());
    }

    #[test]
    fn a_host_that_doesnt_evaluate_fails() {
        let mut s = Scripted {
            expected: expected(&[("benj", Expected::Failed("error: x".into()))]),
            rounds: [BTreeMap::from([("benj", seen("old", &[]))])].into(),
            round: BTreeMap::new(),
            devices: VecDeque::new(),
        };
        let e = watch(&mut s, &hosts(&["benj"]), "abcdef0", "x").unwrap_err();
        assert!(e.to_string().contains("failed on benj"), "{e}");
    }

    #[test]
    fn a_new_comin_failure_fails() {
        let mut s = Scripted {
            expected: expected(&[("benj", Expected::Path("new".into()))]),
            rounds: [
                BTreeMap::from([("benj", seen("old", &[]))]),
                BTreeMap::from([("benj", seen("old", &["build"]))]),
            ]
            .into(),
            round: BTreeMap::new(),
            devices: VecDeque::new(),
        };
        assert!(watch(&mut s, &hosts(&["benj"]), "abcdef0", "x").is_err());
    }

    #[test]
    fn an_earlier_failure_isnt_this_commits() {
        let mut s = Scripted {
            expected: expected(&[("benj", Expected::Path("new".into()))]),
            rounds: [
                BTreeMap::from([("benj", seen("old", &["build"]))]),
                BTreeMap::from([("benj", seen("old", &["build"]))]),
                BTreeMap::from([("benj", seen("new", &[]))]),
            ]
            .into(),
            round: BTreeMap::new(),
            devices: VecDeque::new(),
        };
        assert!(watch(&mut s, &hosts(&["benj"]), "abcdef0", "x").is_ok());
    }

    #[test]
    fn devices_follow_their_host() {
        let mut s = Scripted {
            expected: expected(&[("server", Expected::Path("new".into()))]),
            rounds: [
                BTreeMap::from([("server", seen("old", &[]))]),
                BTreeMap::from([("server", seen("new", &[]))]),
            ]
            .into(),
            round: BTreeMap::new(),
            // Stale (written before its host was done), then fetching, then caught up.
            devices: [
                Some((0.0, Some(0))),
                Some((now() + 60.0, Some(2))),
                Some((now() + 60.0, Some(0))),
            ]
            .into(),
        };
        assert!(watch(&mut s, &hosts(&["server"]), "abcdef0", "x").is_ok());
        assert!(
            s.devices.len() == 1,
            "the devices were asked until caught up"
        );
    }
}
