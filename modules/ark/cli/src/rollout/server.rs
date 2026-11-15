//! The rollout as the monitoring host sees it: Prometheus and Loki (services/dash), the
//! same facts Grafana shows, through their HTTP APIs on the tailnet
//! (`arkMonitoring`, metrics.<domain> and logs.<domain>).
//!
//! Expected systems are ark-rollout's (services/dash/rollout), worked out on
//! the monitoring host for each new commit on main, raced against the same
//! evaluation here: whichever answers first for a host.
//! Prometheus scrapes every minute, so which system a host runs (and its
//! comin state, and the devices') is read from the host itself when it
//! answers, and from Prometheus when it doesn't.
use std::collections::BTreeMap;
use std::time::Duration;

use serde_json::Value;

use super::direct::{address, comin_seen, devices_seen, scrape, switched, Ports};
use super::eval::Evaluation;
use super::{DevicesSeen, Expected, HostSeen, Source};
use crate::hosts::{Host, Hosts};
use crate::prom::Sample;

pub struct Server<'a> {
    /// The host running services/dash, as messages name it.
    host: String,
    prometheus: String,
    loki: String,
    /// The hosts' own ports, to read them between scrapes.
    ports: Option<Ports>,
    hosts: &'a Hosts,
    agent: ureq::Agent,
    /// For the hosts themselves: quick to give up on one that isn't there.
    direct: ureq::Agent,
    /// This round's samples, by host label.
    samples: BTreeMap<String, Vec<Sample>>,
    /// Hosts Prometheus last scraped fine.
    up: BTreeMap<String, bool>,
    /// What each host builds at the commit, worked out here (./eval.rs).
    evaluation: Option<Evaluation>,
}

/// %-encoding for a query string value.
fn encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

impl<'a> Server<'a> {
    pub fn new(
        host: String,
        prometheus: String,
        loki: String,
        ports: Option<Ports>,
        hosts: &'a Hosts,
    ) -> Self {
        Server {
            host,
            prometheus: prometheus.trim_end_matches('/').into(),
            loki: loki.trim_end_matches('/').into(),
            ports,
            hosts,
            agent: ureq::AgentBuilder::new()
                .timeout(Duration::from_secs(5))
                .build(),
            direct: ureq::AgentBuilder::new()
                .timeout(Duration::from_secs(2))
                .build(),
            samples: BTreeMap::new(),
            up: BTreeMap::new(),
            evaluation: None,
        }
    }

    /// What the host's node_exporter and comin serve right now, when it
    /// answers on the tailnet (the ports from lib/agents.nix).
    fn fresh(&self, host: &Host) -> Option<Vec<Sample>> {
        let ports = self.ports?;
        let address = address(host)?;
        let mut samples = scrape(&self.direct, address, ports.node)?;
        samples.extend(scrape(&self.direct, address, ports.comin).unwrap_or_default());
        Some(samples)
    }

    /// Races ark-rollout against `evaluation` (see expected); without one,
    /// only ark-rollout says what each host should run.
    pub fn evaluating(mut self, evaluation: Evaluation) -> Self {
        self.evaluation = Some(evaluation);
        self
    }

    /// Whether Prometheus answers: what `ark push` picks this source by.
    pub fn answers(&self) -> bool {
        self.query("up").is_some()
    }

