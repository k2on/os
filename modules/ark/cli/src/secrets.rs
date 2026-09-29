//! `ark secrets`, and the sops plumbing service commands use to read and
//! write secrets. Mirrors modules/ark/lib/secrets.nix: that module exports the
//! `arkSecrets` flake output (which secret lives in which secrets/vars file,
//! its recipients, how to generate it), this side makes the files match.
//!
//! Creating never decrypts (age recipients are public). Reading, rekeying, or
//! adding a key to a file that already exists decrypts that file: one yubikey
//! touch per file per run, since the plaintext is kept in Ctx afterwards.
//! Secrets a CLI reads together should therefore share a file (`file = ...`
//! in the nix declaration).
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use anyhow::{bail, Context, Result};
use serde::Deserialize;
use serde_json::{Map, Value};

use crate::service::Ctx;
use crate::util;

#[derive(Deserialize, Clone)]
pub struct Spec {
    /// File under secrets/vars (without .yaml) holding this secret.
    pub file: String,
    /// Shell script whose stdout is the value; None means entered by hand.
    pub generate: Option<String>,
    pub hosts: Vec<String>,
    pub recipients: Vec<String>,
}

#[derive(Deserialize)]
pub struct Manifest {
    pub secrets: BTreeMap<String, Spec>,
    #[serde(rename = "sopsConfig")]
    pub sops_config: Value,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum State {
    Ok,
    Missing,
    /// Present, but encrypted to a different set of recipients.
    Rekey,
}

pub fn vars_dir(ctx: &Ctx) -> PathBuf {
    ctx.root.join("secrets/vars")
}

impl Manifest {
    pub fn load(ctx: &Ctx) -> Result<Manifest> {
        serde_json::from_value(ctx.nix_eval("arkSecrets")?).context("reading the arkSecrets flake output")
    }

    pub fn spec(&self, key: &str) -> Result<&Spec> {
        self.secrets
            .get(key)
            .with_context(|| format!("secret '{key}' is not declared anywhere in the nix config"))
    }

    pub fn state(&self, ctx: &Ctx, key: &str) -> Result<State> {
        let spec = self.spec(key)?;
        let Ok(text) = fs::read_to_string(vars_dir(ctx).join(format!("{}.yaml", spec.file))) else {
            return Ok(State::Missing);
        };
        if !text.lines().any(|l| l.starts_with(&format!("{key}:"))) {
            return Ok(State::Missing);
        }
        let have: BTreeSet<&str> = text
            .split("recipient: ")
            .skip(1)
            .map(|rest| rest.split(|c: char| !c.is_ascii_alphanumeric()).next().unwrap_or(""))
            .collect();
        let want: BTreeSet<&str> = spec.recipients.iter().map(String::as_str).collect();
        Ok(if have == want { State::Ok } else { State::Rekey })
    }

    pub fn present(&self, ctx: &Ctx, key: &str) -> bool {
        !matches!(self.state(ctx, key), Ok(State::Missing) | Err(_))
    }

    /// The plaintext of secrets/vars/<file>.yaml: decrypted the first time it
    /// is asked for in this run (one yubikey touch), remembered after.
    fn plaintext(&self, ctx: &Ctx, file: &str) -> Result<Map<String, Value>> {
        if let Some(cached) = ctx.decrypted.borrow().get(file) {
            return Ok(cached.clone());
        }
        let name = format!("{file}.yaml");
        let out = util::capture(
            ctx.sops_decrypting()?.args(["-d", "--output-type", "json", &name]).current_dir(vars_dir(ctx)),
            &format!("sops -d {name}"),
        )
        .with_context(|| format!("decrypting secrets/vars/{name}"))?;
        let Value::Object(values) = serde_json::from_str(&out).with_context(|| format!("reading decrypted {name}"))?
        else {
            bail!("secrets/vars/{name} does not hold a mapping");
        };
        ctx.decrypted.borrow_mut().insert(file.to_string(), values.clone());
        Ok(values)
    }

    /// One secret's value.
    pub fn read(&self, ctx: &Ctx, key: &str) -> Result<String> {
        let file = &self.spec(key)?.file;
        match self.plaintext(ctx, file)?.get(key) {
            Some(Value::String(s)) => Ok(s.clone()),
            Some(other) => Ok(other.to_string()),
            None => bail!("{key} is not in secrets/vars/{file}.yaml; run `ark secrets`"),
        }
    }

    /// Writes secrets/vars/.sops.yaml so plain `sops <file>` works there too.
    pub fn write_sops_config(&self, ctx: &Ctx) -> Result<()> {
        let dir = vars_dir(ctx);
        fs::create_dir_all(&dir)?;
        fs::write(dir.join(".sops.yaml"), serde_json::to_string_pretty(&self.sops_config)? + "\n")
            .context("writing secrets/vars/.sops.yaml")
    }

