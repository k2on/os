//! Aliases from the laptop: through mail-aliases's internal API on the
//! mail host (the tailnet; ../aliases/src/http.rs), with its key, and what a
//! person types into Bitwarden to make them.
use std::collections::BTreeMap;

use anyhow::{bail, Context, Result};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::secrets::Manifest;
use crate::service::Ctx;

/// `arkServiceConfig.mail.aliases`, from ../default.nix.
#[derive(Deserialize)]
pub struct Config {
    /// Aliases are <something>@<domain>.
    pub domain: String,
    url: String,
    endpoint: Option<String>,
    key: String,
    tokens: BTreeMap<String, String>,
}

#[derive(Deserialize)]
struct Alias {
    address: String,
    creator: String,
    target: String,
    site: Option<String>,
    created: String,
    active: bool,
}

fn endpoint(config: &Config) -> Result<&str> {
    config.endpoint.as_deref().context("no host runs mail, or it is not on the tailnet (`ark hosts`)")
}

fn internal(ctx: &Ctx, config: &Config, method: &str, path: &str, body: Option<Value>) -> Result<Value> {
    let key = Manifest::load(ctx)?.read(ctx, &config.key)?;
    let url = format!("{}{path}", endpoint(config)?);
    let request = ureq::request(method, &url).set("Authorization", &format!("Bearer {key}"));
    let response = match body {
        Some(body) => request.send_json(body),
        None => request.call(),
    };
    match response {
        Ok(r) => Ok(r.into_json()?),
        Err(ureq::Error::Status(_, r)) => {
            let reply: Value = r.into_json().unwrap_or_default();
            bail!("{}", reply["message"].as_str().unwrap_or("mail-aliases said no"))
        }
        Err(e) => Err(e).with_context(|| format!("reaching mail-aliases at {url} (is this laptop on the tailnet?)")),
    }
}

pub fn list(ctx: &Ctx, config: &Config) -> Result<()> {
    let aliases: Vec<Alias> = serde_json::from_value(internal(ctx, config, "GET", "/aliases", None)?)?;
    if aliases.is_empty() {
        println!("no aliases yet");
        return Ok(());
    }
    println!("{:<40} {:<10} {:<10} {:<16} {:<11} {}", "ALIAS", "GOES TO", "MADE BY", "SITE", "MADE", "ON");
    for a in aliases {
        println!(
            "{:<40} {:<10} {:<10} {:<16} {:<11} {}",
            a.address,
            a.target,
            a.creator,
            a.site.as_deref().unwrap_or("-"),
            a.created.get(..10).unwrap_or(&a.created),
            if a.active { "on" } else { "off" },
        );
    }
    Ok(())
}

pub fn set(ctx: &Ctx, config: &Config, address: &str, on: bool) -> Result<()> {
    internal(ctx, config, "PUT", &format!("/aliases/{address}"), Some(json!({ "active": on })))?;
    println!(
        "{address} is {}; the mail server restarts to pick that up (a few seconds)",
        if on { "on again" } else { "off: mail to it is refused" }
    );
    Ok(())
}

/// What goes into Bitwarden's username generator, for one person.
pub fn bitwarden(ctx: &Ctx, config: &Config, domain: &str, person: &str) -> Result<()> {
    let Some(secret) = config.tokens.get(person) else {
        bail!("{person} is not in ark.persons (there: {})", config.tokens.keys().cloned().collect::<Vec<_>>().join(", "));
    };
    let token = Manifest::load(ctx)?.read(ctx, secret)?;
    println!("In Bitwarden: Generator, Username, \"Forwarded email alias\", then:");
    println!("  Service            addy.io");
    println!("  Email domain       {domain}");
    println!("  API access token   {token}");
    println!("  Self-host server   {}", config.url);
    println!("Each alias goes to {person}, until the login holding it is saved in a group's vault.");
    Ok(())
}