    /// An instant PromQL query, as samples (named by `__name__`).
    fn query(&self, q: &str) -> Option<Vec<Sample>> {
        let url = format!("{}/api/v1/query?query={}", self.prometheus, encode(q));
        let v: Value = self.agent.get(&url).call().ok()?.into_json().ok()?;
        if v.get("status")?.as_str()? != "success" {
            return None;
        }
        Some(
            v.pointer("/data/result")?
                .as_array()?
                .iter()
                .filter_map(|r| {
                    let labels: BTreeMap<String, String> = r
                        .get("metric")?
                        .as_object()?
                        .iter()
                        .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_string())))
                        .collect();
                    let value = r.get("value")?.get(1)?.as_str()?.parse().ok()?;
                    Some(Sample {
                        name: labels.get("__name__").cloned().unwrap_or_default(),
                        labels,
                        value,
                    })
                })
                .collect(),
        )
    }

    /// comin's latest log line on the host, from Loki.
    fn log(&self, host: &str) -> Option<String> {
        let q = format!(
            "{{host=\"{host}\",unit=\"comin.service\"}} != \"dropped event for subscriber\""
        );
        let url = format!(
            "{}/loki/api/v1/query_range?query={}&limit=1&direction=backward&since=1h",
            self.loki,
            encode(&q)
        );
        let v: Value = self.agent.get(&url).call().ok()?.into_json().ok()?;
        let line = v.pointer("/data/result/0/values/0/1")?.as_str()?;
        Some(clean(line))
    }
}

/// What a host should run, from the monitoring host's answer (`there`) and
/// this machine's (`here`, None while still evaluating). A path from either
/// settles it. A failure is final only when both failed: either side can
/// fail where the other doesn't (a host of another system whose evaluation
/// builds something first: cale, aarch64, on an x86_64 one; or the other
/// way round on an aarch64 laptop).
fn merge(monitor: &str, there: Expected, here: Option<&Expected>) -> Expected {
    match (there, here) {
        (Expected::Path(p), _) => Expected::Path(p),
        (_, Some(Expected::Path(p))) => Expected::Path(p.clone()),
        (Expected::Failed(t), Some(Expected::Failed(h))) => {
            Expected::Failed(format!("on {monitor}: {t}; here: {h}"))
        }
        (Expected::Failed(_), _) => {
            Expected::Unknown(format!("{monitor} can't evaluate it; evaluating here"))
        }
        (Expected::Unknown(why), None) => Expected::Unknown(format!("{why}; evaluating here too")),
        (unknown, _) => unknown,
    }
}

/// A comin log line without its timestamp and level, as comin-log does
/// (aspects/deploy.nix).
fn clean(line: &str) -> String {
    let msg = line.split_once(" msg=").map_or(line, |(_, m)| m);
    msg.trim().trim_matches('"').replace("\\\"", "\"")
}

