//! The agent: Codex (`codex app-server`), reached over a unix socket that
//! systemd answers by starting one app-server per connection as the agent's
//! account (../_codex.nix). The protocol is Codex's own: JSON-RPC 2.0, one
//! message per line, the `jsonrpc` field left out, with requests both ways
//! (the server asks for approvals; with the policy set to never it never
//! does, and anything it still asks is declined).
//!
//! Every message from the phone or Signal becomes one turn: the event as
//! the input, in the thread that belongs to the chat (started on the first
//! message, resumed after a restart; the mapping is kept in a file, the
//! threads themselves in Codex's state as the agent), and the turn's last
//! agent message as the answer. While it runs, the agent may call the tools
//! this channel serves it over MCP (mcp.rs): `phone_tool`, `reply` (an
//! answer with files, or an early one) and `signal_send`.
//!
//! The answer goes where the event came from: to the phone's held request,
//! or to the Signal chat. An empty answer, or one of just `[SILENT]`, is no
//! answer at all (in a group, the agent lets conversation pass that way).
//! `MEDIA: <path>` lines are taken out of the text and sent as attachments
//! when the chat can take them.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::{mpsc, oneshot};

use crate::files;
use crate::signal::Chat;
use crate::state::{Answer, State};

/// How long a turn may run before the channel gives up on it and
/// interrupts it: generous, since a task on a website takes as long as it
/// takes and the person is told how it goes along the way; the phone gives
/// up on its own after SIVRAD_TIMEOUT_MS anyway.
const RUN_TIMEOUT: Duration = Duration::from_secs(2 * 60 * 60);
/// For the control requests (initialize, thread/start, turn/start), which
/// answer at once.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(60);
pub const SILENT: &str = "[SILENT]";

pub struct Codex {
    socket: PathBuf,
    /// The agent's workspace: every thread's working directory.
    cwd: String,
    /// Where chat_id -> thread id is kept between restarts.
    threads_file: PathBuf,
    threads: Mutex<HashMap<String, String>>,
    conn: tokio::sync::Mutex<Option<Arc<Conn>>>,
}

/// One connection, so one app-server process.
struct Conn {
    writer: mpsc::UnboundedSender<String>,
    next_id: AtomicU64,
    pending: Mutex<HashMap<u64, oneshot::Sender<Result<Value, String>>>>,
    /// Turns in flight, by turn id: the agent messages seen so far, and
    /// who waits for the turn to end.
    turns: Mutex<HashMap<String, Turn>>,
    /// Threads resumed or started on this connection.
    loaded: Mutex<std::collections::HashSet<String>>,
    /// Where the agent's messages go as they come, by thread, when the
    /// chat can take them (Signal); a message delivered this way is not the
    /// turn's result as well. By thread, since events name the thread and
    /// may arrive before the turn's id is known.
    progress: Mutex<HashMap<String, mpsc::UnboundedSender<Progress>>>,
}

/// A turn as the connection sees it. Events may arrive before `turn/start`
/// has answered with the id, so an entry is made for whichever comes
/// first: a waiter (`done`) or the outcome (`result`). A message sent
/// while the chat's turn is running steers that turn (Codex answers
/// `turn/start` with the running turn's id), so a turn can have several
/// waiters: the last one to arrive gets the answer, the earlier ones
/// nothing, since the one answer covers them all.
/// Finished turns keep their result for a while: a message that steered a
/// turn in its last moments registers after the completion arrived.
const KEEP_FINISHED: Duration = Duration::from_secs(10 * 60);

/// What a chat hears of a turn as it goes: that the agent has started
/// writing (a typing indicator), and each message once it is written.
#[derive(Debug, Clone, PartialEq)]
pub enum Progress {
    Writing,
    Message(String),
}

#[derive(Default)]
struct Turn {
    last_message: Option<String>,
    /// Whether the chat already heard the turn's messages as they came
    /// (progress); then the result is empty, and no fallback may repeat
    /// the last one.
    delivered: bool,
    error: Option<String>,
    done: Vec<oneshot::Sender<Result<String, String>>>,
    result: Option<Result<String, String>>,
    finished: Option<std::time::Instant>,
}

