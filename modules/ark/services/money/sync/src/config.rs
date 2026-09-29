//! The JSON at $MONEY_SYNC_CONFIG (see ../default.nix for how it is rendered).
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::Value;

use crate::Result;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    /// Passed through to actual-import untouched:
    /// { serverURL, tokenFile, syncId?, encryptionPasswordFile? }.
    pub actual: Value,
    pub plaid: PlaidConfig,
    /// Actual account name -> the Plaid account feeding it.
    pub accounts: BTreeMap<String, Mapping>,
    pub state_file: PathBuf,
    /// The actual-import executable.
    pub actual_import: PathBuf,
    /// Everyone kanidm lets into the money service. `seed` creates their
    /// Actual users ahead of time so the shared budget is already theirs on
    /// their first login.
    #[serde(default)]
    pub members: Vec<Member>,
}

#[derive(Deserialize)]
pub struct Member {
    /// The username Actual sees at login (kanidm's short username).
    pub name: String,
    /// In the service's admin group: an Actual server admin too.
    #[serde(default)]
    pub admin: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaidConfig {
    pub env: String,
    /// Tests point this at a mock.
    pub base_url: Option<String>,
    pub client_id_file: PathBuf,
    pub secret_file: PathBuf,
    /// Linked banks by name; each token is a file.
    pub items: BTreeMap<String, Item>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub access_token_file: PathBuf,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Mapping {
    pub item: String,
    pub mask: Option<String>,
    pub account_id: Option<String>,
}

impl Config {
    pub fn load() -> Result<Config> {
        let path = std::env::var("MONEY_SYNC_CONFIG").map_err(|_| "MONEY_SYNC_CONFIG is not set")?;
        let text = fs::read_to_string(&path).map_err(|e| format!("{path}: {e}"))?;
        Ok(serde_json::from_str(&text).map_err(|e| format!("{path}: {e}"))?)
    }
}

pub fn read_secret(path: &Path) -> Result<String> {
    let text = fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(text.trim().to_string())
}
