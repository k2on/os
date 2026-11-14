//! nanohub's webhook (MicroMDM's event format) on loopback, for the
//! devices' answers to DeviceInformation:
//!   { "topic": "mdm.Connect",
//!     "acknowledge_event": { "udid": ..., "status": "Acknowledged",
//!                            "raw_payload": <base64 plist with QueryResponses> } }
//! Everything else it sends is answered and ignored.
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::Value;

use crate::{base64, plist, Answers, Result};

const MAX_BODY: usize = 4 * 1024 * 1024;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct DeviceInformation {
    /// 0 to 1.
    pub battery: Option<f64>,
    /// Apple's figures are GB (10^9 bytes).
    pub available_gb: Option<f64>,
    pub capacity_gb: Option<f64>,
    /// When it answered, Unix seconds.
    pub at: i64,
}

pub fn serve(listen: &str, answers: Answers) -> Result<()> {
    let listener = TcpListener::bind(listen).map_err(|e| format!("listening on {listen}: {e}"))?;
    eprintln!("apple-devices-metrics: webhook on {listen}");
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let answers = answers.clone();
        std::thread::spawn(move || {
            if let Err(e) = handle(stream, &answers) {
                eprintln!("apple-devices-metrics: webhook: {e}");
            }
        });
    }
    Ok(())
}

fn handle(mut stream: TcpStream, answers: &Answers) -> Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    let body = read_body(&mut stream)?;
    stream.write_all(b"HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")?;
    let Some(event) = body.and_then(|b| serde_json::from_slice::<Value>(&b).ok()) else { return Ok(()) };
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() as i64;
    if let Some((udid, info)) = device_information(&event, now) {
        answers.lock().map_err(|_| "poisoned")?.insert(udid, info);
    }
    Ok(())
}

/// The device and what it answered, if this is an answer to DeviceInformation.
pub fn device_information(event: &Value, now: i64) -> Option<(String, DeviceInformation)> {
    let ack = event.get("acknowledge_event")?;
    let udid = ack.get("udid")?.as_str()?.to_string();
    let payload = String::from_utf8(base64::decode(ack.get("raw_payload")?.as_str()?)?).ok()?;
    if !payload.contains("<key>QueryResponses</key>") {
        return None;
    }
    Some((
        udid,
        DeviceInformation {
            battery: plist::number(&payload, "BatteryLevel"),
            available_gb: plist::number(&payload, "AvailableDeviceCapacity"),
            capacity_gb: plist::number(&payload, "DeviceCapacity"),
            at: now,
        },
    ))
}

fn read_body(stream: &mut TcpStream) -> Result<Option<Vec<u8>>> {
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let post = line.starts_with("POST ");
    let mut length = 0usize;
    loop {
        line.clear();
        if reader.read_line(&mut line)? == 0 {
            return Ok(None);
        }
        let header = line.trim_end();
        if header.is_empty() {
            break;
        }
        if let Some((name, value)) = header.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") {
                length = value.trim().parse().unwrap_or(0);
            }
        }
    }
    if !post || length > MAX_BODY {
        return Ok(None);
    }
    let mut body = vec![0; length];
    reader.read_exact(&mut body)?;
    Ok(Some(body))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn event(payload: &str) -> Value {
        json!({ "topic": "mdm.Connect", "acknowledge_event": {
            "udid": "U", "status": "Acknowledged", "raw_payload": base64::encode(payload.as_bytes())
        }})
    }

    #[test]
    fn reads_answers() {
        let e = event("<plist><dict><key>QueryResponses</key><dict><key>BatteryLevel</key><real>0.5</real><key>AvailableDeviceCapacity</key><real>40.5</real><key>DeviceCapacity</key><real>128</real></dict></dict></plist>");
        let (udid, info) = device_information(&e, 7).unwrap();
        assert_eq!(udid, "U");
        assert_eq!(info, DeviceInformation { battery: Some(0.5), available_gb: Some(40.5), capacity_gb: Some(128.0), at: 7 });
    }

    #[test]
    fn ignores_other_events() {
        assert_eq!(device_information(&event("<plist><dict><key>Status</key><string>Idle</string></dict></plist>"), 1), None);
        assert_eq!(device_information(&json!({ "topic": "mdm.TokenUpdate" }), 1), None);
    }
}
