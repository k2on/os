//! The Chrome DevTools Protocol over a WebSocket to one page target: a
//! request id per command, the matching response awaited, events read
//! past (or collected while waiting for a page load).

use std::collections::HashMap;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

const COMMAND_TIMEOUT: Duration = Duration::from_secs(30);

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

/// A page target as the DevTools HTTP endpoint lists it.
#[derive(Debug, Clone, PartialEq)]
pub struct Target {
    pub id: String,
    pub url: String,
    pub title: String,
    pub ws: String,
}

/// The page targets of a browser, from `GET /json`.
pub fn targets(endpoint: &str) -> Result<Vec<Target>, String> {
    let list: Value = ureq::get(&format!("{}/json", endpoint.trim_end_matches('/')))
        .timeout(Duration::from_secs(5))
        .call()
        .map_err(|e| format!("DevTools at {endpoint}: {e}"))?
        .into_json()
        .map_err(|e| format!("DevTools list: {e}"))?;
    Ok(list
        .as_array()
        .into_iter()
        .flatten()
        .filter(|t| t["type"] == "page")
        .filter_map(|t| {
            Some(Target {
                id: t["id"].as_str()?.to_owned(),
                url: t["url"].as_str().unwrap_or("").to_owned(),
                title: t["title"].as_str().unwrap_or("").to_owned(),
                ws: t["webSocketDebuggerUrl"].as_str()?.to_owned(),
            })
        })
        .collect())
}

/// Opens a new tab (`PUT /json/new`) and returns it.
pub fn new_target(endpoint: &str, url: &str) -> Result<Target, String> {
    let t: Value = ureq::put(&format!("{}/json/new?{url}", endpoint.trim_end_matches('/')))
        .timeout(Duration::from_secs(5))
        .call()
        .map_err(|e| format!("DevTools new tab: {e}"))?
        .into_json()
        .map_err(|e| format!("DevTools new tab: {e}"))?;
    Ok(Target {
        id: t["id"].as_str().unwrap_or("").to_owned(),
        url: t["url"].as_str().unwrap_or("").to_owned(),
        title: t["title"].as_str().unwrap_or("").to_owned(),
        ws: t["webSocketDebuggerUrl"]
            .as_str()
            .ok_or("new tab without a DevTools address")?
            .to_owned(),
    })
}

pub struct Session {
    socket: Socket,
    next_id: u64,
    /// Events seen while waiting for a response, by method; the load
    /// waiter looks here.
    events: HashMap<String, u32>,
}

impl Session {
    pub async fn connect(ws: &str) -> Result<Session, String> {
        let (socket, _) = tokio::time::timeout(COMMAND_TIMEOUT, tokio_tungstenite::connect_async(ws))
            .await
            .map_err(|_| "DevTools: connect timed out".to_owned())?
            .map_err(|e| format!("DevTools: {e}"))?;
        let mut session = Session {
            socket,
            next_id: 1,
            events: HashMap::new(),
        };
        session.send("Page.enable", json!({})).await?;
        session.send("Runtime.enable", json!({})).await?;
        Ok(session)
    }

    /// One command, its result.
    pub async fn send(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next_id;
        self.next_id += 1;
        let text = json!({ "id": id, "method": method, "params": params }).to_string();
        self.socket
            .send(Message::Text(text.into()))
            .await
            .map_err(|e| format!("DevTools send: {e}"))?;
        let deadline = tokio::time::Instant::now() + COMMAND_TIMEOUT;
        loop {
            let next = tokio::time::timeout_at(deadline, self.socket.next())
                .await
                .map_err(|_| format!("DevTools: {method} timed out"))?;
            let message = match next {
                Some(Ok(Message::Text(t))) => t,
                Some(Ok(_)) => continue,
                Some(Err(e)) => return Err(format!("DevTools: {e}")),
                None => return Err("DevTools: connection closed".into()),
            };
            let Ok(value) = serde_json::from_str::<Value>(&message) else {
                continue;
            };
            if value["id"] == id {
                if let Some(error) = value.get("error").filter(|e| !e.is_null()) {
                    return Err(format!(
                        "{method}: {}",
                        error["message"].as_str().unwrap_or("DevTools error")
                    ));
                }
                return Ok(value["result"].clone());
            }
            if let Some(event) = value["method"].as_str() {
                *self.events.entry(event.to_owned()).or_default() += 1;
            }
        }
    }

    /// Runs JavaScript in the page and returns its value (promises awaited).
    pub async fn eval(&mut self, expression: &str) -> Result<Value, String> {
        let result = self
            .send(
                "Runtime.evaluate",
                json!({ "expression": expression, "returnByValue": true, "awaitPromise": true }),
            )
            .await?;
        if let Some(e) = result.get("exceptionDetails") {
            return Err(format!(
                "page script failed: {}",
                e["exception"]["description"]
                    .as_str()
                    .or(e["text"].as_str())
                    .unwrap_or("unknown")
            ));
        }
        Ok(result["result"]["value"].clone())
    }

    /// Waits for the document to be loaded and settle: ready, then a
    /// moment for scripts to draw. Never fails: a slow page is read as it
    /// is.
    pub async fn settle(&mut self) {
        let start = tokio::time::Instant::now();
        while start.elapsed() < Duration::from_secs(15) {
            if let Ok(Value::String(state)) = self.eval("document.readyState").await {
                if state == "complete" {
                    break;
                }
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        tokio::time::sleep(Duration::from_millis(700)).await;
    }
}