/// Where a message came from, and so where its answer goes.
#[derive(Debug, Clone, PartialEq)]
pub enum Source {
    /// The phone voice assistant: the transcript, the phone's tool
    /// definitions, and whether it is locked.
    Voice { tools: Vec<Value>, locked: bool },
    /// A Signal chat, with one person or a group.
    Signal { chat: Chat },
}

/// One message for the agent.
#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    pub chat_id: String,
    /// The Kanidm username of the person.
    pub sender: String,
    pub source: Source,
    /// The message: the transcript or text, then `[file: ...]` lines.
    pub content: String,
}

impl Event {
    /// The agent's input: a header line it can rely on, then the message.
    pub fn input(&self) -> String {
        let mut header = format!("[sivrad] sender={} chat_id={}", self.sender, self.chat_id);
        match &self.source {
            Source::Voice { locked, .. } => {
                header.push_str(" kind=voice");
                if *locked {
                    header.push_str(" locked=true");
                }
            }
            Source::Signal { chat } => {
                header.push_str(" kind=signal chat=");
                header.push_str(match chat {
                    Chat::Direct(_) => "direct",
                    Chat::Group(_) => "group",
                });
            }
        }
        let mut input = format!("{header}\n{}", self.content);
        if let Source::Voice { tools, .. } = &self.source {
            if !tools.is_empty() {
                let schemas = serde_json::to_string_pretty(tools).unwrap_or_default();
                input.push_str("\n\nPhone tools available for phone_tool (JSON schemas):\n");
                input.push_str(&schemas);
            }
        }
        input
    }
}

impl Codex {
    pub fn new(socket: PathBuf, cwd: &str, threads_file: PathBuf) -> Self {
        let threads = std::fs::read_to_string(&threads_file)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        Codex {
            socket,
            cwd: cwd.to_owned(),
            threads_file,
            threads: Mutex::new(threads),
            conn: tokio::sync::Mutex::new(None),
        }
    }

    /// Runs a turn with `input` in the chat's thread and returns the
    /// agent's last message of it; with `progress`, every message of the
    /// turn goes there as it is said instead, and the result is empty.
    pub async fn respond(
        &self,
        chat_id: &str,
        input: &str,
        progress: Option<mpsc::UnboundedSender<Progress>>,
    ) -> Result<String, String> {
        let conn = self.connection().await?;
        let thread = self.thread(&conn, chat_id).await?;
        match progress {
            Some(p) => {
                conn.progress.lock().unwrap().insert(thread.clone(), p);
            }
            None => {
                conn.progress.lock().unwrap().remove(&thread);
            }
        }
        let turn = conn
            .request(
                "turn/start",
                json!({ "threadId": thread, "input": [{ "type": "text", "text": input }] }),
            )
            .await?;
        let turn_id = turn["turn"]["id"]
            .as_str()
            .ok_or("turn/start answered without a turn id")?
            .to_owned();
        let (tx, rx) = oneshot::channel();
        {
            let mut turns = conn.turns.lock().unwrap();
            turns.retain(|_, t| t.finished.is_none_or(|f| f.elapsed() < KEEP_FINISHED));
            let entry = turns.entry(turn_id.clone()).or_default();
            if let Some(result) = &entry.result {
                return result.clone();
            }
            entry.done.push(tx);
        }
        match tokio::time::timeout(RUN_TIMEOUT, rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err("lost the connection to the agent".into()),
            Err(_) => {
                conn.turns.lock().unwrap().remove(&turn_id);
                let _ = conn
                    .request("turn/interrupt", json!({ "threadId": thread, "turnId": turn_id }))
                    .await;
                Err("the agent did not finish in time".into())
            }
        }
    }

    /// The live connection, or a new one: connect, initialize.
    async fn connection(&self) -> Result<Arc<Conn>, String> {
        let mut slot = self.conn.lock().await;
        if let Some(conn) = slot.as_ref().filter(|c| !c.writer.is_closed()) {
            return Ok(conn.clone());
        }
        let stream = UnixStream::connect(&self.socket)
            .await
            .map_err(|e| format!("agent socket {}: {e}", self.socket.display()))?;
        let conn = Conn::spawn(stream);
        conn.request(
            "initialize",
            json!({ "clientInfo": { "name": "sivrad-channel", "title": "Sivrad", "version": env!("CARGO_PKG_VERSION") } }),
        )
        .await?;
        conn.notify("initialized", json!({}));
        *slot = Some(conn.clone());
        Ok(conn)
    }

