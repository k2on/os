//! Who is waiting on whom: the phone's held HTTP requests (one per
//! conversation) and the phone tool calls awaiting a /tool_result.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use tokio::sync::{mpsc, oneshot};

use crate::identity::People;
use crate::oidc::Oidc;

pub struct Config {
    /// How long a phone request is held before 504.
    pub timeout: Duration,
    /// How long `phone_tool` waits for the phone's /tool_result.
    pub tool_wait: Duration,
    pub people_file: PathBuf,
}

/// The eventual HTTP answer to a held request.
#[derive(Debug, Clone, PartialEq)]
pub struct Answer {
    pub status: u16,
    pub body: Value,
}

impl Answer {
    pub fn ok(body: Value) -> Self {
        Answer { status: 200, body }
    }
    pub fn error(status: u16, message: &str) -> Self {
        Answer {
            status,
            body: json!({ "error": message }),
        }
    }
    pub fn reply(text: &str) -> Self {
        Answer::ok(json!({ "type": "reply", "text": text }))
    }
    pub fn tool_call(id: &str, name: &str, arguments: &Value) -> Self {
        Answer::ok(json!({ "type": "tool_call", "id": id, "name": name, "arguments": arguments }))
    }
}

/// What an MCP tool call returns to Claude.
#[derive(Debug, Clone, PartialEq)]
pub struct Outcome {
    pub text: String,
    pub is_error: bool,
}

impl Outcome {
    pub fn ok(text: impl Into<String>) -> Self {
        Outcome {
            text: text.into(),
            is_error: false,
        }
    }
    pub fn error(text: impl Into<String>) -> Self {
        Outcome {
            text: text.into(),
            is_error: true,
        }
    }
    pub fn gone(conversation: &str) -> Self {
        Outcome::error(format!(
            "the phone is no longer waiting on conversation {conversation}; \
             the owner dismissed it or it timed out"
        ))
    }
}

struct Waiter {
    seq: u64,
    tx: oneshot::Sender<Answer>,
}

struct ToolCall {
    conversation: String,
    tx: oneshot::Sender<Outcome>,
}

pub struct State {
    pub config: Config,
    pub oidc: Oidc,
    out: mpsc::UnboundedSender<Value>,
    seq: AtomicU64,
    waiting: Mutex<HashMap<String, Waiter>>,
    tool_calls: Mutex<HashMap<String, ToolCall>>,
}

impl State {
    /// The state and the receiving end of everything bound for stdout.
    pub fn new(config: Config, oidc: Oidc) -> (Self, mpsc::UnboundedReceiver<Value>) {
        let (out, rx) = mpsc::unbounded_channel();
        let state = State {
            config,
            oidc,
            out,
            seq: AtomicU64::new(0),
            waiting: Mutex::new(HashMap::new()),
            tool_calls: Mutex::new(HashMap::new()),
        };
        (state, rx)
    }

    /// Queues a JSON-RPC message for Claude Code.
    pub fn send(&self, message: Value) {
        let _ = self.out.send(message);
    }

    /// The identity table, read afresh so a changed file applies at once.
    pub fn people(&self) -> People {
        People::load(&self.config.people_file)
    }

    /// Registers the held request for `conversation`; an older one gets 409.
    pub fn hold(self: &Arc<Self>, conversation: &str) -> Held {
        let seq = self.seq.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        let old = self
            .waiting
            .lock()
            .unwrap()
            .insert(conversation.to_owned(), Waiter { seq, tx });
        if let Some(old) = old {
            let _ = old.tx.send(Answer::error(409, "superseded"));
        }
        Held {
            state: self.clone(),
            conversation: conversation.to_owned(),
            seq,
            rx: Some(rx),
        }
    }

    fn take_waiter(&self, conversation: &str) -> Option<Waiter> {
        self.waiting.lock().unwrap().remove(conversation)
    }

    /// Answers the request held for `conversation`; false if none is.
    pub fn answer(&self, conversation: &str, answer: Answer) -> bool {
        match self.take_waiter(conversation) {
            Some(w) => w.tx.send(answer).is_ok(),
            None => false,
        }
    }

    /// Hands a tool call to the phone through the held request; None if
    /// nothing is held for `conversation`.
    pub fn start_tool_call(
        &self,
        conversation: &str,
        name: &str,
        arguments: &Value,
    ) -> Option<(String, oneshot::Receiver<Outcome>)> {
        let waiter = self.take_waiter(conversation)?;
        let id = random_id();
        let (tx, rx) = oneshot::channel();
        self.tool_calls.lock().unwrap().insert(
            id.clone(),
            ToolCall {
                conversation: conversation.to_owned(),
                tx,
            },
        );
        if waiter
            .tx
            .send(Answer::tool_call(&id, name, arguments))
            .is_err()
        {
            self.forget_tool_call(&id);
            return None;
        }
        Some((id, rx))
    }

    pub fn has_tool_call(&self, conversation: &str, id: &str) -> bool {
        self.tool_calls
            .lock()
            .unwrap()
            .get(id)
            .is_some_and(|c| c.conversation == conversation)
    }

