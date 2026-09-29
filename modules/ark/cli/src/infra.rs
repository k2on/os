//! `ark plan | push | destroy`: terranix through tofu, with the provider
//! tokens in the environment.
use std::fs;

use anyhow::{bail, Result};

use crate::secrets::{vars_dir, Manifest};
use crate::service::Ctx;
use crate::util;

/// The tokens all live in one file (secrets/vars/infra.yaml, see
/// lib/secrets.nix), so this is one decryption and one yubikey touch. Refuses
/// to start if a token is missing; the key names are plaintext in the sops
/// file, so that check needs no touch.
pub fn run(ctx: &Ctx, action: &str) -> Result<()> {
    let manifest = Manifest::load(ctx)?;
    let infra = fs::read_to_string(vars_dir(ctx).join("infra.yaml")).unwrap_or_default();
    let missing: Vec<&str> = manifest
        .secrets
        .iter()
        .filter(|(key, spec)| spec.file == "infra" && !infra.lines().any(|l| l.starts_with(&format!("{key}:"))))
        .map(|(key, _)| key.as_str())
        .collect();
    if !missing.is_empty() {
        bail!(
            "infra secrets missing from secrets/vars/infra.yaml: {}\nrun `ark secrets` to enter them",
            missing.join(" ")
        );
    }
    // terranix's generated apply script ends in a bare `tofu apply` that never
    // forwards arguments, so the approval prompt is answered on the terminal.
    util::status(
        ctx.sops_decrypting()?
            .args(["exec-env", "secrets/vars/infra.yaml", &format!("nix run \".?submodules=1#infra.{action}\"")])
            .current_dir(&ctx.root),
        &format!("infra {action}"),
    )
}
