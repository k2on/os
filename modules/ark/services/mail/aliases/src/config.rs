//! What ../../default.nix renders: the accounts (from ark.persons and
//! ark.groups) and where things live. Secrets are paths to their files.
use std::fs;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::Result;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    /// The aliases.
    pub db: PathBuf,
    /// Written whenever an alias changes; Stalwart restarts on it (it reads
    /// its accounts, aliases included, when it starts: render.rs).
    pub changed_file: PathBuf,
    /// Aliases are <something>@<domain>.
    pub domain: String,
    /// Where Bitwarden's requests arrive (behind nginx).
    pub listen: String,
    /// Where adam and `ark` reach the rest (the tailnet).
    pub internal_listen: String,
    pub internal_key_file: PathBuf,
    pub persons: Vec<Person>,
    pub groups: Vec<Group>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Person {
    pub name: String,
    pub address: String,
    pub password_file: PathBuf,
    /// The token Bitwarden sends for them.
    pub token_file: PathBuf,
    pub groups: Vec<String>,
}

#[derive(Deserialize)]
pub struct Group {
    pub name: String,
    pub address: String,
}

impl Config {
    pub fn load(path: &Path) -> Result<Config> {
        let text = fs::read_to_string(path).map_err(|e| format!("reading {}: {e}", path.display()))?;
        Ok(serde_json::from_str(&text).map_err(|e| format!("reading {}: {e}", path.display()))?)
    }
}

/// A secret's file, without the line end an editor may have added.
pub fn secret(path: &Path) -> Result<String> {
    let text = fs::read_to_string(path).map_err(|e| format!("reading {}: {e}", path.display()))?;
    Ok(text.trim_end_matches(['\n', '\r']).to_string())
}
