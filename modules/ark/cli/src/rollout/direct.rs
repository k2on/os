//! The rollout as every host tells it itself, over the tailnet: nothing
//! else needed, so it works with no monitoring host, or with monitoring being what's
//! deployed. Expected systems are evaluated here.
//!
//!   - node_exporter: `ark_system_info`, the system the host runs
//!     (aspects/defaults/metrics.nix), and on the devices' host their metrics
//!     (services/devices/apple/metrics);
//!   - comin: which of its stages last failed, its last deployment;
//!   - comin-log (aspects/defaults/deploy.nix): its latest log line.
//!
//! On the ports lib/agents.nix fixes (the arkAgentPorts flake output).
use std::collections::BTreeMap;
use std::time::Duration;

use super::eval::Evaluation;
use super::{DeviceSeen, DevicesSeen, Expected, HostSeen, Source};
use crate::hosts::{Host, Hosts};
use crate::prom::{self, Sample};
use serde::Deserialize;

/// What every host serves on, from lib/agents.nix.
#[derive(Deserialize, Clone, Copy)]
#[serde(rename_all = "camelCase")]
pub struct Ports {
    pub node: u16,
    pub comin: u16,
    pub comin_log: u16,
    pub comin_fetch: u16,
}

pub struct Direct<'a> {
    hosts: &'a Hosts,
    ports: Ports,
    agent: ureq::Agent,
    /// What each host builds at the commit (./eval.rs).
    evaluation: Evaluation,
}

impl<'a> Direct<'a> {
    pub fn new(hosts: &'a Hosts, ports: Ports, evaluation: Evaluation) -> Self {
        Direct {
            hosts,
            ports,
            agent: ureq::AgentBuilder::new()
                .timeout(Duration::from_secs(3))
                .build(),
            evaluation,
        }
    }
}

/// Makes every host's comin fetch now (aspects/defaults/deploy.nix's comin-fetch),
/// all at once: what the monitoring host's resync does, for when it isn't there to.
/// Returns the hosts that didn't take it.
pub fn resync(hosts: &Hosts, ports: Ports) -> Vec<String> {
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(10))
        .build();
    std::thread::scope(|s| {
        let pokes: Vec<_> = hosts
            .0
            .values()
            .map(|host| {
                let agent = &agent;
                s.spawn(move || {
                    let ok = address(host).is_some_and(|a| {
                        agent
                            .post(&format!("http://{a}:{}/", ports.comin_fetch))
                            .call()
                            .is_ok()
                    });
                    (!ok).then(|| host.name.clone())
                })
            })
            .collect();
        pokes
            .into_iter()
            .filter_map(|p| p.join().ok().flatten())
            .collect()
    })
}

/// Where a host's exporters answer: its tailnet name, from arkHosts' ssh target.
pub fn address(host: &Host) -> Option<&str> {
    let ssh = host.ssh.as_deref()?;
    Some(ssh.rsplit_once('@').map_or(ssh, |(_, a)| a))
}

fn get(agent: &ureq::Agent, url: &str) -> Option<String> {
    agent.get(url).call().ok()?.into_string().ok()
}

pub(super) fn scrape(agent: &ureq::Agent, address: &str, port: u16) -> Option<Vec<Sample>> {
    Some(prom::parse(&get(
        agent,
        &format!("http://{address}:{port}/metrics"),
    )?))
}

/// When the host last switched system: node_exporter's mtime of the file
/// activation writes ark_system_info to (aspects/defaults/metrics.nix). Shared with
/// the server source, whose samples are the same.
pub fn switched(samples: &[Sample]) -> Option<f64> {
    prom::named(samples, "node_textfile_mtime_seconds")
        .find(|s| {
            s.labels
                .get("file")
                .is_some_and(|f| f.ends_with("/ark_system.prom"))
        })
        .map(|s| s.value)
}

/// comin's failed stages and the rest of what its metrics say, shared with
/// the server source, whose samples are the same.
pub fn comin_seen(samples: &[Sample], seen: &mut HostSeen) {
    let flag = |name: &str| prom::named(samples, name).any(|s| s.value == 1.0);
    seen.failed = [
        ("evaluation", "comin_last_eval_failed"),
        ("build", "comin_last_build_failed"),
        ("deployment", "comin_last_deployment_failed"),
    ]
    .into_iter()
    .filter(|(_, m)| flag(m))
    .map(|(stage, _)| stage)
    .collect();
    seen.fetch_failed = flag("comin_last_fetch_failed");
    seen.deployed = prom::named(samples, "comin_deployment_info")
        .next()
        .and_then(|s| {
            Some((
                s.labels.get("commit_id")?.clone(),
                s.labels.get("status")?.clone(),
            ))
        });
}

/// The devices from samples of their metrics, shared with the server source.
pub fn devices_seen(samples: &[Sample]) -> DevicesSeen {
    fn of<'s>(samples: &'s [Sample], name: &'s str, device: &str) -> Vec<&'s Sample> {
        prom::named(samples, name)
            .filter(|s| s.labels.get("device").map(String::as_str) == Some(device))
            .collect()
    }
    let of = |name: &'static str, device: &str| of(samples, name, device);
    DevicesSeen {
        written: prom::named(samples, "apple_devices_metrics_timestamp_seconds")
            .next()
            .map_or(0.0, |s| s.value),
        devices: prom::named(samples, "apple_device_up")
            .filter_map(|s| s.labels.get("device").cloned())
            .map(|name| DeviceSeen {
                pending: of("apple_device_declarations_pending", &name)
                    .first()
                    .map(|s| s.value as u64),
                rejects: of("apple_device_declaration_valid", &name)
                    .into_iter()
                    .find(|s| s.value == 0.0)
                    .and_then(|s| s.labels.get("declaration").cloned()),
                name,
            })
            .collect(),
    }
}

impl Source for Direct<'_> {
    fn name(&self) -> String {
        "watching the hosts directly".into()
    }

    fn expected(&mut self, _commit: &str) -> BTreeMap<String, Expected> {
        match self.evaluation.get() {
            Some(expected) => expected.clone(),
            None => self
                .hosts
                .0
                .keys()
                .map(|n| {
                    (
                        n.clone(),
                        Expected::Unknown("evaluating here what it should run".into()),
                    )
                })
                .collect(),
        }
    }

    fn host(&mut self, host: &Host) -> HostSeen {
        let Some(address) = address(host) else {
            return HostSeen::default();
        };
        let node = scrape(&self.agent, address, self.ports.node);
        let comin = scrape(&self.agent, address, self.ports.comin);
        let mut seen = HostSeen {
            reachable: node.is_some() || comin.is_some(),
            ..Default::default()
        };
        seen.running = node
            .as_deref()
            .and_then(|n| prom::named(n, "ark_system_info").next())
            .and_then(|s| s.labels.get("path").cloned());
        seen.switched = node.as_deref().and_then(switched);
        comin_seen(comin.as_deref().unwrap_or_default(), &mut seen);
        seen.log = get(
            &self.agent,
            &format!("http://{address}:{}/", self.ports.comin_log),
        )
        .map(|t| t.trim().to_string())
        .filter(|l| !l.is_empty());
        seen
    }

    fn devices(&mut self, host: &Host) -> Option<DevicesSeen> {
        Some(devices_seen(&scrape(
            &self.agent,
            address(host)?,
            self.ports.node,
        )?))
    }
}
