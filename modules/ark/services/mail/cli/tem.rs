//! Scaleway Transactional Email from the laptop: the domains `ark push` made
//! (their ids read from the infra state) and their checks (through the
//! Scaleway CLI, with the infra keys). Both tools come from nixpkgs through
//! `nix run`, so this works outside the dev shell too.
use std::collections::BTreeMap;
use std::process::Command;

use anyhow::{Context, Result};
use serde::Deserialize;
use serde_json::Value;

use crate::secrets::Manifest;
use crate::service::Ctx;
use crate::util;

/// The infra secrets `ark push` gives the Scaleway provider (../default.nix).
const KEYS: [&str; 4] = ["SCW_ACCESS_KEY", "SCW_SECRET_KEY", "SCW_DEFAULT_ORGANIZATION_ID", "SCW_DEFAULT_PROJECT_ID"];

/// Each domain's id, by name, from the terraform output `output`, without
/// the `<region>/` the provider puts in front.
pub fn domain_ids(ctx: &Ctx, output: &str) -> Result<BTreeMap<String, String>> {
    let out = util::run(
        Command::new("nix")
            .args(["run", "--inputs-from", ".", "nixpkgs#opentofu", "--", "-chdir=infra", "output", "-json", output])
            .current_dir(&ctx.root),
        &format!("tofu output {output}"),
    )
    .with_context(|| format!("no `{output}` in the infra state yet: run `ark push` first"))?;
    let ids: BTreeMap<String, String> =
        serde_json::from_str(&out).with_context(|| format!("reading tofu output {output}"))?;
    Ok(ids.into_iter().map(|(name, id)| (name, id.rsplit('/').next().unwrap_or(&id).to_string())).collect())
}

/// The domain, as `scw tem domain get` has it.
#[derive(Deserialize)]
pub struct Domain {
    /// checked, unchecked, pending, invalid, locked, revoked or autoconfiguring.
    pub status: String,
    #[serde(default)]
    pub last_error: Option<String>,
    pub statistics: Statistics,
    #[serde(default)]
    pub reputation: Option<Reputation>,
}

#[derive(Deserialize)]
pub struct Statistics {
    pub total_count: u64,
    pub sent_count: u64,
    pub failed_count: u64,
}

#[derive(Deserialize)]
pub struct Reputation {
    pub status: String,
    pub score: u64,
}

/// `scw tem` as the infra key, in the mail region.
pub struct Scw {
    region: String,
    keys: Vec<(&'static str, String)>,
}

impl Scw {
    /// Reads the infra keys: one decryption of secrets/vars/infra.yaml.
    pub fn new(ctx: &Ctx, manifest: &Manifest, region: &str) -> Result<Scw> {
        let keys = KEYS.iter().map(|k| Ok((*k, manifest.read(ctx, k)?))).collect::<Result<_>>()?;
        Ok(Scw { region: region.to_string(), keys })
    }

    fn tem(&self, ctx: &Ctx, args: &[&str]) -> Result<Value> {
        let out = util::run(
            Command::new("nix")
                .args(["run", "--inputs-from", ".", "nixpkgs#scaleway-cli", "--", "tem"])
                .args(args)
                .args([&format!("region={}", self.region), "--output", "json"])
                .envs(self.keys.iter().map(|(k, v)| (k, v)))
                .current_dir(&ctx.root),
            &format!("scw tem {}", args.join(" ")),
        )?;
        serde_json::from_str(&out).with_context(|| format!("reading the output of scw tem {}", args.join(" ")))
    }

    pub fn domain(&self, ctx: &Ctx, id: &str) -> Result<Domain> {
        serde_json::from_value(self.tem(ctx, &["domain", "get", id])?).context("reading the TEM domain")
    }

    /// Asks Scaleway to check the domain's DNS records now rather than at
    /// its next scheduled check.
    pub fn check(&self, ctx: &Ctx, id: &str) -> Result<Domain> {
        serde_json::from_value(self.tem(ctx, &["domain", "check", id])?).context("reading the TEM domain")
    }
}
