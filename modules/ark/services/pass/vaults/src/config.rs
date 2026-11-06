//! What ../default.nix renders: where Vaultwarden keeps its database and
//! the vaults, each with fixed ids (so a rename is a rename and not a second
//! one), the file holding its key, and who belongs in it.
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::Result;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    /// Vaultwarden's SQLite database.
    pub db: PathBuf,
    pub vaults: Vec<Vault>,
    /// Where aliases go (`pass-vaults aliases`, aliases.rs); none without mail.
    #[serde(default)]
    pub aliases: Option<Aliases>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Aliases {
    /// Aliases are <something>@<domain>.
    pub domain: String,
    /// mail-aliases's internal API, on the tailnet.
    pub endpoint: String,
    pub key_file: PathBuf,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Vault {
    /// The organization's id.
    pub id: String,
    /// The group (ark.groups) it is for, whose mailbox its aliases go to.
    pub group: String,
    pub name: String,
    /// Shown as the organization's billing address; Vaultwarden mails nothing to it.
    pub billing_email: String,
    /// The organization's symmetric key: 64 bytes in base64, the first half
    /// for AES, the second for the HMAC.
    pub key_file: PathBuf,
    pub collections: Vec<Collection>,
    /// One entry per person, by the address their OpenID login carries.
    pub members: Vec<Member>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Collection {
    pub id: String,
    pub name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Member {
    pub email: String,
    #[serde(default)]
    pub owner: bool,
}

impl Config {
    pub fn load(path: &Path) -> Result<Config> {
        let text = std::fs::read_to_string(path).map_err(|e| format!("reading {}: {e}", path.display()))?;
        serde_json::from_str(&text).map_err(|e| format!("parsing {}: {e}", path.display()).into())
    }
}
