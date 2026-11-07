//! `ark service mail ...`: mail's way out, Scaleway Transactional Email,
//! and its aliases (../default.nix says how it fits together).
//!
//! TEM: `ark push` makes all of it, the login on the vps included; here is
//! whether Scaleway has passed each domain's records, and asking it to
//! check them again (tem.rs).
//!
//! Aliases: list them, turn one off, and what to type into Bitwarden to
//! make them (aliases.rs).
//!
//! This file is found by ../../../cli/build.rs and compiled as a module of
//! the `ark` crate, like money's.
mod aliases;
mod tem;

use anyhow::{Context, Result};
use clap::{Arg, ArgMatches, Command as Clap};
use serde::Deserialize;

use crate::secrets::Manifest;
use crate::service::{Ctx, Service};

pub static SERVICE: Service = Service {
    name: "mail",
    about: "Mail on the vps, and its way out through Scaleway Transactional Email",
    command,
    run,
};

fn command() -> Clap {
    Clap::new("mail")
        .subcommand_required(true)
        .arg_required_else_help(true)
        .subcommand(
            Clap::new("status").about("Where TEM stands, for each domain: its checks, its reputation, what it sent"),
        )
        .subcommand(
            Clap::new("relay")
                .about("Copy Stalwart's SMTP login at TEM from the infra state into sops")
                .long_about(
                    "Copy Stalwart's SMTP login at TEM (the key `ark push` made) from the infra state into \
                     secrets/vars/mail_relay.yaml, encrypted to the mail host, which comin then deploys. \
                     After the first `ark push`, and whenever the key is replaced.",
                ),
        )
        .subcommand(Clap::new("aliases").about("Every alias: where it goes, who made it, for which site, whether it is on"))
        .subcommand(
            Clap::new("alias")
                .about("Turn an alias off (mail to it is refused) or on again")
                .arg(Arg::new("address").required(true).help("The alias, e.g. expedia-k7m2x@<domain>"))
                .arg(Arg::new("state").required(true).value_parser(["on", "off"])),
        )
        .subcommand(
            Clap::new("bitwarden")
                .about("What to type into Bitwarden's username generator to make aliases")
                .long_about(
                    "What to type into Bitwarden's username generator (Forwarded email alias, addy.io) so it \
                     makes aliases for this person: the server, the domain, and their token \
                     (mail_alias_token_<person>; one yubikey touch to read it).",
                )
                .arg(Arg::new("person").required(true).help("Whose aliases, by username")),
        )
}

/// What ../default.nix exports as `arkServiceConfig.mail`.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Config {
    region: String,
    domains_output: String,
    relay_output: String,
    aliases: aliases::Config,
}

fn config(ctx: &Ctx) -> Result<Config> {
    serde_json::from_value(ctx.nix_eval("arkServiceConfig.mail")?).context("reading arkServiceConfig.mail")
}

fn run(ctx: &Ctx, m: &ArgMatches) -> Result<()> {
    let config = config(ctx)?;
    match m.subcommand() {
        Some(("status", _)) => status(ctx, &config),
        Some(("relay", _)) => relay(ctx, &config),
        Some(("aliases", _)) => aliases::list(ctx, &config.aliases),
        Some(("alias", m)) => aliases::set(
            ctx,
            &config.aliases,
            m.get_one::<String>("address").expect("required"),
            m.get_one::<String>("state").expect("required") == "on",
        ),
        Some(("bitwarden", m)) => {
            aliases::bitwarden(ctx, &config.aliases, &config.aliases.domain, m.get_one::<String>("person").expect("required"))
        }
        _ => unreachable!("subcommand_required"),
    }
}

/// Each domain's checks, reputation and sending; while a domain's checks
/// have not passed, asks Scaleway to run them now rather than at its next
/// round.
fn status(ctx: &Ctx, config: &Config) -> Result<()> {
    let ids = tem::domain_ids(ctx, &config.domains_output)?;
    let scw = tem::Scw::new(ctx, &Manifest::load(ctx)?, &config.region)?;
    for (name, id) in &ids {
        let mut domain = scw.domain(ctx, id)?;
        if domain.status != "checked" {
            domain = scw.check(ctx, id)?;
        }
        println!("{name}:  {}", domain.status);
        if let Some(error) = domain.last_error.as_deref().filter(|e| !e.is_empty()) {
            println!("  last check: {error}");
        }
        if domain.status != "checked" {
            println!("  Scaleway sends nothing for it until its records pass; DNS can take a while");
        }
        if let Some(r) = &domain.reputation {
            println!("  reputation: {} ({}/100)", r.status, r.score);
        }
        let s = &domain.statistics;
        println!("  sent:       {} of {} ({} failed)", s.sent_count, s.total_count, s.failed_count);
    }
    Ok(())
}

/// The SMTP login from the infra state into sops, both halves in one file.
fn relay(ctx: &Ctx, config: &Config) -> Result<()> {
    let (username, password) = tem::relay_login(ctx, &config.relay_output)?;
    let values = [("mail_relay_username", username), ("mail_relay_password", password)]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
    Manifest::load(ctx)?.store(ctx, "mail_relay", &values)?;
    println!("secrets/vars/mail_relay.yaml: written and staged. Commit the secrets repo, then this one, and push.");
    Ok(())
}
