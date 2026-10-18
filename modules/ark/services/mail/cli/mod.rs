//! `ark service mail ...`: mail's way out, Amazon SES (../default.nix says
//! how it fits together). `ark push` makes SES's side: the domain, its DNS
//! records and an IAM user that may only send as it. What it cannot do is
//! here: store that user's SMTP login where the mail server reads it, and
//! ask AWS to take the account out of the sandbox, which a person at AWS
//! reviews.
//!
//! This file is found by ../../../cli/build.rs and compiled as a module of
//! the `ark` crate, like money's.
mod ses;

use std::collections::BTreeMap;

use anyhow::{Context, Result};
use clap::{ArgMatches, Command as Clap};
use serde::Deserialize;
use serde_json::Value;

use crate::secrets::Manifest;
use crate::service::{Ctx, Service};

pub static SERVICE: Service = Service {
    name: "mail",
    about: "Mail on the vps, and its way out through Amazon SES",
    command,
    run,
};

fn command() -> Clap {
    Clap::new("mail")
        .subcommand_required(true)
        .arg_required_else_help(true)
        .subcommand(
            Clap::new("init")
                .about("Store SES's SMTP login for the mail server, and ask AWS for production access")
                .long_about(
                    "After `ark push` has set SES up: store the SMTP login it made in secrets/vars/mail_ses.yaml \
                     (the mail server relays through SES once that is deployed: `ark push` again), and, if the \
                     account is still in the SES sandbox, ask AWS to take it out. That asks for a website and a \
                     few words on what the mail is; a person at AWS reviews it, usually within a day, and \
                     `status` shows how it went. Until then SES only delivers to addresses verified in it. Safe \
                     to run again.",
                ),
        )
        .subcommand(
            Clap::new("status")
                .about("Where SES stands: the domain's checks, sandbox or production, today's sending"),
        )
}

/// What ../default.nix exports as `arkServiceConfig.mail`.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Config {
    domain: String,
    region: String,
    ses_output: String,
    secrets: Secrets,
}

#[derive(Deserialize)]
struct Secrets {
    username: String,
    password: String,
}

fn run(ctx: &Ctx, m: &ArgMatches) -> Result<()> {
    let config: Config =
        serde_json::from_value(ctx.nix_eval("arkServiceConfig.mail")?).context("reading arkServiceConfig.mail")?;
    match m.subcommand() {
        Some(("init", _)) => init(ctx, &config),
        Some(("status", _)) => status(ctx, &config),
        _ => unreachable!("subcommand_required"),
    }
}

fn init(ctx: &Ctx, config: &Config) -> Result<()> {
    let manifest = Manifest::load(ctx)?;

    let login = ses::smtp_login(ctx, &config.ses_output)?;
    let stored = manifest.present(ctx, &config.secrets.password)
        && manifest.read(ctx, &config.secrets.username)? == login.username
        && manifest.read(ctx, &config.secrets.password)? == login.password;
    if stored {
        println!("SES login: already stored");
    } else {
        let file = &manifest.spec(&config.secrets.password)?.file;
        let values = BTreeMap::from([
            (config.secrets.username.clone(), login.username),
            (config.secrets.password.clone(), login.password),
        ]);
        manifest.store(ctx, file, &values)?;
        println!("SES login: stored in secrets/vars/{file}.yaml; `ark push` turns the relay on");
    }

    let aws = ses::Aws::new(ctx, &manifest, &config.region)?;
    let account = aws.account(ctx)?;
    if account.production_access_enabled {
        println!("SES: out of the sandbox, sending anywhere");
        return Ok(());
    }
    if let Some(status) = account.review().and_then(|r| r.status.as_deref()) {
        if status == "PENDING" {
            println!("SES: in the sandbox; the request to leave it is being reviewed (`status` to check)");
            return Ok(());
        }
        println!("SES: in the sandbox; the last request to leave it was {status}. Asking again.");
    }

    println!(
        "\nSES is in the sandbox: it only delivers to addresses verified in it. Asking AWS to lift that; a \
         person reads what you write here, so say it plainly."
    );
    let website = ctx.prompt("A website that is yours (AWS looks at it)")?;
    let default_use_case = format!(
        "Personal mail for a family at {domain}: a few people sending their own everyday mail (replies, \
         account sign-ups, receipts) from their own mailboxes on a self-hosted mail server, relayed through SES. \
         No marketing, newsletters or bulk mail, and no lists. Every recipient is someone a person here writes \
         to by hand. Bounces come back to bounce.{domain} and are read by the people who sent the mail.",
        domain = config.domain
    );
    println!("\nWhat the mail is (Enter for this):\n  {default_use_case}");
    let use_case = match ctx.prompt("Use case")? {
        typed if typed.trim().is_empty() => default_use_case,
        typed => typed,
    };
    aws.request_production(ctx, website.trim(), &use_case)?;
    println!("\nAsked. AWS answers by email, usually within a day; `ark service mail status` shows it too.");
    Ok(())
}

fn status(ctx: &Ctx, config: &Config) -> Result<()> {
    let manifest = Manifest::load(ctx)?;
    let stored = manifest.present(ctx, &config.secrets.password);
    println!("SMTP login:   {}", if stored { "stored" } else { "not stored: `ark service mail init`" });

    let aws = ses::Aws::new(ctx, &manifest, &config.region)?;
    let identity = aws.identity(ctx, &config.domain)?;
    let field = |path: &[&str]| {
        path.iter().fold(&identity, |v, key| &v[*key]).as_str().map(str::to_lowercase).unwrap_or("-".into())
    };
    println!(
        "{}:  verified {}, DKIM {}, MAIL FROM {}",
        config.domain,
        if identity["VerifiedForSendingStatus"] == Value::Bool(true) { "yes" } else { "no" },
        field(&["DkimAttributes", "Status"]),
        field(&["MailFromAttributes", "MailFromDomainStatus"]),
    );

    let account = aws.account(ctx)?;
    let review = account.review();
    let sandbox = if account.production_access_enabled {
        "production: sends anywhere".to_string()
    } else {
        match review.and_then(|r| r.status.as_deref()) {
            Some(status) => format!("sandbox; request to leave it: {}", status.to_lowercase()),
            None => "sandbox; nothing asked yet: `ark service mail init`".to_string(),
        }
    };
    println!("Account:      {sandbox}");
    if let Some(case) = review.and_then(|r| r.case_id.as_deref()) {
        println!("              AWS support case {case}");
    }
    let quota = &account.send_quota;
    println!(
        "Sending:      {} of {} today, at most {}/s",
        quota.sent_last24_hours, quota.max24_hour_send, quota.max_send_rate
    );
    Ok(())
}