    /// The chat's thread, loaded on this connection: resumed when known
    /// (started afresh when Codex no longer has it), started otherwise.
    async fn thread(&self, conn: &Arc<Conn>, chat_id: &str) -> Result<String, String> {
        let known = self.threads.lock().unwrap().get(chat_id).cloned();
        if let Some(id) = known {
            if conn.loaded.lock().unwrap().contains(&id) {
                return Ok(id);
            }
            match conn
                .request("thread/resume", json!({ "threadId": id, "cwd": self.cwd, "approvalPolicy": "never", "sandbox": "workspace-write" }))
                .await
            {
                Ok(_) => {
                    conn.loaded.lock().unwrap().insert(id.clone());
                    return Ok(id);
                }
                Err(e) => eprintln!("sivrad: resuming thread {id} for {chat_id}: {e}; starting a new one"),
            }
        }
        let started = conn
            .request(
                "thread/start",
                json!({ "cwd": self.cwd, "approvalPolicy": "never", "sandbox": "workspace-write", "serviceName": "sivrad" }),
            )
            .await?;
        let id = started["thread"]["id"]
            .as_str()
            .ok_or("thread/start answered without a thread id")?
            .to_owned();
        conn.loaded.lock().unwrap().insert(id.clone());
        let snapshot = {
            let mut threads = self.threads.lock().unwrap();
            threads.insert(chat_id.to_owned(), id.clone());
            serde_json::to_string_pretty(&*threads).unwrap_or_default()
        };
        if let Err(e) = std::fs::write(&self.threads_file, snapshot) {
            eprintln!("sivrad: saving {}: {e}", self.threads_file.display());
        }
        Ok(id)
    }
}

