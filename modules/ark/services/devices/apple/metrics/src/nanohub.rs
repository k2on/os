//! nanohub's API: what devices report (KMFDDM's status), and queueing the
//! DeviceInformation query (NanoMDM's raw enqueue, which also pushes).
use serde_json::Value;

use crate::{base64, time, Config, Result};

/// A device's declaration, as it last said.
pub struct Declaration {
    pub identifier: String,
    pub active: bool,
    /// "valid", "invalid" or "unknown".
    pub valid: String,
    /// Whether the device has its current version (nanohub's server token).
    pub current: bool,
}

pub struct DeviceStatus {
    pub declarations: Vec<Declaration>,
    /// When it last reported anything, Unix seconds.
    pub last_report: Option<i64>,
    pub os_version: Option<String>,
    pub model: Option<String>,
}

fn auth(config: &Config) -> Result<String> {
    let key = std::fs::read_to_string(&config.nanohub_key)
        .map_err(|e| format!("reading {}: {e}", config.nanohub_key.display()))?;
    Ok(format!("Basic {}", base64::encode(format!("nanohub:{}", key.trim()).as_bytes())))
}

fn get(config: &Config, path: &str) -> Result<Value> {
    let v = ureq::get(&format!("{}{path}", config.nanohub))
        .set("Authorization", &auth(config)?)
        .call()?
        .into_json()?;
    Ok(v)
}

/// The list under the device's UDID in a KMFDDM status answer.
fn under<'a>(v: &'a Value, udid: &str) -> &'a [Value] {
    v.get(udid).and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[])
}

pub fn device_status(config: &Config, udid: &str) -> Result<DeviceStatus> {
    let declarations = get(config, &format!("/api/v1/ddm/declaration-status/{udid}"))?;
    let values = get(config, &format!("/api/v1/ddm/status-values/{udid}"))?;
    Ok(parse_status(udid, &declarations, &values))
}

pub fn parse_status(udid: &str, declarations: &Value, values: &Value) -> DeviceStatus {
    let s = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
    let values = under(values, udid);
    let latest = |path: &str| {
        values
            .iter()
            .filter(|v| s(v, "path").as_deref() == Some(path))
            .max_by_key(|v| s(v, "timestamp").and_then(|t| time::parse(&t)))
            .and_then(|v| s(v, "value"))
    };
    DeviceStatus {
        declarations: under(declarations, udid)
            .iter()
            .filter_map(|d| {
                Some(Declaration {
                    identifier: s(d, "identifier")?,
                    active: d.get("active").and_then(Value::as_bool).unwrap_or(false),
                    valid: s(d, "valid").unwrap_or_else(|| "unknown".into()),
                    current: d.get("current").and_then(Value::as_bool).unwrap_or(false),
                })
            })
            .collect(),
        last_report: values.iter().filter_map(|v| time::parse(&s(v, "timestamp")?)).max(),
        os_version: latest(".StatusItems.device.operating-system.version"),
        model: latest(".StatusItems.device.model.identifier"),
    }
}

/// Battery and storage, answered later through the webhook.
pub fn ask_device_information(config: &Config, udid: &str) -> Result<()> {
    let uuid = std::fs::read_to_string("/proc/sys/kernel/random/uuid")?;
    let command = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CommandUUID</key>
	<string>{}</string>
	<key>Command</key>
	<dict>
		<key>RequestType</key>
		<string>DeviceInformation</string>
		<key>Queries</key>
		<array>
			<string>BatteryLevel</string>
			<string>AvailableDeviceCapacity</string>
			<string>DeviceCapacity</string>
		</array>
	</dict>
</dict>
</plist>
"#,
        uuid.trim()
    );
    ureq::put(&format!("{}/api/v1/nanomdm/enqueue/{udid}", config.nanohub))
        .set("Authorization", &auth(config)?)
        .set("Content-Type", "application/xml")
        .send_string(&command)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses() {
        let declarations = json!({ "U": [
            { "identifier": "a.status", "active": true, "valid": "valid", "current": true },
            { "identifier": "a.app", "active": false, "valid": "invalid" }
        ]});
        let values = json!({ "U": [
            { "path": ".StatusItems.device.operating-system.version", "value": "26.0", "timestamp": "2026-11-13T09:00:00-06:00" },
            { "path": ".StatusItems.device.operating-system.version", "value": "26.1", "timestamp": "2026-11-14T09:00:00-06:00" },
            { "path": ".StatusItems.device.model.identifier", "value": "iPhone16,1", "timestamp": "2026-11-13T09:00:00-06:00" }
        ]});
        let s = parse_status("U", &declarations, &values);
        assert_eq!(s.declarations.len(), 2);
        assert!(!s.declarations[1].active);
        assert_eq!(s.declarations[1].valid, "invalid");
        assert_eq!(s.os_version.as_deref(), Some("26.1"));
        assert_eq!(s.model.as_deref(), Some("iPhone16,1"));
        assert_eq!(s.last_report, time::parse("2026-11-14T09:00:00-06:00"));
    }

    #[test]
    fn empty_answers() {
        let s = parse_status("U", &json!({ "U": null }), &json!({}));
        assert!(s.declarations.is_empty());
        assert_eq!(s.last_report, None);
    }
}
