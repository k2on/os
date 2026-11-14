//! The rollout as every host tells it itself, over the tailnet: nothing
//! else needed, so it works with no adam, or with monitoring being what's
//! deployed. Expected systems are evaluated here.
//!
//!   - node_exporter (:9100): `ark_system_info`, the system the host runs
//!     (aspects/metrics.nix), and on the devices' host their metrics
//!     (services/devices/apple/metrics);
//!   - comin (:4243): which of its stages last failed, its last deployment;
//!   - comin-log (:4244, aspects/deploy.nix): its latest log line.
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Duration;

use super::{evaluate_here, DeviceSeen, DevicesSeen, Expected, HostSeen, Source};
use crate::hosts::{Host, Hosts};
use crate::prom::{self, Sample};

const NODE_PORT: u16 = 9100;
const COMIN_PORT: u16 = 4243;
const COMIN_LOG_PORT: u16 = 4244;

pub struct Direct<'a> {
    root: PathBuf,
    hosts: &'a Hosts,
    agent: ureq::Agent,
    expected: Option<BTreeMap<String, Expected>>,
}

impl<'a> Direct<'a> {
    pub fn new(root: PathBuf, hosts: &'a Hosts) -> Self {
        Direct { root, hosts, agent: ureq::AgentBuilder::new().timeout(Duration::from_secs(3)).build(), expected: None }
    }
}

/// Where a host's exporters answer: its tailnet name, from arkHosts' ssh target.
pub fn address(host: &Host) -> Option<&str> {
    let ssh = host.ssh.as_deref()?;
    Some(ssh.rsplit_once('@').map_or(ssh, |(_, a)| a))
}

fn get(agent: &ureq::Agent, url: &str) -> Option<String> {
    agent.get(url).call().ok()?.into_string().ok()
}

fn scrape(agent: &ureq::Agent, address: &str, port: u16) -> Option<Vec<Sample>> {
    Some(prom::parse(&get(agent, &format!("http://{address}:{port}/metrics"))?))
}

/// comin's failed stages and the rest of what its metrics say, shared with
/// the server source, whose samples are the same.
pub fn comin_seen(samples: &[Sample], seen: &mut HostSeen) {
    let flag = |name: &str| prom::named(samples, name).any(|s| s.value == 1.0);
    seen.failed = [("evaluation", "comin_last_eval_failed"), ("build", "comin_last_build_failed"), ("deployment", "comin_last_deployment_failed")]
        .into_iter()
        .filter(|(_, m)| flag(m))
        .map(|(stage, _)| stage)
        .collect();
    seen.fetch_failed = flag("comin_last_fetch_failed");
    seen.deployed = prom::named(samples, "comin_deployment_info")
        .next()
        .and_then(|s| Some((s.labels.get("commit_id")?.clone(), s.labels.get("status")?.clone())));
}

/// The devices from samples of their metrics, shared with the server source.
pub fn devices_seen(samples: &[Sample]) -> DevicesSeen {
    fn of<'s>(samples: &'s [Sample], name: &'s str, device: &str) -> Vec<&'s Sample> {
        prom::named(samples, name).filter(|s| s.labels.get("device").map(String::as_str) == Some(device)).collect()
    }
    let of = |name: &'static str, device: &str| of(samples, name, device);
    DevicesSeen {
        written: prom::named(samples, "apple_devices_metrics_timestamp_seconds").next().map_or(0.0, |s| s.value),
        devices: prom::named(samples, "apple_device_up")
            .filter_map(|s| s.labels.get("device").cloned())
            .map(|name| DeviceSeen {
                pending: of("apple_device_declarations_pending", &name).first().map(|s| s.value as u64),
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

    fn expected(&mut self, commit: &str) -> BTreeMap<String, Expected> {
        self.expected.get_or_insert_with(|| evaluate_here(&self.root, self.hosts, commit)).clone()
    }

    fn host(&mut self, host: &Host) -> HostSeen {
        let Some(address) = address(host) else { return HostSeen::default() };
        let node = scrape(&self.agent, address, NODE_PORT);
        let comin = scrape(&self.agent, address, COMIN_PORT);
        let mut seen = HostSeen { reachable: node.is_some() || comin.is_some(), ..Default::default() };
        seen.running = node.as_deref().and_then(|n| prom::named(n, "ark_system_info").next()).and_then(|s| s.labels.get("path").cloned());
        comin_seen(comin.as_deref().unwrap_or_default(), &mut seen);
        seen.log = get(&self.agent, &format!("http://{address}:{COMIN_LOG_PORT}/"))
            .map(|t| t.trim().to_string())
            .filter(|l| !l.is_empty());
        seen
    }

    fn devices(&mut self, host: &Host) -> Option<DevicesSeen> {
        Some(devices_seen(&scrape(&self.agent, address(host)?, NODE_PORT)?))
    }
}