impl Source for Server<'_> {
    fn name(&self) -> String {
        format!("from {}", self.prometheus.trim_start_matches("https://"))
    }

    fn refresh(&mut self) {
        self.samples.clear();
        for q in [
            "ark_system_info",
            r#"node_textfile_mtime_seconds{file=~".*/ark_system.prom"}"#,
            r#"{__name__=~"comin_last_(eval|build|deployment|fetch)_failed"}"#,
            "comin_deployment_info",
            r#"{__name__=~"apple_device_up|apple_device_declarations_pending|apple_devices_metrics_timestamp_seconds"}"#,
            "apple_device_declaration_valid == 0",
        ] {
            for s in self.query(q).unwrap_or_default() {
                let host = s.labels.get("host").cloned().unwrap_or_default();
                self.samples.entry(host).or_default().push(s);
            }
        }
        self.up = self
            .query(r#"up{job="node"}"#)
            .unwrap_or_default()
            .into_iter()
            .filter_map(|s| Some((s.labels.get("host")?.clone(), s.value == 1.0)))
            .collect();
    }

    fn expected(&mut self, commit: &str) -> BTreeMap<String, Expected> {
        // The same commit evaluated here too (./eval.rs): whichever answers
        // first for a host is what it should run (they agree), so the watch
        // never waits on ark-rollout noticing the commit and evaluating
        // every host, which can take longer than a host takes to deploy.
        let here = self.evaluation.as_mut().and_then(Evaluation::get).cloned();
        if let Some(here) = &here {
            if here.values().all(|e| matches!(e, Expected::Path(_))) {
                return here.clone();
            }
        }

        let of = |q: &str| {
            self.query(&format!("{q}{{commit=\"{commit}\"}}"))
                .unwrap_or_default()
        };
        // No ark-rollout there at all (not deployed yet): only here counts.
        let absent = self
            .query("ark_rollout_commit_timestamp_seconds")
            .is_some_and(|s| s.is_empty());
        let seen = !of("ark_rollout_commit_timestamp_seconds").is_empty();
        let paths = of("ark_rollout_expected_system");
        let failures = of("ark_rollout_eval_failed");
        self.hosts
            .0
            .keys()
            .map(|name| {
                // target_host: Prometheus keeps "host" for the host it
                // scraped (the monitoring host), so ark-rollout names the
                // one it means so.
                let by = |s: &&Sample| s.labels.get("target_host") == Some(name);
                let there = if absent {
                    Expected::Failed("ark-rollout isn't running there".into())
                } else if let Some(p) = paths.iter().find(by).and_then(|s| s.labels.get("path")) {
                    Expected::Path(p.clone())
                } else if let Some(f) = failures.iter().find(by) {
                    Expected::Failed(f.labels.get("error").cloned().unwrap_or_default())
                } else if seen {
                    Expected::Unknown(format!("{} is working out what it should run", self.host))
                } else {
                    Expected::Unknown(format!("waiting for {} to see the commit", self.host))
                };
                let here = here.as_ref().and_then(|h| h.get(name));
                (name.clone(), merge(&self.host, there, here))
            })
            .collect()
    }

    fn host(&mut self, host: &Host) -> HostSeen {
        // The host itself when it answers: Prometheus scrapes once a minute,
        // so a host that has just switched would look behind until then.
        let fresh = self.fresh(host);
        let mut seen = HostSeen {
            reachable: fresh.is_some() || self.up.get(&host.name).copied().unwrap_or(false),
            ..Default::default()
        };
        let scraped = self
            .samples
            .get(&host.name)
            .map(Vec::as_slice)
            .unwrap_or_default();
        let samples = fresh.as_deref().unwrap_or(scraped);
        seen.running = samples
            .iter()
            .find(|s| s.name == "ark_system_info")
            .and_then(|s| s.labels.get("path").cloned());
        seen.switched = switched(samples);
        comin_seen(samples, &mut seen);
        seen.log = self.log(&host.name);
        seen
    }

    fn devices(&mut self, host: &Host) -> Option<DevicesSeen> {
        let fresh = self.fresh(host);
        let samples = fresh.as_ref().or(self.samples.get(&host.name))?;
        let seen = devices_seen(samples);
        (!seen.devices.is_empty()).then_some(seen)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn show(e: &Expected) -> String {
        match e {
            Expected::Path(p) => format!("path {p}"),
            Expected::Failed(f) => format!("failed {f}"),
            Expected::Unknown(u) => format!("unknown {u}"),
        }
    }

    #[test]
    fn merges_there_and_here() {
        let path = |p: &str| Expected::Path(p.into());
        let failed = |f: &str| Expected::Failed(f.into());
        let unknown = |u: &str| Expected::Unknown(u.into());
        let cases = [
            // Whichever has a path first.
            (path("a"), None, "path a"),
            (unknown("busy"), Some(path("b")), "path b"),
            (failed("IFD"), Some(path("b")), "path b"),
            // Both failed: final, with both reasons.
            (
                failed("IFD"),
                Some(failed("no key")),
                "failed on m: IFD; here: no key",
            ),
            // One side failed: wait for the other.
            (
                failed("IFD"),
                None,
                "unknown m can't evaluate it; evaluating here",
            ),
            (unknown("busy"), Some(failed("no key")), "unknown busy"),
            (unknown("busy"), None, "unknown busy; evaluating here too"),
        ];
        for (there, here, want) in cases {
            assert_eq!(show(&merge("m", there, here.as_ref())), want);
        }
    }

    #[test]
    fn encodes() {
        assert_eq!(encode(r#"up{job="node"}"#), "up%7Bjob%3D%22node%22%7D");
    }

    #[test]
    fn cleans_comin_lines() {
        assert_eq!(
            clean(
                r#"time="2026-11-14T10:34:23-06:00" level=info msg="deployer: \"switch\" failed""#
            ),
            r#"deployer: "switch" failed"#
        );
        assert_eq!(clean("plain"), "plain");
    }
}
