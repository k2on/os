//! Prometheus' text format, written whole to node_exporter's textfile
//! directory (a temporary file renamed over the last, so it never reads half).
use std::collections::HashMap;
use std::fmt::Write as _;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::nanohub::DeviceStatus;
use crate::webhook::DeviceInformation;
use crate::{expiry, nanohub, Config, Result};

pub struct Collected {
    pub push_certificate: Option<Result<i64>>,
    pub vpp_token: Option<Result<i64>>,
    pub abm_tokens: Vec<(String, Result<i64>)>,
    /// By UDID.
    pub devices: HashMap<String, Result<DeviceStatus>>,
}

pub fn collect(config: &Config) -> Collected {
    Collected {
        push_certificate: config.push_cert.as_deref().map(expiry::push_certificate),
        vpp_token: config.vpp_token.as_deref().map(expiry::vpp_token),
        abm_tokens: config.dep_names.iter().map(|n| (n.clone(), expiry::abm_token(config, n))).collect(),
        devices: config.devices.iter().map(|d| (d.udid.clone(), nanohub::device_status(config, &d.udid))).collect(),
    }
}

/// A label value, quoted and escaped.
fn q(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n"))
}

struct Out(String);

impl Out {
    fn help(&mut self, name: &str, help: &str) {
        let _ = writeln!(self.0, "# HELP {name} {help}\n# TYPE {name} gauge");
    }
    fn line(&mut self, name: &str, labels: &[(&str, &str)], value: impl std::fmt::Display) {
        let labels: Vec<String> = labels.iter().map(|(k, v)| format!("{k}={}", q(v))).collect();
        let labels = if labels.is_empty() { String::new() } else { format!("{{{}}}", labels.join(",")) };
        let _ = writeln!(self.0, "{name}{labels} {value}");
    }
}

pub fn render(config: &Config, c: &Collected, answers: &HashMap<String, DeviceInformation>) -> String {
    let mut out = Out(String::new());
    let mut errors = 0;
    let mut err = |what: &str, e: &Box<dyn std::error::Error>| {
        eprintln!("apple-devices-metrics: {what}: {e}");
        errors += 1;
    };

    out.help("apple_mdm_push_certificate_expiry_timestamp_seconds", "When the MDM push certificate expires.");
    match &c.push_certificate {
        Some(Ok(t)) => out.line("apple_mdm_push_certificate_expiry_timestamp_seconds", &[], t),
        Some(Err(e)) => err("push certificate", e),
        None => {}
    }
    out.help("apple_vpp_token_expiry_timestamp_seconds", "When the Apps and Books content token expires.");
    match &c.vpp_token {
        Some(Ok(t)) => out.line("apple_vpp_token_expiry_timestamp_seconds", &[], t),
        Some(Err(e)) => err("content token", e),
        None => {}
    }
    out.help("apple_abm_token_expiry_timestamp_seconds", "When an ABM MDM server's token expires.");
    for (name, t) in &c.abm_tokens {
        match t {
            Ok(t) => out.line("apple_abm_token_expiry_timestamp_seconds", &[("name", name)], t),
            Err(e) => err(&format!("ABM token {name}"), e),
        }
    }

    out.help("apple_device_up", "Whether nanohub answered for the device.");
    out.help("apple_device_last_report_timestamp_seconds", "When the device last sent a status report.");
    out.help("apple_device_info", "The device's model and OS version, as it last reported them.");
    out.help("apple_device_declaration_active", "Whether a declaration is active on the device.");
    out.help("apple_device_declaration_valid", "Whether the device found a declaration valid (1) or invalid (0).");
    out.help("apple_device_battery_level_ratio", "The device's battery, 0 to 1, as it last answered.");
    out.help("apple_device_storage_available_bytes", "The device's free storage, as it last answered.");
    out.help("apple_device_storage_total_bytes", "The device's storage, as it last answered.");
    out.help("apple_device_information_timestamp_seconds", "When the device last answered for its battery and storage.");
    for d in &config.devices {
        let id = [("device", d.name.as_str()), ("owner", d.owner.as_str())];
        match c.devices.get(&d.udid) {
            Some(Ok(s)) => {
                out.line("apple_device_up", &id, 1);
                if let Some(t) = s.last_report {
                    out.line("apple_device_last_report_timestamp_seconds", &id, t);
                }
                let os = s.os_version.as_deref().unwrap_or("");
                let model = s.model.as_deref().unwrap_or("");
                out.line("apple_device_info", &[id[0], id[1], ("os_version", os), ("model", model)], 1);
                for decl in &s.declarations {
                    let l = [id[0], id[1], ("declaration", decl.identifier.as_str())];
                    out.line("apple_device_declaration_active", &l, u8::from(decl.active));
                    match decl.valid.as_str() {
                        "valid" => out.line("apple_device_declaration_valid", &l, 1),
                        "invalid" => out.line("apple_device_declaration_valid", &l, 0),
                        _ => {}
                    }
                }
            }
            Some(Err(e)) => {
                out.line("apple_device_up", &id, 0);
                err(&format!("device {}", d.name), e);
            }
            None => {}
        }
        if let Some(a) = answers.get(&d.udid) {
            if let Some(b) = a.battery {
                out.line("apple_device_battery_level_ratio", &id, b);
            }
            if let Some(g) = a.available_gb {
                out.line("apple_device_storage_available_bytes", &id, (g * 1e9).round());
            }
            if let Some(g) = a.capacity_gb {
                out.line("apple_device_storage_total_bytes", &id, (g * 1e9).round());
            }
            out.line("apple_device_information_timestamp_seconds", &id, a.at);
        }
    }

    let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    out.help("apple_devices_metrics_errors", "Sources that failed in the last refresh.");
    out.line("apple_devices_metrics_errors", &[], errors);
    out.help("apple_devices_metrics_timestamp_seconds", "When these were last written.");
    out.line("apple_devices_metrics_timestamp_seconds", &[], now);
    out.0
}