impl Conn {
    fn spawn(stream: UnixStream) -> Arc<Conn> {
        let (read, mut write) = stream.into_split();
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let conn = Arc::new(Conn {
            writer: tx,
            next_id: AtomicU64::new(1),
            pending: Mutex::new(HashMap::new()),
            turns: Mutex::new(HashMap::new()),
            loaded: Mutex::new(Default::default()),
            progress: Mutex::new(HashMap::new()),
        });
        tokio::spawn(async move {
            while let Some(line) = rx.recv().await {
                if write.write_all(line.as_bytes()).await.is_err() {
                    break;
                }
            }
        });
        let reader = conn.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(read).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                if let Ok(message) = serde_json::from_str::<Value>(&line) {
                    reader.receive(message);
                }
            }
            eprintln!("sivrad: the agent connection closed");
            reader.close();
        });
        conn
    }

    fn send(&self, message: Value) -> bool {
        self.writer.send(format!("{message}\n")).is_ok()
    }

    fn notify(&self, method: &str, params: Value) {
        self.send(json!({ "method": method, "params": params }));
    }

    async fn request(&self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id, tx);
        if !self.send(json!({ "id": id, "method": method, "params": params })) {
            self.pending.lock().unwrap().remove(&id);
            return Err("the agent is not connected".into());
        }
        match tokio::time::timeout(REQUEST_TIMEOUT, rx).await {
            Ok(Ok(result)) => result.map_err(|e| format!("{method}: {e}")),
            Ok(Err(_)) => Err(format!("{method}: lost the connection to the agent")),
            Err(_) => {
                self.pending.lock().unwrap().remove(&id);
                Err(format!("{method}: the agent did not answer"))
            }
        }
    }

    /// One message from the server: a response, a request, or a
    /// notification.
    fn receive(&self, message: Value) {
        let method = message.get("method").and_then(Value::as_str);
        let id = message.get("id").cloned();
        match (method, id) {
            (None, Some(id)) => {
                let Some(id) = id.as_u64() else { return };
                let result = match message.get("error") {
                    Some(e) if !e.is_null() => Err(e["message"].as_str().unwrap_or("error").to_owned()),
                    _ => Ok(message.get("result").cloned().unwrap_or(Value::Null)),
                };
                if let Some(tx) = self.pending.lock().unwrap().remove(&id) {
                    let _ = tx.send(result);
                }
            }
            (Some(method), Some(id)) => self.answer_request(method, id, &message["params"]),
            (Some(method), None) => self.notification(method, &message["params"]),
            (None, None) => {}
        }
    }

    /// The server asks: approvals and questions. Nobody is there to say
    /// yes, so the answer is no.
    fn answer_request(&self, method: &str, id: Value, params: &Value) {
        eprintln!(
            "sivrad: the agent asked {method} on turn {}; declining",
            params["turnId"].as_str().unwrap_or("?")
        );
        if method.ends_with("/requestApproval") {
            self.send(json!({ "id": id, "result": { "decision": "decline" } }));
        } else {
            self.send(json!({ "id": id, "error": { "code": -32601, "message": "nobody is there to answer" } }));
        }
    }

    fn notification(&self, method: &str, params: &Value) {
        match method {
            "item/agentMessage/delta" => {
                // The first words of a message: the chat sees typing. Every
                // delta is passed on; the forwarder rations them.
                if let Some(thread) = params["threadId"].as_str() {
                    if let Some(p) = self.progress.lock().unwrap().get(thread) {
                        let _ = p.send(Progress::Writing);
                    }
                }
            }
            "item/completed" => {
                let item = &params["item"];
                if item["type"] == "agentMessage" {
                    if let (Some(turn), Some(text)) = (params["turnId"].as_str(), item["text"].as_str()) {
                        let delivered = params["threadId"]
                            .as_str()
                            .and_then(|thread| self.progress.lock().unwrap().get(thread).cloned())
                            .is_some_and(|p| p.send(Progress::Message(text.to_owned())).is_ok());
                        let mut turns = self.turns.lock().unwrap();
                        let t = turns.entry(turn.to_owned()).or_default();
                        t.delivered |= delivered;
                        t.last_message = if delivered { None } else { Some(text.to_owned()) };
                    }
                }
            }
            "error" => {
                if let Some(turn) = params["turnId"].as_str() {
                    let mut turns = self.turns.lock().unwrap();
                    turns.entry(turn.to_owned()).or_default().error =
                        params["error"]["message"].as_str().map(str::to_owned);
                }
            }
            "turn/completed" => {
                let turn = &params["turn"];
                let Some(id) = turn["id"].as_str() else { return };
                let mut turns = self.turns.lock().unwrap();
                let t = turns.entry(id.to_owned()).or_default();
                let status = turn["status"].as_str().unwrap_or("completed");
                let result = if status == "completed" {
                    let fallback = if t.delivered { None } else { final_message(turn) };
                    Ok(t.last_message.take().or(fallback).unwrap_or_default())
                } else {
                    let detail = turn["error"]["message"]
                        .as_str()
                        .map(str::to_owned)
                        .or(t.error.take())
                        .unwrap_or_default();
                    Err(format!("turn {status} {detail}").trim_end().to_owned())
                };
                if let Some(last) = t.done.pop() {
                    for earlier in t.done.drain(..) {
                        let _ = earlier.send(Ok(String::new()));
                    }
                    let _ = last.send(result.clone());
                }
                t.result = Some(result);
                t.finished = Some(std::time::Instant::now());
            }
            _ => {}
        }
    }

    fn close(&self) {
        self.pending.lock().unwrap().clear();
        self.turns.lock().unwrap().clear();
    }
}

/// The last agent message among a completed turn's items, when it carries
/// them.
fn final_message(turn: &Value) -> Option<String> {
    turn["items"]
        .as_array()?
        .iter()
        .filter(|item| item["type"] == "agentMessage")
        .filter_map(|item| item["text"].as_str())
        .last()
        .map(str::to_owned)
}

/// Kimi K3 wraps what it says in its channel markers (`<|open|> response`
/// ... `<|close|> response`), which Tinfoil's Responses API lets through.
/// They mean nothing to a reader; take them out.
const MARKERS: [&str; 4] = ["<|open|> response", "<|close|> response", "<|open|>", "<|close|>"];

pub fn clean(text: &str) -> String {
    let mut text = text.to_owned();
    for marker in MARKERS {
        text = text.replace(marker, "");
    }
    text
}

