//! The MCP side: JSON-RPC 2.0 messages one per line on stdin/stdout, logs
//! on stderr. Requests are answered in order; the browser is one tab, so
//! there is nothing to gain from answering out of order.

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use crate::page::Browser;
use crate::tools;

pub async fn serve(mut browser: Browser) {
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    let mut out = tokio::io::stdout();
    while let Ok(Some(line)) = lines.next_line().await {
        let Ok(message) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if let Some(response) = handle(&mut browser, message).await {
            let mut text = response.to_string();
            text.push('\n');
            if out.write_all(text.as_bytes()).await.is_err() {
                break;
            }
            let _ = out.flush().await;
        }
    }
}

/// The response to one message; None for notifications.
pub async fn handle(browser: &mut Browser, message: Value) -> Option<Value> {
    let method = message.get("method")?.as_str()?.to_owned();
    let id = message.get("id")?.clone();
    let params = message.get("params").cloned().unwrap_or_else(|| json!({}));
    let result = match method.as_str() {
        "initialize" => json!({
            "protocolVersion": params.get("protocolVersion").cloned().unwrap_or_else(|| json!("2025-06-18")),
            "capabilities": { "tools": {} },
            "serverInfo": { "name": "sivrad-browser", "version": env!("CARGO_PKG_VERSION") },
            "instructions": tools::INSTRUCTIONS,
        }),
        "ping" => json!({}),
        "tools/list" => json!({ "tools": tools::list() }),
        "tools/call" => {
            let name = params["name"].as_str().unwrap_or_default().to_owned();
            let arguments = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
            match tools::call(browser, &name, &arguments).await {
                Ok(content) => json!({ "content": content }),
                Err(e) => json!({ "content": [{ "type": "text", "text": e }], "isError": true }),
            }
        }
        _ => {
            return Some(json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": { "code": -32601, "message": format!("method not found: {method}") }
            }))
        }
    };
    Some(json!({ "jsonrpc": "2.0", "id": id, "result": result }))
}
