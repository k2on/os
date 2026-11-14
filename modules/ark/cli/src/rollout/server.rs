//! The rollout as adam sees it: Prometheus and Loki (services/dash), the
//! same facts Grafana shows, through their HTTP APIs on the tailnet
//! (`arkMonitoring`, metrics.<domain> and logs.<domain>).
//!
//! Expected systems are ark-rollout's (services/dash/rollout), worked out on
//! adam for each new commit on main; until adam has any (ark-rollout not
//! deployed yet), they're evaluated here, as the direct source does.
//! Prometheus scrapes every minute, so this lags the hosts by up to that.
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Duration;

use serde_json::Value;

use super::direct::{comin_seen, devices_seen};
use super::{evaluate_here, DevicesSeen, Expected, HostSeen, Source};
use crate::hosts::{Host, Hosts};
use crate::prom::Sample;

pub struct Server<'a> {
    prometheus: String,
    loki: String,
    root: PathBuf,
    hosts: &'a Hosts,
    agent: ureq::Agent,
    /// This round's samples, by host label.
    samples: BTreeMap<String, Vec<Sample>>,
    /// Hosts Prometheus last scraped fine.
    up: BTreeMap<String, bool>,
    evaluated_here: Option<BTreeMap<String, Expected>>,
}

/// %-encoding for a query string value.
fn encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

impl<'a> Server<'a> {
    pub fn new(prometheus: String, loki: String, root: PathBuf, hosts: &'a Hosts) -> Self {
        Server {
            prometheus: prometheus.trim_end_matches('/').into(),
            loki: loki.trim_end_matches('/').into(),
            root,
            hosts,
            agent: ureq::AgentBuilder::new().timeout(Duration::from_secs(5)).build(),
            samples: BTreeMap::new(),
            up: BTreeMap::new(),
            evaluated_here: None,
        }
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
                    Some(Sample { name: labels.get("__name__").cloned().unwrap_or_default(), labels, value })
                })
                .collect(),
        )
    }

    /// comin's latest log line on the host, from Loki.
    fn log(&self, host: &str) -> Option<String> {
        let q = format!("{{host=\"{host}\",unit=\"comin.service\"}} != \"dropped event for subscriber\"");
        let url = format!("{}/loki/api/v1/query_range?query={}&limit=1&direction=backward&since=1h", self.loki, encode(&q));
        let v: Value = self.agent.get(&url).call().ok()?.into_json().ok()?;
        let line = v.pointer("/data/result/0/values/0/1")?.as_str()?;
        Some(clean(line))
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
        if let Some(e) = &self.evaluated_here {
            return e.clone();
        }
        // ark-rollout has never published: work it out here instead.
        if self.query("ark_rollout_commit_timestamp_seconds").is_some_and(|s| s.is_empty()) {
            return self.evaluated_here.insert(evaluate_here(&self.root, self.hosts, commit)).clone();
        }
        let of = |q: &str| self.query(&format!("{q}{{commit=\"{commit}\"}}")).unwrap_or_default();
        let seen = !of("ark_rollout_commit_timestamp_seconds").is_empty();
        let paths = of("ark_rollout_expected_system");
        let failures = of("ark_rollout_eval_failed");
        self.hosts
            .0
            .keys()
            .map(|name| {
                // target_host: Prometheus keeps "host" for the host it
                // scraped (adam), so ark-rollout names the one it means so.
                let by = |s: &&Sample| s.labels.get("target_host") == Some(name);
                let e = if let Some(p) = paths.iter().find(by).and_then(|s| s.labels.get("path")) {
                    Expected::Path(p.clone())
                } else if let Some(f) = failures.iter().find(by) {
                    Expected::Failed(f.labels.get("error").cloned().unwrap_or_default())
                } else if seen {
                    Expected::Unknown("adam is working out what it should run".into())
                } else {
                    Expected::Unknown("waiting for adam to see the commit".into())
                };
                (name.clone(), e)
            })
            .collect()
    }

    fn host(&mut self, host: &Host) -> HostSeen {
        let samples = self.samples.get(&host.name).map(Vec::as_slice).unwrap_or_default();
        let mut seen = HostSeen { reachable: self.up.get(&host.name).copied().unwrap_or(false), ..Default::default() };
        seen.running = samples.iter().find(|s| s.name == "ark_system_info").and_then(|s| s.labels.get("path").cloned());
        comin_seen(samples, &mut seen);
        seen.log = self.log(&host.name);
        seen
    }

    fn devices(&mut self, host: &Host) -> Option<DevicesSeen> {
        let samples = self.samples.get(&host.name)?;
        let seen = devices_seen(samples);
        (!seen.devices.is_empty()).then_some(seen)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes() {
        assert_eq!(encode(r#"up{job="node"}"#), "up%7Bjob%3D%22node%22%7D");
    }

    #[test]
    fn cleans_comin_lines() {
        assert_eq!(
            clean(r#"time="2026-11-14T10:34:23-06:00" level=info msg="deployer: \"switch\" failed""#),
            r#"deployer: "switch" failed"#
        );
        assert_eq!(clean("plain"), "plain");
    }
}