/// Splits `MEDIA: <path>` lines off a text, after cleaning it; the rest is
/// trimmed.
pub fn split_media(text: &str) -> (String, Vec<String>) {
    let text = clean(text);
    let mut media = Vec::new();
    let mut kept = Vec::new();
    for line in text.lines() {
        match line.trim().strip_prefix("MEDIA:") {
            Some(path) => {
                if !path.trim().is_empty() {
                    media.push(path.trim().to_owned());
                }
            }
            None => kept.push(line),
        }
    }
    (kept.join("\n").trim().to_owned(), media)
}

/// Runs the agent on an event and delivers its answer; returns at once.
/// A Signal chat hears each of the agent's messages as it is said (the
/// final one included), so a long task reads as progress rather than
/// silence; the phone takes one answer, at the end.
pub fn run(state: Arc<State>, event: Event) {
    tokio::spawn(async move {
        let input = event.input();
        let progress = match &event.source {
            Source::Signal { chat } => {
                let (tx, mut rx) = mpsc::unbounded_channel::<Progress>();
                let state = state.clone();
                let chat = chat.clone();
                tokio::spawn(async move {
                    // Typing is shown once per message being written: on the
                    // first delta, and again only after a message went out
                    // or a while passed (Signal drops it after some seconds).
                    let mut typed_at: Option<std::time::Instant> = None;
                    while let Some(progress) = rx.recv().await {
                        match progress {
                            Progress::Writing => {
                                if typed_at.is_some_and(|t| t.elapsed() < Duration::from_secs(10)) {
                                    continue;
                                }
                                typed_at = Some(std::time::Instant::now());
                                if let Err(e) = state.signal.typing(&chat).await {
                                    eprintln!("sivrad: typing indicator for {}: {e}", chat.id());
                                }
                            }
                            Progress::Message(text) => {
                                typed_at = None;
                                let (text, media) = split_media(&text);
                                if text.is_empty() || text == SILENT {
                                    continue;
                                }
                                let files = files::outgoing(&state.config, &media).unwrap_or_default();
                                if let Err(e) = state.signal.send(&chat, &text, &files).await {
                                    eprintln!("sivrad: sending progress to {}: {e}", chat.id());
                                }
                            }
                        }
                    }
                });
                Some(tx)
            }
            Source::Voice { .. } => None,
        };
        match state.codex.respond(&event.chat_id, &input, progress).await {
            Ok(text) => answer(&state, &event, &text).await,
            Err(e) => {
                eprintln!("sivrad: agent turn for {} failed: {e}", event.chat_id);
                failed(&state, &event).await;
            }
        }
    });
}

async fn answer(state: &Arc<State>, event: &Event, text: &str) {
    let (text, media) = split_media(text);
    let silent = text.is_empty() || text == SILENT;
    match &event.source {
        Source::Voice { .. } => {
            if silent {
                // Nothing to say: the phone still needs an answer, unless the
                // agent already gave one with `reply`.
                if state.answer(&event.chat_id, Answer::error(502, "no answer")) {
                    eprintln!("sivrad: no answer for {}", event.chat_id);
                }
            } else if !state.answer(&event.chat_id, Answer::reply(&text)) {
                eprintln!("sivrad: {}: nobody waiting for the answer", event.chat_id);
            }
        }
        Source::Signal { chat } => {
            let files = match files::outgoing(&state.config, &media) {
                Ok(f) => f,
                Err(e) => {
                    eprintln!("sivrad: media in the answer for {}: {e}", event.chat_id);
                    Vec::new()
                }
            };
            if silent && files.is_empty() {
                return;
            }
            let text = if silent { "" } else { text.as_str() };
            if let Err(e) = state.signal.send(chat, text, &files).await {
                eprintln!("sivrad: sending the answer to {}: {e}", event.chat_id);
            }
        }
    }
}

