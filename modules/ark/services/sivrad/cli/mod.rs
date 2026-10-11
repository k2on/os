//! `ark service sivrad ...`: set up the sivrad container from a laptop. Commands
//! drive the container over ssh (as `sivrad-channel`, at its tailnet name) and
//! keep what has to survive a rebuild in the secrets repo: the Signal account.
//!
//! Who may use sivrad is not a command: it is everyone with a Signal number
//! in secrets/ark.nix (`ark.persons.<username>.signal`, see ../default.nix).
//! Nor is the model: the Tinfoil API key is a secret like any other (`ark
//! secrets` asks for it), and the rest is configuration (../_llm.nix).
//!
//! This file is found by ../../../cli/build.rs and compiled as a module of
//! the `ark` crate, like money's.
mod signal;

use std::process::{Command, Output, Stdio};

use anyhow::{bail, Context, Result};
use clap::{ArgMatches, Command as Clap};
use serde::Deserialize;

use crate::secrets::Manifest;
use crate::service::{Ctx, Service};
use crate::util;

pub static SERVICE: Service = Service {
    name: "sivrad",
    about: "The sivrad assistant container: its services and Signal",
    command,
    run,
};

/// The secret entered by hand: Tinfoil's API key (../default.nix).
const TINFOIL_KEY: &str = "sivrad_tinfoil_api_key";

/// The container's services, in the order they depend on each other
/// (../_guest.nix, ../_llm.nix, ../_codex.nix, ../_chrome.nix). The agent
/// itself is a socket: an app-server starts when the channel connects.
const UNITS: &[&str] = &[
    "sivrad-tinfoil",
    "sivrad-llm",
    "sivrad.socket",
    "signal-cli",
    "sivrad-channel",
    "sivrad-chromium",
];

fn command() -> Clap {
    Clap::new("sivrad")
        .subcommand_required(true)
        .arg_required_else_help(true)
        .subcommand(
            Clap::new("init")
                .about("First-time setup, step by step; skips what is already done")
                .long_about(
                    "First-time setup; run it again any time, it skips what is already done. Says who \
                     may use sivrad (the people in secrets/ark.nix with a Signal number or username), makes sure the \
                     secrets exist (the Tinfoil API key is entered by hand with `ark secrets`), checks the \
                     container's services over ssh, and says what is left: the Signal account.",
                ),
        )
        .subcommand(signal::command())
}

fn run(ctx: &Ctx, m: &ArgMatches) -> Result<()> {
    match m.subcommand() {
        Some(("init", _)) => init(ctx),
        Some(("signal", m)) => signal::run(ctx, m),
        _ => unreachable!("subcommand_required"),
    }
}

/// What the nix side exports for us: the `arkServiceConfig.sivrad` flake
/// output, defined in ../default.nix from ../_container.nix.
#[derive(Deserialize)]
pub struct Config {
    /// The container's tailnet name; null when no host runs headscale.
    host: Option<String>,
    /// The account to log in as: the channel's, which owns the Signal
    /// account.
    user: String,
    signal: SignalConfig,
    /// Who may use sivrad: the Kanidm usernames in ark.persons with a Signal
    /// number.
    people: Vec<String>,
    browser: BrowserConfig,
}

/// The headed browser's page (sivrad-browser), behind a Kanidm sign-in.
#[derive(Deserialize)]
pub struct BrowserConfig {
    url: String,
    /// The Kanidm usernames it lets in.
    people: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SignalConfig {
    config_dir: String,
    socket: String,
}

impl Config {
    pub fn load(ctx: &Ctx) -> Result<Config> {
        serde_json::from_value(ctx.nix_eval("arkServiceConfig.sivrad")?)
            .context("reading arkServiceConfig.sivrad")
    }

    pub fn vm(&self) -> Result<Vm> {
        let host = self.host.as_deref().context(
            "the container has no tailnet name: some host has to run headscale (its dns.base_domain names it)",
        )?;
        Ok(Vm {
            target: format!("{}@{host}", self.user),
        })
    }
}

/// The container, over ssh. Its tailnet name is new to known_hosts the first time;
/// accept-new takes it then and still refuses a key that changed.
pub struct Vm {
    target: String,
}

impl Vm {
    fn ssh(&self) -> Command {
        let mut cmd = Command::new("ssh");
        cmd.args(["-o", "StrictHostKeyChecking=accept-new"]);
        cmd
    }

    /// Runs a command with the terminal attached (`ssh -t`), for anything
    /// interactive.
    pub fn interactive(&self, remote: &str) -> Result<()> {
        util::status(
            self.ssh().args(["-t", &self.target, remote]),
            &format!("ssh {}", self.target),
        )
    }

    /// Runs a command and returns its stdout; its stderr goes to the terminal.
    pub fn output(&self, remote: &str) -> Result<String> {
        util::capture(
            self.ssh().args([&self.target, remote]),
            &format!("ssh {}", self.target),
        )
    }

    /// Runs a command whose failure is an answer, not an error.
    fn probe(&self, remote: &str) -> Result<Output> {
        self.ssh()
            .args(["-o", "ConnectTimeout=15", &self.target, remote])
            .stdin(Stdio::null())
            .stderr(Stdio::piped())
            .output()
            .context("starting ssh")
    }
}

impl std::fmt::Display for Vm {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.target)
    }
}