    /// Encrypts `values` into secrets/vars/<file>.yaml, merged with what is
    /// already there, and stages the result. Decrypts only if the file exists
    /// and was not read or written earlier in this run.
    pub fn store(&self, ctx: &Ctx, file: &str, values: &BTreeMap<String, String>) -> Result<()> {
        self.write_sops_config(ctx)?;
        let dir = vars_dir(ctx);
        let name = format!("{file}.yaml");
        let path = dir.join(&name);

        let mut merged = if path.exists() { self.plaintext(ctx, file)? } else { Map::new() };
        for (k, v) in values {
            merged.insert(k.clone(), Value::String(v.clone()));
        }

        let mut sops = Command::new("sops")
            .args(["--input-type", "json", "--output-type", "yaml", "--filename-override", &name, "-e", "/dev/stdin"])
            .current_dir(&dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .context("starting sops")?;
        sops.stdin
            .take()
            .expect("piped stdin")
            .write_all(serde_json::to_string(&Value::Object(merged.clone()))?.as_bytes())?;
        let out = sops.wait_with_output()?;
        if !out.status.success() {
            bail!("sops -e {name} failed ({})", out.status);
        }
        let tmp = dir.join(format!("{name}.tmp"));
        fs::write(&tmp, &out.stdout)?;
        fs::rename(&tmp, &path).with_context(|| format!("writing secrets/vars/{name}"))?;
        ctx.decrypted.borrow_mut().insert(file.to_string(), merged);
        ctx.git_secrets(&["add", &format!("vars/{name}"), "vars/.sops.yaml"])
    }
}

/// `ark secrets [--dry-run]`: list every declared secret; create the missing
/// ones (generated or prompted), rekey the ones whose recipients changed.
pub fn run(ctx: &Ctx, dry_run: bool) -> Result<()> {
    let manifest = Manifest::load(ctx)?;
    if !dry_run {
        manifest.write_sops_config(ctx)?;
    }

    let mut missing: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut rekey: BTreeSet<String> = BTreeSet::new();
    println!("{:<32} {:<8} {:<9} {:<12} {}", "SECRET", "STATE", "SOURCE", "FILE", "HOSTS");
    for (key, spec) in &manifest.secrets {
        let state = manifest.state(ctx, key)?;
        let hosts = if spec.hosts.is_empty() { "(admin only)".to_string() } else { spec.hosts.join(" ") };
        let source = if spec.generate.is_some() { "generate" } else { "prompt" };
        let file = if spec.file == *key { "" } else { spec.file.as_str() };
        let shown = match state {
            State::Ok => "ok",
            State::Missing => "missing",
            State::Rekey => "rekey",
        };
        println!("{key:<32} {shown:<8} {source:<9} {file:<12} {hosts}");
        match state {
            State::Missing => missing.entry(spec.file.clone()).or_default().push(key.clone()),
            State::Rekey => {
                rekey.insert(spec.file.clone());
            }
            State::Ok => {}
        }
    }
    // Files nothing declares anymore (a secret moved or went away): left alone, but said.
    let declared: BTreeSet<String> = manifest.secrets.values().map(|s| format!("{}.yaml", s.file)).collect();
    let mut stray: Vec<String> = fs::read_dir(vars_dir(ctx))
        .map(|dir| {
            dir.flatten()
                .filter_map(|e| e.file_name().into_string().ok())
                .filter(|n| n.ends_with(".yaml") && !n.starts_with('.') && !declared.contains(n))
                .collect()
        })
        .unwrap_or_default();
    stray.sort();
    if !stray.is_empty() {
        println!("\nnot declared by anything (safe to delete): {}", stray.join(" "));
    }

    if dry_run {
        return Ok(());
    }

    for file in &rekey {
        let name = format!("{file}.yaml");
        util::status(
            ctx.sops_decrypting()?.args(["updatekeys", "-y", &name]).current_dir(vars_dir(ctx)),
            &format!("sops updatekeys {name}"),
        )
        .with_context(|| format!("rekeying {name}"))?;
        ctx.git_secrets(&["add", &format!("vars/{name}")])?;
    }

    for (file, keys) in &missing {
        let mut values = BTreeMap::new();
        for key in keys {
            let value = match &manifest.secrets[key].generate {
                Some(script) => util::run(Command::new("bash").args(["-c", script]), &format!("generating {key}"))?
                    .trim_end_matches('\n')
                    .to_string(),
                None => ctx.prompt_hidden(&format!("  enter {key}"))?,
            };
            values.insert(key.clone(), value);
        }
        manifest.store(ctx, file, &values)?;
    }
    Ok(())
}
