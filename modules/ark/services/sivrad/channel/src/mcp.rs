//! The MCP side: the tools the agent calls back for during a run, served
//! over HTTP on loopback (http.rs: `POST /mcp`, one JSON-RPC 2.0 message per
//! request, the streamable HTTP transport in its plain-JSON form). Just the
//! subset a client needs: initialize, ping, tools/list, tools/call.

use serde_json::{json, Value};

use crate::files;
use crate::signal;
use crate::state::{Answer, Outcome, State};

pub const INSTRUCTIONS: &str = "\
sivrad's channel to the people it serves. Messages reach you as runs whose input starts with a [sivrad] header line: sender (the person's Kanidm username; the same person whether they write from the phone or Signal), chat_id, kind (voice or signal) and, for Signal, chat (direct or group). Your final answer is sent to that chat for you; answer with exactly [SILENT] to say nothing.
kind=voice: the phone voice assistant, transcribed from speech, so expect transcription errors. Answer in one or two short plain sentences, to be read aloud: no markdown, no lists, no code. When the request is something the phone itself must do (a timer, an alarm, a text, opening an app) and the input lists a matching phone tool, call phone_tool with the chat_id, the tool's name and arguments matching its JSON schema, then answer briefly. The phone waits about two minutes per step. locked=true means the phone is locked; tools marked requiresUnlock will prompt the owner to unlock it.
kind=signal: a Signal message; chat_id is signal:<address> or signal:group:<id>. In a group, act as the group's assistant: only trusted people's messages reach you, but others may read your answers; answer when addressed or useful, [SILENT] otherwise.
Files: a received file is listed in the input as a [file: <path> (<content type>)] line; it is in inbox/ in the workspace. To send files to the chat you are answering, call reply with their workspace paths (the text may be empty); to message another trusted person, signal_send, only when the sender asked for it. The phone cannot take files.";