/// `systemctl is-active a b c` prints one state per line, in order, and
/// exits non-zero when any is not active; pairs them up.
fn unit_states<'a>(units: &[&'a str], output: &str) -> Vec<(&'a str, String)> {
    let mut lines = output.lines();
    units
        .iter()
        .map(|u| (*u, lines.next().unwrap_or("unknown").trim().to_owned()))
        .collect()
}

/// `ark service sivrad init`.
fn init(ctx: &Ctx) -> Result<()> {
    let cfg = Config::load(ctx)?;
    let manifest = Manifest::load(ctx)?;

    println!("1. People and secrets");
    print_people(&cfg);
    let created = init_secrets(ctx, &manifest)?;
    if !manifest.present(ctx, TINFOIL_KEY) {
        println!(
            "   {TINFOIL_KEY} is missing: the model's API key, from the Tinfoil dashboard \
             (https://tinfoil.sh). Run `ark secrets`, which asks for it, then commit secrets/ and \
             deploy adam."
        );
    }
    if created {
        println!("   Commit secrets/ and deploy adam so the container gets them.");
    }

    println!("2. The container");
    let vm = cfg.vm()?;
    let reach = vm.probe("true")?;
    if !reach.status.success() {
        bail!(
            "cannot reach {vm} over ssh ({}). Is adam deployed and the container up on the tailnet? Then run \
             `ark service sivrad init` again",
            String::from_utf8_lossy(&reach.stderr).trim()
        );
    }
    let status = vm.probe(&format!("systemctl is-active {}", UNITS.join(" ")))?;
    let mut down = Vec::new();
    for (unit, state) in unit_states(UNITS, &String::from_utf8_lossy(&status.stdout)) {
        println!("   {unit:16} {state}");
        if state != "active" {
            down.push(unit);
        }
    }
    if !down.is_empty() {
        println!(
            "   Not running: {}. See why with\n     ssh {vm} journalctl -u {} -n 50",
            down.join(", "),
            down[0]
        );
    }

    println!("3. Signal");
    match signal::accounts(&cfg, &vm) {
        Ok(accounts) if accounts.is_empty() => println!(
            "   No Signal account yet. Give sivrad its own number with\n     ark service sivrad \
             signal register <+number>"
        ),
        Ok(accounts) => {
            let ids: Vec<&str> = accounts.iter().map(signal::Account::id).collect();
            println!("   signal-cli has {}.", ids.join(", "));
            if !signal_backed_up(ctx, &manifest) {
                println!(
                    "   It is not saved in the secrets repo yet: ark service sivrad signal backup"
                );
            }
        }
        Err(e) => println!("   Could not ask signal-cli in the container: {e:#}"),
    }

    println!(
        "\nThen, in the sivrad app, enter http://sivrad:8788 and sign in. People watch and take \
         over the assistant's browser at {browser} (sign in with Kanidm as one of: \
         {browser_people}); nothing to set up there.",
        browser = cfg.browser.url,
        browser_people = cfg.browser.people.join(", "),
    );
    Ok(())
}

/// Who may use sivrad, or how to add someone when nobody may yet.
fn print_people(cfg: &Config) {
    if cfg.people.is_empty() {
        println!(
            "   Nobody may use sivrad yet. Give a person in secrets/ark.nix a Signal number:\n\n     \
             ark.persons.<username>.signal = \"+15551234567\";\n\n   then commit secrets/ and deploy \
             adam."
        );
    } else {
        println!("   sivrad users: {}", cfg.people.join(", "));
    }
}

/// The Signal backup placeholders. True when anything was created.
fn init_secrets(ctx: &Ctx, manifest: &Manifest) -> Result<bool> {
    let missing: Vec<&str> = [signal::NUMBER, signal::ACCOUNT]
        .into_iter()
        .filter(|key| !manifest.present(ctx, key))
        .collect();
    if missing.is_empty() {
        println!("   {} and {} exist", signal::NUMBER, signal::ACCOUNT);
        return Ok(false);
    }
    // Empty until an account is registered; adam needs them to build.
    let values: Vec<(&str, String)> = missing.iter().map(|k| (*k, String::new())).collect();
    signal::store(ctx, manifest, &values)?;
    println!("   created {} (empty for now)", missing.join(" and "));
    Ok(true)
}

/// Whether the Signal account backup holds something, without decrypting:
/// sops leaves empty strings unencrypted, so the placeholder reads `""`.
fn signal_backed_up(ctx: &Ctx, manifest: &Manifest) -> bool {
    let Ok(spec) = manifest.spec(signal::ACCOUNT) else {
        return false;
    };
    let path = crate::secrets::vars_dir(ctx).join(format!("{}.yaml", spec.file));
    let Ok(text) = std::fs::read_to_string(path) else {
        return false;
    };
    let empty = format!("{}: \"\"", signal::ACCOUNT);
    text.lines()
        .any(|l| l.starts_with(&format!("{}:", signal::ACCOUNT)) && l.trim_end() != empty)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unit_states_pair_up() {
        let states = unit_states(&["a", "b", "c"], "active\nfailed\n");
        assert_eq!(
            states,
            [
                ("a", "active".to_owned()),
                ("b", "failed".to_owned()),
                ("c", "unknown".to_owned())
            ]
        );
    }
}
