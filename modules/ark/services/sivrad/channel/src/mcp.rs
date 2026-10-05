//! The MCP side: newline-delimited JSON-RPC 2.0 on stdin/stdout, just the
//! subset Claude Code needs from a channel server (initialize, ping,
//! tools/list, tools/call) plus our `notifications/claude/channel` events.

use std::sync::Arc;

use serde_json::{json, Map, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

use crate::state::{Answer, Outcome, State};

pub const INSTRUCTIONS: &str = "\
Messages arrive as <channel source=\"sivrad\" chat_id=\"...\" kind=\"voice\" locked=\"...\" sender=\"...\"> events from the owner's phone voice assistant. They are transcribed from speech, so expect transcription errors. sender is the Kanidm username of the trusted person speaking.
Answer with the reply tool, passing the event's chat_id, in one or two short plain sentences suitable to be read aloud or shown on a small overlay: no markdown, no lists, no code.
When the request is something the phone itself must do (a timer, an alarm, a text message, opening an app, an HTTP request to one of the owner's services) and the event lists a matching phone tool, call phone_tool with that chat_id, the tool name and arguments matching the listed JSON schema; then reply with a short confirmation or the tool's own message.
The phone waits about two minutes per step, so reply before starting long work.
locked=\"true\" means the phone is locked; tools marked requiresUnlock will prompt the owner to unlock it.";

fn tools() -> Value {
    json!([
        {
            "name": "reply",
            "description": "Send the final spoken answer to the phone for a sivrad conversation.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "chat_id": { "type": "string", "description": "chat_id of the channel event being answered" },
                    "text": { "type": "string", "description": "One or two short plain sentences" }
                },
                "required": ["chat_id", "text"]
            }
        },
        {
            "name": "phone_tool",
            "description": "Run one of the phone's tools (definitions arrive in the channel event) and return its result.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "chat_id": { "type": "string", "description": "chat_id of the channel event" },
                    "name": { "type": "string", "description": "Name of a phone tool listed in the event" },
                    "arguments": { "type": "object", "description": "Arguments matching that tool's JSON schema" }
                },
                "required": ["chat_id", "name", "arguments"]
            }
        }
    ])
}

/// A channel event. Meta keys must be identifiers (letters, digits, `_`).
pub fn channel_event(content: &str, meta: &[(&str, &str)]) -> Value {
    let meta: Map<String, Value> = meta
        .iter()
        .map(|(k, v)| (k.to_string(), Value::from(*v)))
        .collect();
    json!({
        "jsonrpc": "2.0",
        "method": "notifications/claude/channel",
        "params": { "content": content, "meta": meta }
    })
}

pub fn outcome_json(outcome: &Outcome) -> Value {
    let mut result = json!({ "content": [{ "type": "text", "text": outcome.text }] });
    if outcome.is_error {
        result["isError"] = json!(true);
    }
    result
}