fn tools() -> Value {
    json!([
        {
            "name": "reply",
            "description": "Send an answer to the chat of the current run before it ends: a Signal message with files attached (chat_id signal:<address> or signal:group:<id>), or an early spoken answer for the phone. The run's final text is sent anyway, so use this for files or for an answer that cannot wait.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "chat_id": { "type": "string", "description": "chat_id from the run's [sivrad] header" },
                    "text": { "type": "string", "description": "The message; may be empty when files are attached" },
                    "files": { "type": "array", "items": { "type": "string" }, "description": "Signal chats only: paths of files in the workspace to attach, such as a screenshot" }
                },
                "required": ["chat_id", "text"]
            }
        },
        {
            "name": "phone_tool",
            "description": "Run one of the phone's tools (their definitions are in the run's input) and return its result.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "chat_id": { "type": "string", "description": "chat_id from the run's [sivrad] header" },
                    "name": { "type": "string", "description": "Name of a phone tool listed in the input" },
                    "arguments": { "type": "object", "description": "Arguments matching that tool's JSON schema" }
                },
                "required": ["chat_id", "name", "arguments"]
            }
        },
        {
            "name": "signal_send",
            "description": "Send a Signal message to another trusted person, only when the sender asked for it.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "to": { "type": "string", "description": "The person's username, as in a run's sender" },
                    "text": { "type": "string", "description": "The message; may be empty when files are attached" },
                    "files": { "type": "array", "items": { "type": "string" }, "description": "Paths of files in the workspace to attach" }
                },
                "required": ["to", "text"]
            }
        }
    ])
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
            "capabilities": { "tools": {} },
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
    if name == "signal_send" {
        return signal_send(state, args).await;
    }
    // Trimmed: some models pad every string argument with spaces.
    let Some(chat) = args["chat_id"].as_str().map(str::trim) else {
        return Outcome::error("chat_id must be a string");
    };
    match name {
        "reply" => {
            let Some(text) = args["text"].as_str() else {
                return Outcome::error("text must be a string");
            };
            let files = match files_arg(args) {
                Ok(f) => f,
                Err(e) => return Outcome::error(e),
            };
            if let Some(target) = signal::Chat::parse(chat) {
                if !state.signal.is_trusted(&state.people(), &target) {
                    return Outcome::error(format!(
                        "{chat} is not a trusted person's Signal address or group"
                    ));
                }
                return send_signal(state, &target, text, &files).await;
            }
            if !files.is_empty() {
                return Outcome::error("the phone cannot take files; only Signal chats can");
            }
            if text.trim().is_empty() {
                return Outcome::error("text must not be empty");
            }
            if state.answer(chat, Answer::reply(text)) {
                Outcome::ok("sent")
            } else {
                Outcome::gone(chat)
            }
        }
        "phone_tool" => {
            let Some(tool) = args["name"].as_str().map(str::trim) else {
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

async fn signal_send(state: &State, args: &Value) -> Outcome {
    let (Some(to), Some(text)) = (args["to"].as_str().map(str::trim), args["text"].as_str().map(str::trim)) else {
        return Outcome::error("to and text must be strings");
    };
    let files = match files_arg(args) {
        Ok(f) => f,
        Err(e) => return Outcome::error(e),
    };
    match state.signal.address_of(&state.people(), to).await {
        Ok(address) => send_signal(state, &signal::Chat::Direct(address), text, &files).await,
        Err(e) => Outcome::error(e),
    }
}

/// The optional `files` argument: a list of paths, or nothing.
fn files_arg(args: &Value) -> Result<Vec<String>, String> {
    match &args["files"] {
        Value::Null => Ok(vec![]),
        Value::Array(list) => list
            .iter()
            .map(|f| {
                f.as_str()
                    .map(str::to_owned)
                    .ok_or_else(|| "files must be a list of paths".to_owned())
            })
            .collect(),
        _ => Err("files must be a list of paths".into()),
    }
}

/// Sends text and workspace files to a Signal chat; an empty message with
/// no files is refused.
async fn send_signal(
    state: &State,
    chat: &signal::Chat,
    text: &str,
    files: &[String],
) -> Outcome {
    if text.trim().is_empty() && files.is_empty() {
        return Outcome::error("text must not be empty unless files are attached");
    }
    let files = match files::outgoing(&state.config, files) {
        Ok(f) => f,
        Err(e) => return Outcome::error(e),
    };
    match state.signal.send(chat, text, &files).await {
        Ok(()) => Outcome::ok("sent"),
        Err(e) => Outcome::error(format!("Signal: {e}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::codex::Codex;
    use crate::oidc::Oidc;
    use crate::state::Config;
    use std::sync::Arc;
    use std::time::Duration;

    fn state() -> Arc<State> {
        let config = Config {
            timeout: Duration::from_millis(500),
            tool_wait: Duration::from_millis(100),
            people_file: "/nonexistent".into(),
            signal_socket: "/nonexistent.sock".into(),
            workspace: std::env::temp_dir(),
            signal_attachments: "/nonexistent".into(),
        };
        Arc::new(State::new(
            config,
            Oidc::new(None, None),
            Codex::new("/nonexistent.sock".into(), "/nonexistent", "/nonexistent.json".into()),
        ))
    }

    #[tokio::test]
    async fn initialize_and_list() {
        let s = state();
        let r = handle(&s, json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": { "protocolVersion": "2025-03-26" } }))
        .await
        .unwrap();
        assert_eq!(r["result"]["protocolVersion"], "2025-03-26");
        assert_eq!(r["result"]["serverInfo"]["name"], "sivrad");
        assert!(r["result"]["capabilities"]["tools"].is_object());
        assert!(handle(&s, json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }))
            .await
            .is_none());
        let r = handle(&s, json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/list" }))
            .await
            .unwrap();
        let names: Vec<&str> = r["result"]["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap())
            .collect();
        assert_eq!(names, ["reply", "phone_tool", "signal_send"]);
        let r = handle(&s, json!({ "jsonrpc": "2.0", "id": 3, "method": "nope" }))
            .await
            .unwrap();
        assert_eq!(r["error"]["code"], -32601);
    }

    #[tokio::test]
    async fn reply_reaches_the_phone() {
        let s = state();
        let held = s.hold("c1");
        let r = handle(&s, json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": { "name": "reply", "arguments": { "chat_id": "c1", "text": "hi" } } }))
        .await
        .unwrap();
        assert_eq!(r["result"]["content"][0]["text"], "sent");
        assert_eq!(held.wait().await, Answer::reply("hi"));
        // nobody waiting any more
        let r = handle(&s, json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": { "name": "reply", "arguments": { "chat_id": "c1", "text": "again" } } }))
        .await
        .unwrap();
        assert_eq!(r["result"]["isError"], true);
        let r = handle(&s, json!({ "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": { "name": "reply", "arguments": { "chat_id": "c1", "text": "x", "files": ["a.png"] } } }))
        .await
        .unwrap();
        assert!(r["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("cannot take files"));
    }

    #[tokio::test]
    async fn phone_tool_waits_for_the_result() {
        let s = state();
        let held = s.hold("c1");
        let call = tokio::spawn({
            let s = s.clone();
            async move {
                handle(&s, json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                    "params": { "name": "phone_tool", "arguments": { "chat_id": "c1", "name": "t", "arguments": {} } } })).await
            }
        });
        let answer = held.wait().await;
        assert_eq!(answer.body["type"], "tool_call");
        let id = answer.body["id"].as_str().unwrap();
        assert!(s.finish_tool_call("c1", id, Outcome::ok("done")));
        let r = call.await.unwrap().unwrap();
        assert_eq!(r["result"]["content"][0]["text"], "done");

        // no phone waiting
        let r = handle(&s, json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": { "name": "phone_tool", "arguments": { "chat_id": "c2", "name": "t", "arguments": {} } } }))
        .await
        .unwrap();
        assert_eq!(r["result"]["isError"], true);
    }

    #[tokio::test]
    async fn signal_tools_need_trust_and_signal_cli() {
        let s = state();
        let r = handle(&s, json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": { "name": "reply", "arguments": { "chat_id": "signal:+15550000001", "text": "hi" } } }))
        .await
        .unwrap();
        assert!(r["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("not a trusted"));
        let r = handle(&s, json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": { "name": "signal_send", "arguments": { "to": "nobody", "text": "hi" } } }))
        .await
        .unwrap();
        assert!(r["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("unknown person"));
        let r = handle(&s, json!({ "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": { "name": "bogus", "arguments": {} } }))
        .await
        .unwrap();
        assert_eq!(r["result"]["isError"], true);
    }
}