    /// Delivers the phone's result for tool call `id`; false if unknown.
    pub fn finish_tool_call(&self, conversation: &str, id: &str, outcome: Outcome) -> bool {
        let call = {
            let mut calls = self.tool_calls.lock().unwrap();
            match calls.get(id) {
                Some(c) if c.conversation == conversation => calls.remove(id),
                _ => None,
            }
        };
        call.is_some_and(|c| c.tx.send(outcome).is_ok())
    }

    pub fn forget_tool_call(&self, id: &str) {
        self.tool_calls.lock().unwrap().remove(id);
    }

    /// A new request abandons tool calls still running for the old one.
    pub fn abandon_tool_calls(&self, conversation: &str) {
        let abandoned: Vec<ToolCall> = {
            let mut calls = self.tool_calls.lock().unwrap();
            let ids: Vec<String> = calls
                .iter()
                .filter(|(_, c)| c.conversation == conversation)
                .map(|(id, _)| id.clone())
                .collect();
            ids.iter().filter_map(|id| calls.remove(id)).collect()
        };
        for call in abandoned {
            let _ = call.tx.send(Outcome::error(
                "the owner started a new request; this tool result was abandoned",
            ));
        }
    }
}

/// A held HTTP request. Dropping it (the phone hung up) unregisters it, so
/// `reply` reports that nobody is waiting instead of pretending to deliver.
pub struct Held {
    state: Arc<State>,
    conversation: String,
    seq: u64,
    rx: Option<oneshot::Receiver<Answer>>,
}

impl Held {
    pub async fn wait(mut self) -> Answer {
        let rx = self.rx.take().expect("waited once");
        match tokio::time::timeout(self.state.config.timeout, rx).await {
            Ok(Ok(answer)) => answer,
            Ok(Err(_)) => Answer::error(409, "superseded"),
            Err(_) => Answer::error(504, "no reply"),
        }
    }
}

impl Drop for Held {
    fn drop(&mut self) {
        let mut waiting = self.state.waiting.lock().unwrap();
        if waiting
            .get(&self.conversation)
            .is_some_and(|w| w.seq == self.seq)
        {
            waiting.remove(&self.conversation);
        }
    }
}

/// 128 random bits as hex.
pub fn random_id() -> String {
    use ring::rand::SecureRandom;
    let mut bytes = [0u8; 16];
    ring::rand::SystemRandom::new()
        .fill(&mut bytes)
        .expect("system randomness");
    hex(&bytes)
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state(timeout_ms: u64) -> Arc<State> {
        let config = Config {
            timeout: Duration::from_millis(timeout_ms),
            tool_wait: Duration::from_millis(timeout_ms),
            people_file: "/nonexistent".into(),
        };
        Arc::new(State::new(config, Oidc::new(None, None)).0)
    }

    #[tokio::test]
    async fn reply_answers_the_held_request() {
        let s = state(1000);
        let held = s.hold("c1");
        assert!(s.answer("c1", Answer::reply("hi")));
        assert_eq!(held.wait().await, Answer::reply("hi"));
        assert!(!s.answer("c1", Answer::reply("again")));
    }

    #[tokio::test]
    async fn newer_request_supersedes() {
        let s = state(1000);
        let first = s.hold("c1");
        let second = s.hold("c1");
        assert_eq!(first.wait().await.status, 409);
        // dropping the superseded request must not unregister the new one
        assert!(s.answer("c1", Answer::reply("two")));
        assert_eq!(second.wait().await, Answer::reply("two"));
    }

    #[tokio::test]
    async fn timeout_and_hang_up_unregister() {
        let s = state(20);
        assert_eq!(s.hold("c1").wait().await.status, 504);
        assert!(!s.answer("c1", Answer::reply("late")));
        drop(s.hold("c2"));
        assert!(!s.answer("c2", Answer::reply("gone")));
    }

    #[tokio::test]
    async fn tool_call_round_trip() {
        let s = state(1000);
        let held = s.hold("c1");
        let args = json!({ "seconds": 300 });
        let (id, rx) = s.start_tool_call("c1", "set_timer", &args).unwrap();
        assert_eq!(
            held.wait().await,
            Answer::tool_call(&id, "set_timer", &args)
        );
        assert!(s.has_tool_call("c1", &id));
        assert!(!s.has_tool_call("c2", &id));
        assert!(!s.finish_tool_call("c2", &id, Outcome::ok("wrong conversation")));
        assert!(s.finish_tool_call("c1", &id, Outcome::ok("done")));
        assert_eq!(rx.await.unwrap(), Outcome::ok("done"));
        assert!(!s.finish_tool_call("c1", &id, Outcome::ok("twice")));
        assert!(s.start_tool_call("c1", "set_timer", &args).is_none());
    }

    #[tokio::test]
    async fn new_request_abandons_tool_calls() {
        let s = state(1000);
        let _held = s.hold("c1");
        let (_, rx) = s.start_tool_call("c1", "t", &json!({})).unwrap();
        s.abandon_tool_calls("c1");
        assert!(rx.await.unwrap().is_error);
    }

    #[test]
    fn ids_are_hex() {
        let id = random_id();
        assert_eq!(id.len(), 32);
        assert!(id.chars().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(id, random_id());
    }
}
