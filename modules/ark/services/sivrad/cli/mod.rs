//! `ark service sivrad ...`: set up the sivrad VM from a laptop. Commands
//! drive the VM over ssh (as `sivrad`, at its tailnet name) and keep what
//! has to survive a rebuild in the secrets repo: the people table, the
//! Kanidm group that follows it, and the Signal account. The Claude Code
//! login lives on the VM's state volume.
//!
//! This file is found by ../../../cli/build.rs and compiled as a module of
//! the `ark` crate, like money's.
mod people;
mod signal;

use std::process::{Command, Output, Stdio};

use anyhow::{bail, Context, Result};
use clap::{ArgMatches, Command as Clap};
use serde::Deserialize;
use serde_json::Value;

use crate::secrets::Manifest;
use crate::service::{Ctx, Service};
use crate::util;

pub static SERVICE: Service = Service {
    name: "sivrad",
    about: "The sivrad assistant VM: people, the Claude login, Signal",
    command,
    run,
};

fn command() -> Clap {
    Clap::new("sivrad")
        .subcommand_required(true)
        .arg_required_else_help(true)
        .subcommand(
            Clap::new("init")
                .about("First-time setup, step by step; skips what is already done")
                .long_about(
                    "First-time setup; run it again any time, it skips what is already done. Makes sure \
                     the secrets exist (asking who may talk to sivrad), logs Claude Code in inside the VM \
                     over ssh (the browser flow), and says what is left: the Signal account and accepting \
                     the development-channel warning.",
                ),
        )
        .subcommand(people::command())
        .subcommand(signal::command())
}

fn run(ctx: &Ctx, m: &ArgMatches) -> Result<()> {
    match m.subcommand() {
        Some(("init", _)) => init(ctx),
        Some(("people", m)) => people::run(ctx, m),
        Some(("signal", m)) => signal::run(ctx, m),
        _ => unreachable!("subcommand_required"),
    }
}

/// What the nix side exports for us: the `arkServiceConfig.sivrad` flake
/// output, defined in ../default.nix from ../_vm.nix.
#[derive(Deserialize)]
pub struct Config {
    /// The VM's tailnet name; null when no host runs headscale.
    host: Option<String>,
    user: String,
    signal: SignalConfig,
    /// Kanidm usernames (ark.persons).
    persons: Vec<String>,
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
            "the VM has no tailnet name: some host has to run headscale (its dns.base_domain names it)",
        )?;
        Ok(Vm {
            target: format!("{}@{host}", self.user),
        })
    }
}

/// The VM, over ssh. Its tailnet name is new to known_hosts the first time;
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

/// What `claude auth status --json` says (claude-code 2.1).
fn logged_in(status: &str) -> Option<bool> {
    serde_json::from_str::<Value>(status.trim())
        .ok()?
        .get("loggedIn")?
        .as_bool()
}

/// Claude Code in the VM runs from the sivrad service's environment; these
/// match it for commands run over ssh.
const CLAUDE_ENV: &str = "DISABLE_AUTOUPDATER=1";

/// `ark service sivrad init`.
fn init(ctx: &Ctx) -> Result<()> {
    let cfg = Config::load(ctx)?;
    let manifest = Manifest::load(ctx)?;

    println!("1. Secrets");
    let created = init_secrets(ctx, &cfg, &manifest)?;
    if created {
        println!("   Commit secrets/ and deploy adam so the VM gets them.");
    }

    println!("2. Claude Code in the VM");
    let vm = cfg.vm()?;
    let reach = vm.probe("true")?;
    if !reach.status.success() {
        bail!(
            "cannot reach {vm} over ssh ({}). Is adam deployed and the VM up on the tailnet? Then run \
             `ark service sivrad init` again",
            String::from_utf8_lossy(&reach.stderr).trim()
        );
    }
    init_claude(&vm)?;

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
                println!("   It is not saved in the secrets repo yet: ark service sivrad signal backup");
            }
        }
        Err(e) => println!("   Could not ask signal-cli in the VM: {e:#}"),
    }

    println!(
        "\nLeft to do by hand: attach to the session once and accept the development-channel warning \
         (it comes back after every restart of the session):\n\n  ssh -t {vm} tmux attach -t sivrad\n\n\
         (detach with Ctrl-b d). Then, in the sivrad app, enter http://sivrad:8788 and sign in."
    );
    Ok(())
}

