//! What ../../default.nix renders: who is who (from ark.persons), where
//! Immich's database is and where the pictures go.
use std::fs;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::Result;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    /// The directory Postgres's socket is in (.s.PGSQL.5432).
    pub socket: PathBuf,
    pub database: String,
    /// The role to connect as, by peer (or trust) authentication: no password.
    pub user: String,
    /// Where <name>.png are written, for nginx to serve.
    pub dir: PathBuf,
    /// How often the trigger is put back regardless (an Immich migration that
    /// rebuilds its user table would drop it) and everyone synced again.
    pub recheck_seconds: u64,
    /// Where the long poll (http.rs) listens, behind nginx; none if absent.
    #[serde(default)]
    pub listen: Option<String>,
    /// ImageMagick, to make PNGs of other kinds and the pictures cropped
    /// to a circle (image.rs).
    pub magick: PathBuf,
    pub persons: Vec<Person>,
}

#[derive(Deserialize)]
pub struct Person {
    /// Their username, which names the file and so the URL.
    pub name: String,
    /// Their address, which is their Immich account's (Kanidm gives it).
    pub mail: String,
}

impl Config {
    pub fn load(path: &Path) -> Result<Config> {
        let text = fs::read_to_string(path).map_err(|e| format!("reading {}: {e}", path.display()))?;
        Ok(serde_json::from_str(&text).map_err(|e| format!("reading {}: {e}", path.display()))?)
    }
}
