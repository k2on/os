//! Which host runs which service, and how to reach it: the `arkHosts` flake
//! output (modules/ark/lib/services.nix), so service commands never carry
//! addresses of their own.
use std::collections::BTreeMap;
use std::fmt;
use std::process::Command;

use anyhow::{bail, Context, Result};
use serde::Deserialize;

use crate::service::Ctx;
use crate::util;

#[derive(Deserialize)]
pub struct Host {
    /// The den host name, e.g. adam; how the machine is called in this repo.
    pub name: String,
    /// networking.hostName, e.g. ark.
    #[serde(rename = "hostName")]
    pub host_name: String,
    /// user@address to ssh to: the host's sudo user at its tailnet name. None
    /// when nix cannot work it out (no tailscale, no single sudo user).
    pub ssh: Option<String>,
    /// The ark services (modules/ark/services) it runs.
    pub services: Vec<String>,
}

impl fmt::Display for Host {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.ssh {
            Some(ssh) => write!(f, "{} ({ssh})", self.name),
            None => write!(f, "{}", self.name),
        }
    }
}

impl Host {
    fn target(&self) -> Result<&str> {
        self.ssh.as_deref().with_context(|| {
            format!(
                "no way to ssh to {}: it needs tailscale and exactly one sudo (wheel) user, and some host must run headscale",
                self.name
            )
        })
    }

    /// ssh to the host. Its tailnet name is new to known_hosts the first time;
    /// accept-new takes it then and still refuses a key that changed.
    fn command(&self) -> Result<(Command, &str)> {
        let target = self.target()?;
        let mut cmd = Command::new("ssh");
        cmd.args(["-o", "StrictHostKeyChecking=accept-new"]);
        Ok((cmd, target))
    }

    /// Runs a shell command on the host over ssh, with the terminal attached
    /// (sudo may ask, and output streams as it happens).
    pub fn ssh(&self, remote: &str) -> Result<()> {
        let (mut cmd, target) = self.command()?;
        util::status(cmd.args(["-t", target, remote]), &format!("ssh {target}"))
    }

    /// Runs a shell command on the host over ssh and returns its stdout.
    pub fn ssh_output(&self, remote: &str) -> Result<String> {
        let (mut cmd, target) = self.command()?;
        util::capture(cmd.args([target, remote]), &format!("ssh {target}"))
    }
}

pub struct Hosts(pub BTreeMap<String, Host>);

impl Hosts {
    /// The host running a service; there has to be exactly one.
    pub fn running(&self, service: &str) -> Result<&Host> {
        let mut found = self.0.values().filter(|h| h.services.iter().any(|s| s == service));
        let Some(host) = found.next() else {
            bail!("no host includes the {service} service (den.aspects.<host>.includes service-{service})");
        };
        if let Some(other) = found.next() {
            bail!("{service} runs on both {} and {}; that is not something ark knows how to pick between", host.name, other.name);
        }
        Ok(host)
    }
}

impl Ctx {
    pub fn hosts(&self) -> Result<Hosts> {
        let raw: BTreeMap<String, Host> =
            serde_json::from_value(self.nix_eval("arkHosts")?).context("reading the arkHosts flake output")?;
        Ok(Hosts(raw))
    }
}

/// `ark hosts`: the hosts, how to reach them, what they run.
pub fn list(ctx: &Ctx) -> Result<()> {
    println!("{:<8} {:<10} {:<20} {}", "HOST", "HOSTNAME", "SSH", "SERVICES");
    for host in ctx.hosts()?.0.values() {
        println!(
            "{:<8} {:<10} {:<20} {}",
            host.name,
            host.host_name,
            host.ssh.as_deref().unwrap_or("-"),
            if host.services.is_empty() { "-".to_string() } else { host.services.join(" ") }
        );
    }
    Ok(())
}
