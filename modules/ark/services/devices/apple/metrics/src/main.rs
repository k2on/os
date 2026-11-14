//! apple-devices-metrics: the household's Apple devices and their MDM as
//! Prometheus metrics (../default.nix), written to node_exporter's textfile
//! directory, so the node job brings them in with the host's labels.
//!
//!   apple-devices-metrics <config.json>
//!
//! Every `refresh` seconds it asks nanohub's API how each device's
//! declarations are doing and what it last reported (nanohub.rs), reads
//! when the push certificate and the two Apple tokens expire (expiry.rs),
//! and writes it all out at once (metrics.rs). Every `query` seconds it
//! asks each device for its battery and storage (DeviceInformation); the
//! answers come back through nanohub's webhook (webhook.rs) and are in the
//! next write.
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

mod base64;
mod config;
mod expiry;
mod metrics;
mod nanohub;
mod plist;
mod time;
mod webhook;

pub use config::Config;

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

/// What a device last answered to DeviceInformation, by UDID.
pub type Answers = Arc<Mutex<HashMap<String, webhook::DeviceInformation>>>;

fn main() {
    let Some(path) = std::env::args().nth(1) else {
        eprintln!("usage: apple-devices-metrics <config.json>");
        std::process::exit(2);
    };
    let config = match Config::load(&path) {
        Ok(c) => Arc::new(c),
        Err(e) => {
            eprintln!("apple-devices-metrics: {e}");
            std::process::exit(1);
        }
    };
    let answers: Answers = Arc::default();

    {
        let (config, answers) = (config.clone(), answers.clone());
        std::thread::spawn(move || {
            if let Err(e) = webhook::serve(&config.listen, answers) {
                eprintln!("apple-devices-metrics: webhook: {e}");
                std::process::exit(1);
            }
        });
    }
    {
        let config = config.clone();
        std::thread::spawn(move || loop {
            for device in &config.devices {
                if let Err(e) = nanohub::ask_device_information(&config, &device.udid) {
                    eprintln!("apple-devices-metrics: asking {}: {e}", device.name);
                }
            }
            std::thread::sleep(Duration::from_secs(config.query));
        });
    }
    loop {
        let snapshot = answers.lock().map(|a| a.clone()).unwrap_or_default();
        let text = metrics::render(&config, &metrics::collect(&config), &snapshot);
        if let Err(e) = metrics::write(&config.output, &text) {
            eprintln!("apple-devices-metrics: writing {}: {e}", config.output.display());
        }
        std::thread::sleep(Duration::from_secs(config.refresh));
    }
}