/// The response to one incoming message; None for notifications and for
/// responses (we send no requests).
pub async fn handle(state: &State, message: Value) -> Option<Value> {
    let method = message.get("method")?.as_str()?;
    let id = message.get("id")?.clone();
    let params = message.get("params").cloned().unwrap_or_else(|| json!({}));
    let result = match method {
        "initialize" => json!({
            "protocolVersion": params.get("protocolVersion").cloned().unwrap_or_else(|| json!("2025-06-18")),
            "capabilities": { "experimental": { "claude/channel": {} }, "tools": {} },
            "serverInfo": { "name": "sivrad", "version": env!("CARGO_PKG_VERSION") },
            "instructions": INSTRUCTIONS,
        }),
        "ping" => json!({}),
        "tools/list" => json!({ "tools": tools() }),
        "tools/call" => {
            let name = params["name"].as_str().unwrap_or_default();
            let arguments = params
                .get("arguments")
                .cloned()
                .unwrap_or_else(|| json!({}));
            outcome_json(&call_tool(state, name, &arguments).await)
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

async fn call_tool(state: &State, name: &str, args: &Value) -> Outcome {
    let Some(chat) = args["chat_id"].as_str() else {
        return Outcome::error("chat_id must be a string");
    };
    match name {
        "reply" => {
            let Some(text) = args["text"].as_str() else {
                return Outcome::error("text must be a string");
            };
            if state.answer(chat, Answer::reply(text)) {
                Outcome::ok("sent")
            } else {
                Outcome::gone(chat)
            }
        }
        "phone_tool" => {
            let Some(tool) = args["name"].as_str() else {
                return Outcome::error("name must be a string");
            };
            let call = &args["arguments"];
            if !call.is_object() {
                return Outcome::error("arguments must be an object");
            }
            let Some((id, result)) = state.start_tool_call(chat, tool, call) else {
                return Outcome::gone(chat);
            };
            eprintln!("sivrad: tool_call {tool} on {chat}");
            match tokio::time::timeout(state.config.tool_wait, result).await {
                Ok(Ok(outcome)) => outcome,
                _ => {
                    state.forget_tool_call(&id);
                    Outcome::error("the phone did not report a result")
                }
            }
        }
        _ => Outcome::error(format!("unknown tool: {name}")),
    }
}

/// Serves Claude Code until it closes stdin, then exits the process.
pub async fn read_stdin(state: Arc<State>) {
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<Value>(&line) {
            Ok(message) => {
                let state = state.clone();
                // Concurrently: phone_tool may wait minutes for the phone.
                tokio::spawn(async move {
                    if let Some(response) = handle(&state, message).await {
                        state.send(response);
                    }
                });
            }
            Err(_) => state.send(json!({
                "jsonrpc": "2.0",
                "id": null,
                "error": { "code": -32700, "message": "parse error" }
            })),
        }
    }
    std::process::exit(0);
}

/// Writes queued messages to stdout, one JSON document per line.
pub async fn write_stdout(mut queue: mpsc::UnboundedReceiver<Value>) {
    let mut stdout = tokio::io::stdout();
    while let Some(message) = queue.recv().await {
        let line = format!("{message}\n");
        if stdout.write_all(line.as_bytes()).await.is_err() || stdout.flush().await.is_err() {
            std::process::exit(0);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::oidc::Oidc;
    use crate::state::Config;
    use std::time::Duration;

    fn state() -> Arc<State> {
        let config = Config {
            timeout: Duration::from_secs(1),
            tool_wait: Duration::from_millis(50),
            people_file: "/nonexistent".into(),
        };
        Arc::new(State::new(config, Oidc::new(None, None)).0)
    }

    async fn call(state: &State, message: Value) -> Value {
        handle(state, message).await.unwrap()
    }

    #[tokio::test]
    async fn initialize_echoes_the_protocol_version() {
        let s = state();
        let r = call(&s, json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": { "protocolVersion": "2025-11-25" } })).await;
        assert_eq!(r["id"], 1);
        assert_eq!(r["result"]["protocolVersion"], "2025-11-25");
        assert_eq!(
            r["result"]["capabilities"],
            json!({ "experimental": { "claude/channel": {} }, "tools": {} })
        );
        assert_eq!(r["result"]["serverInfo"]["name"], "sivrad");
        assert!(r["result"]["instructions"]
            .as_str()
            .unwrap()
            .contains("source=\"sivrad\""));
    }

    #[tokio::test]
    async fn lists_tools_and_rejects_unknown_methods() {
        let s = state();
        let r = call(
            &s,
            json!({ "jsonrpc": "2.0", "id": "a", "method": "tools/list" }),
        )
        .await;
        let names: Vec<&str> = r["result"]["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap())
            .collect();
        assert_eq!(names, ["reply", "phone_tool"]);
        let r = call(
            &s,
            json!({ "jsonrpc": "2.0", "id": 2, "method": "resources/list" }),
        )
        .await;
        assert_eq!(r["error"]["code"], -32601);
        assert_eq!(
            call(&s, json!({ "jsonrpc": "2.0", "id": 3, "method": "ping" })).await["result"],
            json!({})
        );
    }

    #[tokio::test]
    async fn ignores_notifications_and_responses() {
        let s = state();
        assert!(handle(
            &s,
            json!({ "jsonrpc": "2.0", "method": "notifications/initialized" })
        )
        .await
        .is_none());
        assert!(
            handle(&s, json!({ "jsonrpc": "2.0", "id": 1, "result": {} }))
                .await
                .is_none()
        );
    }

    #[tokio::test]
    async fn reply_without_a_waiting_phone_is_an_error() {
        let s = state();
        let r = call(
            &s,
            json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": { "name": "reply", "arguments": { "chat_id": "c1", "text": "hi" } } }),
        )
        .await;
        assert_eq!(r["result"]["isError"], true);
        assert!(r["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("no longer waiting on conversation c1"));
    }

    #[tokio::test]
    async fn reply_reaches_the_held_request() {
        let s = state();
        let held = s.hold("c1");
        let r = call(
            &s,
            json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": { "name": "reply", "arguments": { "chat_id": "c1", "text": "Noon." } } }),
        )
        .await;
        assert_eq!(
            r["result"],
            json!({ "content": [{ "type": "text", "text": "sent" }] })
        );
        assert_eq!(held.wait().await, Answer::reply("Noon."));
    }

    #[tokio::test]
    async fn phone_tool_times_out_without_a_result() {
        let s = state();
        let held = s.hold("c1");
        let pending = tokio::spawn({
            let s = s.clone();
            async move {
                call(&s, json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                    "params": { "name": "phone_tool", "arguments": { "chat_id": "c1", "name": "t", "arguments": {} } } })).await
            }
        });
        assert_eq!(held.wait().await.body["type"], "tool_call");
        let r = pending.await.unwrap();
        assert_eq!(r["result"]["isError"], true);
        assert_eq!(
            r["result"]["content"][0]["text"],
            "the phone did not report a result"
        );
    }

    #[test]
    fn channel_event_shape() {
        let e = channel_event("hi", &[("chat_id", "c1"), ("kind", "voice")]);
        assert_eq!(
            e,
            json!({ "jsonrpc": "2.0", "method": "notifications/claude/channel",
            "params": { "content": "hi", "meta": { "chat_id": "c1", "kind": "voice" } } })
        );
    }

    #[test]
    fn outcome_shapes() {
        assert_eq!(
            outcome_json(&Outcome::ok("a")),
            json!({ "content": [{ "type": "text", "text": "a" }] })
        );
        assert_eq!(outcome_json(&Outcome::error("b"))["isError"], true);
    }
}
