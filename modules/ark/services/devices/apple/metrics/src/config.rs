//! The config file, written by Nix (../default.nix).
use std::path::PathBuf;

use serde_json::Value;

use crate::Result;

pub struct Device {
    pub name: String,
    pub udid: String,
    pub owner: String,
}

pub struct Config {
    /// Where nanohub's webhook reaches this, on loopback.
    pub listen: String,
    /// The .prom file in node_exporter's textfile directory.
    pub output: PathBuf,
    pub nanohub: String,
    pub nanohub_key: PathBuf,
    pub depserver: Option<String>,
    pub depserver_key: Option<PathBuf>,
    pub dep_names: Vec<String>,
    pub push_cert: Option<PathBuf>,
    pub vpp_token: Option<PathBuf>,
    pub devices: Vec<Device>,
    pub refresh: u64,
    pub query: u64,
}

impl Config {
    pub fn load(path: &str) -> Result<Config> {
        let text = std::fs::read_to_string(path).map_err(|e| format!("reading {path}: {e}"))?;
        let v: Value = serde_json::from_str(&text).map_err(|e| format!("{path}: {e}"))?;
        let s = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
        let need = |k: &str| s(k).ok_or_else(|| format!("{path}: no {k}"));
        let path_of = |k: &str| s(k).map(PathBuf::from);
        Ok(Config {
            listen: need("listen")?,
            output: need("output")?.into(),
            nanohub: need("nanohub")?.trim_end_matches('/').to_string(),
            nanohub_key: need("nanohubKey")?.into(),
            depserver: s("depserver").map(|u| u.trim_end_matches('/').to_string()),
            depserver_key: path_of("depserverKey"),
            dep_names: strings(&v, "depNames"),
            push_cert: path_of("pushCert"),
            vpp_token: path_of("vppToken"),
            devices: v
                .get("devices")
                .and_then(Value::as_array)
                .map(|ds| {
                    ds.iter()
                        .filter_map(|d| {
                            Some(Device {
                                name: d.get("name")?.as_str()?.to_string(),
                                udid: d.get("udid")?.as_str()?.to_string(),
                                owner: d.get("owner").and_then(Value::as_str).unwrap_or("").to_string(),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default(),
            refresh: v.get("refresh").and_then(Value::as_u64).unwrap_or(300),
            query: v.get("query").and_then(Value::as_u64).unwrap_or(3600),
        })
    }
}

fn strings(v: &Value, key: &str) -> Vec<String> {
    v.get(key)
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|s| s.as_str().map(str::to_string)).collect())
        .unwrap_or_default()
}
