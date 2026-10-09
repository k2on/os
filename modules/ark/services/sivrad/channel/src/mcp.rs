//! The MCP side: newline-delimited JSON-RPC 2.0 on stdin/stdout, just the
//! subset Claude Code needs from a channel server (initialize, ping,
//! tools/list, tools/call) plus our `notifications/claude/channel` events.

use std::sync::Arc;

use serde_json::{json, Map, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

use crate::files;
use crate::signal;
use crate::state::{Answer, Outcome, State};

pub const INSTRUCTIONS: &str = "\
Messages arrive as <channel source=\"sivrad\" ...> events from a small group of trusted people. Every event carries sender, the Kanidm username of the person; it is the same person whether the message came from the phone or from Signal.
kind=\"voice\" events come from the phone voice assistant, transcribed from speech, so expect transcription errors. Answer with the reply tool, passing the event's chat_id, in one or two short plain sentences suitable to be read aloud or shown on a small overlay: no markdown, no lists, no code.
When the request is something the phone itself must do (a timer, an alarm, a text message, opening an app, an HTTP request to one of the owner's services) and the event lists a matching phone tool, call phone_tool with that chat_id, the tool name and arguments matching the listed JSON schema; then reply with a short confirmation or the tool's own message.
The phone waits about two minutes per step, so reply before starting long work. locked=\"true\" means the phone is locked; tools marked requiresUnlock will prompt the owner to unlock it.
kind=\"signal\" events are Signal messages; their chat_id is signal:<address> (chat=\"direct\": one person) or signal:group:<id> (chat=\"group\": a group with several people, where everyone reads your reply). Answer them with reply to that chat_id, in plain text.
In a group, act as the group's assistant: only trusted people's messages reach you, but others may be in the group and read your replies. Reply when addressed or when you can help; let conversation between people pass without comment.
Message another trusted person only with signal_send, and only when the sender asked for it; then confirm back to the sender with reply.
Files: a Signal message's attachments (images, documents, anything) are listed in the event as [file: <path> (<content type>)] lines; they are in inbox/ in the workspace, and you can look at an image with Read. To send files over Signal (a screenshot from the browser, a document) pass their workspace paths in the files argument of reply or signal_send; the text may then be empty. The phone cannot take files.";

fn tools() -> Value {
    json!([
        {
            "name": "reply",
            "description": "Answer a sivrad channel event: the spoken answer for a phone conversation, or a Signal message for a signal:<address> or signal:group:<id> chat_id.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "chat_id": { "type": "string", "description": "chat_id of the channel event being answered" },
                    "text": { "type": "string", "description": "One or two short plain sentences; may be empty when files are attached" },
                    "files": { "type": "array", "items": { "type": "string" }, "description": "Signal chats only: paths of files in the workspace to attach, such as a screenshot" }
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
        },
        {
            "name": "signal_send",
            "description": "Send a Signal message to another trusted person, only when the sender asked for it.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "to": { "type": "string", "description": "The person's username, as in an event's sender" },
                    "text": { "type": "string", "description": "The message; may be empty when files are attached" },
                    "files": { "type": "array", "items": { "type": "string" }, "description": "Paths of files in the workspace to attach" }
                },
                "required": ["to", "text"]
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
    if name == "signal_send" {
        return signal_send(state, args).await;
    }
    let Some(chat) = args["chat_id"].as_str() else {
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

async fn signal_send(state: &State, args: &Value) -> Outcome {
    let (Some(to), Some(text)) = (args["to"].as_str(), args["text"].as_str()) else {
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
        Value::Null => Ok(Vec::new()),
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

/// A Signal message with its files checked (files.rs); something has to
/// be in it.
async fn send_signal(state: &State, chat: &signal::Chat, text: &str, files: &[String]) -> Outcome {
    if text.trim().is_empty() && files.is_empty() {
        return Outcome::error("nothing to send: give text or files");
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
            signal_socket: "/nonexistent.sock".into(),
            workspace: std::env::temp_dir(),
            signal_attachments: "/nonexistent".into(),
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
        assert_eq!(names, ["reply", "phone_tool", "signal_send"]);
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

    fn with_people() -> Arc<State> {
        let workspace =
            std::env::temp_dir().join(format!("sivrad-ws-{}", crate::state::random_id()));
        std::fs::create_dir_all(&workspace).unwrap();
        let path =
            std::env::temp_dir().join(format!("sivrad-people-{}.json", crate::state::random_id()));
        std::fs::write(&path, r#"{ "alice": { "signal": "+15550000001" }, "bob": { "signal": "+15550000002" }, "carol": {} }"#).unwrap();
        let config = Config {
            timeout: Duration::from_secs(1),
            tool_wait: Duration::from_millis(50),
            people_file: path,
            signal_socket: "/nonexistent.sock".into(),
            // its own directory: the tests tell workspace files from others
            workspace: workspace.clone(),
            signal_attachments: "/nonexistent".into(),
        };
        Arc::new(State::new(config, Oidc::new(None, None)).0)
    }

    async fn tool(state: &State, name: &str, arguments: Value) -> Value {
        call(
            state,
            json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": { "name": name, "arguments": arguments } }),
        )
        .await["result"]
            .clone()
    }

    #[tokio::test]
    async fn signal_routing() {
        let s = with_people();
        // a trusted number goes to signal-cli (not running here)
        let r = tool(
            &s,
            "reply",
            json!({ "chat_id": "signal:+15550000001", "text": "hi" }),
        )
        .await;
        assert_eq!(r["content"][0]["text"], "Signal: signal-cli is not running");
        // anyone else's number is refused before reaching signal-cli
        let r = tool(
            &s,
            "reply",
            json!({ "chat_id": "signal:+15550000009", "text": "hi" }),
        )
        .await;
        assert_eq!(
            r["content"][0]["text"],
            "signal:+15550000009 is not a trusted person's Signal address or group"
        );
        // a group nobody trusted has written in is refused too
        let r = tool(
            &s,
            "reply",
            json!({ "chat_id": "signal:group:g1==", "text": "hi" }),
        )
        .await;
        assert_eq!(r["isError"], true);
        let r = tool(&s, "signal_send", json!({ "to": "bob", "text": "hi" })).await;
        assert_eq!(r["content"][0]["text"], "Signal: signal-cli is not running");
        let r = tool(&s, "signal_send", json!({ "to": "mallory", "text": "hi" })).await;
        assert_eq!(r["isError"], true);
        assert_eq!(r["content"][0]["text"], "unknown person; known: alice, bob");
        let r = tool(&s, "signal_send", json!({ "to": "carol", "text": "hi" })).await;
        assert_eq!(r["content"][0]["text"], "unknown person; known: alice, bob");
        std::fs::remove_dir_all(&s.config.workspace).unwrap();
        std::fs::remove_file(&s.config.people_file).unwrap();
    }

    #[tokio::test]
    async fn files_go_to_signal_only_from_the_workspace() {
        let s = with_people();
        let shot = s
            .config
            .workspace
            .join(format!("sivrad-shot-{}.png", crate::state::random_id()));
        std::fs::write(&shot, b"png").unwrap();
        let shot = shot.to_string_lossy().into_owned();
        // the phone cannot take files
        s.hold("c1");
        let r = tool(
            &s,
            "reply",
            json!({ "chat_id": "c1", "text": "", "files": [shot] }),
        )
        .await;
        assert_eq!(
            r["content"][0]["text"],
            "the phone cannot take files; only Signal chats can"
        );
        // a workspace file goes to signal-cli (not running here)
        let r = tool(
            &s,
            "reply",
            json!({ "chat_id": "signal:+15550000001", "text": "", "files": [shot] }),
        )
        .await;
        assert_eq!(r["content"][0]["text"], "Signal: signal-cli is not running");
        let r = tool(
            &s,
            "signal_send",
            json!({ "to": "bob", "text": "", "files": [shot] }),
        )
        .await;
        assert_eq!(r["content"][0]["text"], "Signal: signal-cli is not running");
        // anything else is refused before reaching it: the people file is
        // beside the workspace, not in it
        let outside = s.config.people_file.to_string_lossy().into_owned();
        let r = tool(
            &s,
            "reply",
            json!({ "chat_id": "signal:+15550000001", "text": "", "files": [outside] }),
        )
        .await;
        assert!(r["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("only files in the workspace"));
        let r = tool(
            &s,
            "reply",
            json!({ "chat_id": "signal:+15550000001", "text": "", "files": [] }),
        )
        .await;
        assert_eq!(
            r["content"][0]["text"],
            "nothing to send: give text or files"
        );
        let r = tool(
            &s,
            "reply",
            json!({ "chat_id": "signal:+15550000001", "text": "x", "files": "nope" }),
        )
        .await;
        assert_eq!(r["content"][0]["text"], "files must be a list of paths");
        std::fs::remove_dir_all(&s.config.workspace).unwrap();
        std::fs::remove_file(&s.config.people_file).unwrap();
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