/// The people table (and its people.nix) and the Signal backup placeholders.
/// True when anything was created.
fn init_secrets(ctx: &Ctx, cfg: &Config, manifest: &Manifest) -> Result<bool> {
    let mut created = false;
    if manifest.present(ctx, people::SECRET) {
        if people::people_nix_exists(ctx) {
            println!("   {} exists", people::SECRET);
        } else {
            // From before people.nix: give the Kanidm group the table's people.
            let table = people::load(ctx, manifest)?;
            people::write_people_nix(ctx, &table)?;
            println!(
                "   {} exists; wrote secrets/services/sivrad/people.nix from it",
                people::SECRET
            );
            created = true;
        }
    } else {
        let table = people::prompt_people(ctx, cfg)?;
        people::save(ctx, manifest, &table)?;
        println!("   stored {}", people::SECRET);
        created = true;
    }

    let missing: Vec<&str> = [signal::NUMBER, signal::ACCOUNT]
        .into_iter()
        .filter(|key| !manifest.present(ctx, key))
        .collect();
    if missing.is_empty() {
        println!("   {} and {} exist", signal::NUMBER, signal::ACCOUNT);
    } else {
        // Empty until an account is registered; adam needs them to build.
        let values: Vec<(&str, String)> = missing.iter().map(|k| (*k, String::new())).collect();
        signal::store(ctx, manifest, &values)?;
        println!("   created {} (empty for now)", missing.join(" and "));
        created = true;
    }
    Ok(created)
}

/// Logs Claude Code in if it is not, then restarts the session so it picks
/// the login up.
fn init_claude(vm: &Vm) -> Result<()> {
    let status = vm.probe(&format!("{CLAUDE_ENV} claude auth status --json"))?;
    let has_auth = match logged_in(&String::from_utf8_lossy(&status.stdout)) {
        Some(true) => {
            println!("   logged in");
            return Ok(());
        }
        Some(false) => true,
        // An older claude without `claude auth`: look for the login itself.
        None => {
            if vm
                .probe("test -s ~/.claude/.credentials.json")?
                .status
                .success()
            {
                println!("   logged in");
                return Ok(());
            }
            false
        }
    };

    if !has_auth {
        println!(
            "   Not logged in, and this claude has no `claude auth login`. Attach to the session and log \
             in there (/login), then detach with Ctrl-b d:\n\n     ssh -t {vm} tmux attach -t sivrad\n"
        );
        return Ok(());
    }

    println!(
        "   Not logged in. Logging in inside the VM: open the link it prints, sign in, and paste the code \
         back here."
    );
    vm.interactive(&format!("{CLAUDE_ENV} claude auth login"))
        .context("claude auth login in the VM")?;
    let status = vm.probe(&format!("{CLAUDE_ENV} claude auth status --json"))?;
    if logged_in(&String::from_utf8_lossy(&status.stdout)) != Some(true) {
        bail!("Claude Code in the VM still is not logged in; run `ark service sivrad init` again");
    }
    // The running session started logged out; ending it makes systemd start a
    // fresh one (tmux exits with its last session) that has the login.
    vm.output("tmux kill-session -t sivrad 2>/dev/null || true")?;
    println!("   logged in; restarted the session, which is back in about 30 seconds");
    Ok(())
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
    fn claude_auth_status() {
        assert_eq!(
            logged_in(r#"{ "loggedIn": true, "authMethod": "claude.ai" }"#),
            Some(true)
        );
        assert_eq!(logged_in("{\n  \"loggedIn\": false\n}\n"), Some(false));
        assert_eq!(logged_in("error: unknown command 'auth'"), None);
        assert_eq!(logged_in(""), None);
    }
}