async fn failed(state: &Arc<State>, event: &Event) {
    match &event.source {
        Source::Voice { .. } => {
            state.answer(&event.chat_id, Answer::error(502, "the assistant failed to answer"));
        }
        Source::Signal { chat } => {
            let _ = state
                .signal
                .send(chat, "Something went wrong on my side; please try again.", &[])
                .await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::random_id;

    #[test]
    fn input_carries_the_header_and_tools() {
        let voice = Event {
            chat_id: "c1".into(),
            sender: "alice".into(),
            source: Source::Voice {
                tools: vec![json!({ "type": "function", "function": { "name": "set_timer" } })],
                locked: true,
            },
            content: "set a timer".into(),
        };
        let input = voice.input();
        assert!(input.starts_with("[sivrad] sender=alice chat_id=c1 kind=voice locked=true\nset a timer\n\nPhone tools"));
        assert!(input.contains("\"name\": \"set_timer\""));

        let group = Event {
            chat_id: "signal:group:g1".into(),
            sender: "bob".into(),
            source: Source::Signal {
                chat: Chat::Group("g1".into()),
            },
            content: "hi all\n[file: /w/inbox/a.jpg (image/jpeg)]".into(),
        };
        assert_eq!(
            group.input(),
            "[sivrad] sender=bob chat_id=signal:group:g1 kind=signal chat=group\nhi all\n[file: /w/inbox/a.jpg (image/jpeg)]"
        );
    }

    #[test]
    fn media_lines_split_off() {
        let (text, media) = split_media("Here you go.\nMEDIA: /w/shot.png\n  MEDIA:/w/doc.pdf\nMEDIA:\n");
        assert_eq!(text, "Here you go.");
        assert_eq!(media, ["/w/shot.png", "/w/doc.pdf"]);
        assert_eq!(split_media("  [SILENT] "), (SILENT.to_owned(), vec![]));
        assert_eq!(
            split_media(" <|open|> response It is noon. <|close|> response"),
            ("It is noon.".to_owned(), vec![])
        );
        assert_eq!(split_media(" <|open|> response <|close|> response"), (String::new(), vec![]));
    }

    #[test]
    fn final_message_is_the_last_agent_message() {
        let turn = json!({ "items": [
            { "type": "agentMessage", "text": "first" },
            { "type": "commandExecution", "command": "ls" },
            { "type": "agentMessage", "text": "last" }
        ] });
        assert_eq!(final_message(&turn), Some("last".into()));
        assert_eq!(final_message(&json!({ "items": [] })), None);
        assert_eq!(final_message(&json!({})), None);
    }

    /// A fake app-server on a unix socket: initialize, thread/start, a
    /// turn that asks for an approval (declined), says something twice and
    /// completes; then a resumed thread on a fresh connection.
    #[tokio::test]
    async fn turns_round_trip() {
        let dir = std::env::temp_dir().join(format!("sivrad-codex-{}", random_id()));
        std::fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("codex.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let seen = Arc::new(Mutex::new(Vec::<String>::new()));
        let log = seen.clone();
        tokio::spawn(async move {
            loop {
                let (stream, _) = listener.accept().await.unwrap();
                let log = log.clone();
                tokio::spawn(async move {
                    let (read, mut write) = stream.into_split();
                    let mut lines = BufReader::new(read).lines();
                    let say = |v: Value| {
                        let line = format!("{v}\n");
                        async move { line }
                    };
                    while let Ok(Some(line)) = lines.next_line().await {
                        let m: Value = serde_json::from_str(&line).unwrap();
                        let method = m["method"].as_str().unwrap_or("").to_owned();
                        log.lock().unwrap().push(method.clone());
                        let id = m["id"].clone();
                        let out: Vec<Value> = match method.as_str() {
                            "initialize" => vec![json!({ "id": id, "result": { "userAgent": "fake" } })],
                            "initialized" => vec![],
                            "thread/start" => vec![
                                json!({ "id": id, "result": { "thread": { "id": "thr_1" } } }),
                                json!({ "method": "thread/started", "params": { "thread": { "id": "thr_1" } } }),
                            ],
                            "thread/resume" => {
                                assert_eq!(m["params"]["threadId"], "thr_1");
                                vec![json!({ "id": id, "result": { "thread": { "id": "thr_1" } } })]
                            }
                            // "hold": start a turn and leave it running; the next
                            // turn/start steers it (same turn id) and completes it.
                            "turn/start" if m["params"]["input"][0]["text"] == "hold" => {
                                vec![json!({ "id": id, "result": { "turn": { "id": "turn_held", "status": "inProgress" } } })]
                            }
                            "turn/start" if m["params"]["input"][0]["text"] == "steer" => {
                                // The answer to turn/start first, then (after the
                                // client has registered) the turn's end.
                                let line = format!("{}\n", json!({ "id": id, "result": { "turn": { "id": "turn_held", "status": "inProgress" } } }));
                                write.write_all(line.as_bytes()).await.unwrap();
                                tokio::time::sleep(Duration::from_millis(200)).await;
                                vec![
                                    json!({ "method": "item/completed", "params": { "threadId": "thr_1", "turnId": "turn_held",
                                            "item": { "type": "agentMessage", "id": "i9", "text": "steered answer" } } }),
                                    json!({ "method": "turn/completed", "params": { "turn": { "id": "turn_held", "status": "completed" } } }),
                                ]
                            }
                            "turn/start" => {
                                let text = m["params"]["input"][0]["text"].as_str().unwrap().to_owned();
                                let turn = format!("turn_{}", log.lock().unwrap().len());
                                vec![
                                    json!({ "id": id, "result": { "turn": { "id": turn, "status": "inProgress" } } }),
                                    json!({ "method": "turn/started", "params": { "turn": { "id": turn } } }),
                                    json!({ "id": 900, "method": "item/commandExecution/requestApproval",
                                            "params": { "threadId": "thr_1", "turnId": turn, "itemId": "i0", "command": ["rm"] } }),
                                    json!({ "method": "item/completed", "params": { "threadId": "thr_1", "turnId": turn,
                                            "item": { "type": "agentMessage", "id": "i1", "text": "working" } } }),
                                    json!({ "method": "item/completed", "params": { "threadId": "thr_1", "turnId": turn,
                                            "item": { "type": "agentMessage", "id": "i2", "text": format!("echo: {text}") } } }),
                                    // As real Codex does: the final agent message
                                    // again, in the completed turn.
                                    json!({ "method": "turn/completed", "params": { "turn": { "id": turn, "status": "completed",
                                            "items": [{ "type": "agentMessage", "id": "i2", "text": format!("echo: {text}") }] } } }),
                                ]
                            }
                            _ => {
                                // the decline of the approval request
                                assert_eq!(m["result"]["decision"], "decline");
                                vec![]
                            }
                        };
                        for v in out {
                            let line = say(v).await;
                            write.write_all(line.as_bytes()).await.unwrap();
                        }
                    }
                });
            }
        });

        let threads_file = dir.join("threads.json");
        let codex = Codex::new(socket.clone(), "/w", threads_file.clone());
        assert_eq!(codex.respond("signal:+1", "hello", None).await, Ok("echo: hello".into()));
        assert_eq!(codex.respond("signal:+1", "again", None).await, Ok("echo: again".into()));
        let saved: HashMap<String, String> =
            serde_json::from_str(&std::fs::read_to_string(&threads_file).unwrap()).unwrap();
        assert_eq!(saved["signal:+1"], "thr_1");

        // A new channel process: the thread is resumed, not started.
        let again = Arc::new(Codex::new(socket, "/w", threads_file));
        assert_eq!(again.respond("signal:+1", "back", None).await, Ok("echo: back".into()));

        // A message during a running turn steers it: the earlier message
        // ends silent, the later one gets the answer.
        let held = {
            let again = again.clone();
            tokio::spawn(async move { again.respond("signal:+1", "hold", None).await })
        };
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(again.respond("signal:+1", "steer", None).await, Ok("steered answer".into()));
        assert_eq!(held.await.unwrap(), Ok(String::new()));

        // With a progress channel, each message is delivered as it comes and
        // the result is empty.
        let (tx, mut rx) = mpsc::unbounded_channel();
        assert_eq!(again.respond("signal:+1", "hello", Some(tx)).await, Ok(String::new()));
        assert_eq!(rx.recv().await, Some(Progress::Message("working".into())));
        assert_eq!(rx.recv().await, Some(Progress::Message("echo: hello".into())));
        let methods = seen.lock().unwrap().clone();
        assert_eq!(methods.iter().filter(|m| *m == "thread/start").count(), 1);
        assert_eq!(methods.iter().filter(|m| *m == "thread/resume").count(), 1);
        assert_eq!(methods.iter().filter(|m| *m == "initialize").count(), 2);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