pub fn write(path: &Path, text: &str) -> Result<()> {
    let tmp = path.with_extension("prom.tmp");
    std::fs::write(&tmp, text)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Device;
    use crate::nanohub::Declaration;

    fn config() -> Config {
        Config {
            listen: String::new(),
            output: "/dev/null".into(),
            nanohub: String::new(),
            nanohub_key: "/dev/null".into(),
            depserver: None,
            depserver_key: None,
            dep_names: vec![],
            push_cert: None,
            vpp_token: None,
            devices: vec![Device { name: "max-iphone".into(), udid: "U".into(), owner: "max".into() }],
            refresh: 1,
            query: 1,
        }
    }

    #[test]
    fn renders() {
        let status = DeviceStatus {
            declarations: vec![Declaration { identifier: "a.\"app\"".into(), active: false, valid: "invalid".into() }],
            last_report: Some(100),
            os_version: Some("26.1".into()),
            model: None,
        };
        let c = Collected {
            push_certificate: Some(Ok(1800000000)),
            vpp_token: None,
            abm_tokens: vec![("abm".into(), Err("down".into()))],
            devices: [("U".to_string(), Ok(status))].into(),
        };
        let answers = [("U".to_string(), DeviceInformation { battery: Some(0.5), available_gb: Some(1.5), capacity_gb: None, at: 9 })].into();
        let text = render(&config(), &c, &answers);
        for want in [
            "apple_mdm_push_certificate_expiry_timestamp_seconds 1800000000",
            r#"apple_device_up{device="max-iphone",owner="max"} 1"#,
            r#"apple_device_info{device="max-iphone",owner="max",os_version="26.1",model=""} 1"#,
            r#"apple_device_declaration_active{device="max-iphone",owner="max",declaration="a.\"app\""} 0"#,
            r#"apple_device_declaration_valid{device="max-iphone",owner="max",declaration="a.\"app\""} 0"#,
            r#"apple_device_battery_level_ratio{device="max-iphone",owner="max"} 0.5"#,
            r#"apple_device_storage_available_bytes{device="max-iphone",owner="max"} 1500000000"#,
            "apple_devices_metrics_errors 1",
        ] {
            assert!(text.contains(want), "missing {want} in\n{text}");
        }
        assert!(!text.contains("apple_abm_token_expiry_timestamp_seconds{"));
    }
}
