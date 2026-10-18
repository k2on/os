//! Amazon SES from the laptop: the SMTP login `ark push` made (read from the
//! infra state) and the account's sandbox (through the AWS CLI, with the
//! infra keys). Both tools come from nixpkgs through `nix run`, so this
//! works outside the dev shell too.
use std::process::Command;

use anyhow::{Context, Result};
use serde::Deserialize;
use serde_json::Value;

use crate::secrets::Manifest;
use crate::service::Ctx;
use crate::util;

/// The infra secrets `ark push` gives the AWS provider (../default.nix).
const KEY_ID: &str = "AWS_ACCESS_KEY_ID";
const KEY_SECRET: &str = "AWS_SECRET_ACCESS_KEY";

#[derive(Deserialize, PartialEq)]
pub struct Login {
    pub username: String,
    pub password: String,
}

/// The SMTP login from the terraform output `output` (sensitive, so only
/// `tofu output -json` shows it).
pub fn smtp_login(ctx: &Ctx, output: &str) -> Result<Login> {
    let out = util::run(
        Command::new("nix")
            .args(["run", "--inputs-from", ".", "nixpkgs#opentofu", "--", "-chdir=infra", "output", "-json", output])
            .current_dir(&ctx.root),
        &format!("tofu output {output}"),
    )
    .with_context(|| format!("no `{output}` in the infra state yet: run `ark push` first"))?;
    serde_json::from_str(&out).with_context(|| format!("reading tofu output {output}"))
}

/// The account, as `aws sesv2 get-account` has it.
#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct Account {
    pub production_access_enabled: bool,
    pub send_quota: Quota,
    pub details: Option<Details>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct Quota {
    pub max24_hour_send: f64,
    pub max_send_rate: f64,
    pub sent_last24_hours: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct Details {
    pub review_details: Option<Review>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct Review {
    /// PENDING, GRANTED, DENIED or FAILED.
    pub status: Option<String>,
    pub case_id: Option<String>,
}

impl Account {
    /// The production-access request's review, if one was made.
    pub fn review(&self) -> Option<&Review> {
        self.details.as_ref()?.review_details.as_ref()
    }
}

/// `aws sesv2` as the infra user, in the mail region.
pub struct Aws {
    region: String,
    key_id: String,
    key_secret: String,
}

impl Aws {
    /// Reads the infra keys: one decryption of secrets/vars/infra.yaml.
    pub fn new(ctx: &Ctx, manifest: &Manifest, region: &str) -> Result<Aws> {
        Ok(Aws {
            region: region.to_string(),
            key_id: manifest.read(ctx, KEY_ID)?,
            key_secret: manifest.read(ctx, KEY_SECRET)?,
        })
    }

    fn sesv2(&self, ctx: &Ctx, args: &[&str]) -> Result<Value> {
        let out = util::run(
            Command::new("nix")
                .args(["run", "--inputs-from", ".", "nixpkgs#awscli2", "--", "sesv2"])
                .args(args)
                .args(["--region", &self.region, "--output", "json"])
                .env("AWS_ACCESS_KEY_ID", &self.key_id)
                .env("AWS_SECRET_ACCESS_KEY", &self.key_secret)
                .current_dir(&ctx.root),
            &format!("aws sesv2 {}", args[0]),
        )?;
        if out.trim().is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_str(&out).with_context(|| format!("reading the output of aws sesv2 {}", args[0]))
    }

    pub fn account(&self, ctx: &Ctx) -> Result<Account> {
        serde_json::from_value(self.sesv2(ctx, &["get-account"])?).context("reading the SES account")
    }

    /// The domain's identity: verification, DKIM, MAIL FROM.
    pub fn identity(&self, ctx: &Ctx, domain: &str) -> Result<Value> {
        self.sesv2(ctx, &["get-email-identity", "--email-identity", domain])
    }

    /// Asks AWS to take the account out of the sandbox; a person reviews it.
    pub fn request_production(&self, ctx: &Ctx, website: &str, use_case: &str) -> Result<()> {
        self.sesv2(
            ctx,
            &[
                "put-account-details",
                "--production-access-enabled",
                "--mail-type",
                "TRANSACTIONAL",
                "--website-url",
                website,
                "--use-case-description",
                use_case,
                "--contact-language",
                "EN",
            ],
        )
        .map(|_| ())
    }
}
