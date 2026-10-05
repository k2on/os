//! Signal, through signal-cli's JSON-RPC daemon on a unix socket
//! (`signal-cli daemon --socket`, newline-delimited JSON-RPC 2.0).
//!
//! Incoming `receive` notifications become channel events only for plain
//! one-to-one messages from a number in the identity table; everything else
//! (unknown senders, groups, receipts, typing, sync messages) is dropped and
//! counted on stderr, never echoing message text. Replies go out with `send`.
//! The socket may be absent (signal-cli not running or not yet registered):
//! we keep reconnecting with backoff and the phone side carries on.

use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::{mpsc, oneshot};

use crate::identity::People;
use crate::mcp::channel_event;
use crate::state::State;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_BACKOFF: Duration = Duration::from_secs(60);

type Pending = HashMap<u64, oneshot::Sender<Result<Value, String>>>;

pub struct Signal {
    socket: PathBuf,
    writer: Mutex<Option<mpsc::UnboundedSender<String>>>,
    pending: Mutex<Pending>,
    next_id: AtomicU64,
    /// The daemon runs in multi-account mode, where requests name the
    /// account; learned with listAccounts.
    account: Mutex<Option<String>>,
    dropped: Mutex<BTreeMap<&'static str, u64>>,
}

/// The chat_id of a Signal conversation: `signal:<E.164 number>`.
pub fn chat_id(number: &str) -> String {
    format!("signal:{number}")
}

/// The number behind a Signal chat_id; None for phone conversations.
pub fn number_of_chat(chat_id: &str) -> Option<&str> {
    chat_id.strip_prefix("signal:").filter(|n| !n.is_empty())
}

#[derive(Debug, PartialEq)]
pub struct Inbound {
    pub number: String,
    pub sender: String,
    pub text: String,
}

/// Accepts a `receive` notification's params, or says why it is dropped.
pub fn classify(params: &Value, people: &People) -> Result<Inbound, &'static str> {
    // Automatic receiving puts the envelope in params; a subscription wraps
    // it in params.result.
    let envelope = match (&params["envelope"], &params["result"]["envelope"]) {
        (e @ Value::Object(_), _) | (_, e @ Value::Object(_)) => e,
        _ => return Err("malformed"),
    };
    let message = &envelope["dataMessage"];
    if !message.is_object() {
        return Err("non-message"); // receipts, typing, sync, calls, stories
    }
    if !message["groupInfo"].is_null() || !message["groupV2"].is_null() {
        return Err("group");
    }
    let text = match message["message"].as_str() {
        Some(t) if !t.trim().is_empty() => t,
        _ => return Err("empty"),
    };
    let number = envelope["sourceNumber"]
        .as_str()
        .or_else(|| envelope["source"].as_str().filter(|s| s.starts_with('+')))
        .ok_or("unknown sender")?;
    let sender = people.by_number(number).ok_or("unknown sender")?;
    Ok(Inbound {
        number: number.to_owned(),
        sender: sender.to_owned(),
        text: text.to_owned(),
    })
}

impl Signal {
    pub fn new(socket: PathBuf) -> Self {
        Signal {
            socket,
            writer: Mutex::new(None),
            pending: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            account: Mutex::new(None),
            dropped: Mutex::new(BTreeMap::new()),
        }
    }

    /// Keeps a connection to signal-cli up for the life of the process.
    pub async fn run(state: Arc<State>) {
        let signal = &state.signal;
        let mut backoff = Duration::from_secs(1);
        let mut reported = false;
        loop {
            match UnixStream::connect(&signal.socket).await {
                Ok(stream) => {
                    eprintln!("sivrad: connected to signal-cli");
                    backoff = Duration::from_secs(1);
                    reported = false;
                    signal.session(&state, stream).await;
                    eprintln!("sivrad: lost signal-cli; reconnecting");
                }
                Err(e) if !reported => {
                    eprintln!(
                        "sivrad: signal-cli socket {}: {e}; retrying",
                        signal.socket.display()
                    );
                    reported = true;
                }
                Err(_) => {}
            }
            tokio::time::sleep(backoff).await;
            backoff = (backoff * 2).min(MAX_BACKOFF);
        }
    }

    async fn session(&self, state: &Arc<State>, stream: UnixStream) {
        let (read, mut write) = stream.into_split();
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        *self.writer.lock().unwrap() = Some(tx);
        let writer = tokio::spawn(async move {
            while let Some(line) = rx.recv().await {
                if write.write_all(line.as_bytes()).await.is_err() {
                    break;
                }
            }
        });
        // Learn the account in the background; responses arrive below.
        let learner = tokio::spawn({
            let state = state.clone();
            async move { state.signal.learn_account().await }
        });

        let mut lines = BufReader::new(read).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let Ok(message) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if message.get("method").and_then(Value::as_str) == Some("receive") {
                self.receive(state, &message["params"]);
            } else if let Some(id) = message.get("id").and_then(Value::as_u64) {
                let result = match message.get("error") {
                    Some(e) if !e.is_null() => Err(e["message"]
                        .as_str()
                        .unwrap_or("signal-cli error")
                        .to_owned()),
                    _ => Ok(message.get("result").cloned().unwrap_or(Value::Null)),
                };
                if let Some(tx) = self.pending.lock().unwrap().remove(&id) {
                    let _ = tx.send(result);
                }
            }
        }

        *self.writer.lock().unwrap() = None;
        writer.abort();
        learner.abort();
        // Fail whatever was in flight instead of letting it time out.
        self.pending.lock().unwrap().clear();
    }

    fn receive(&self, state: &State, params: &Value) {
        match classify(params, &state.people()) {
            Ok(m) => {
                eprintln!("sivrad: Signal message from {}", m.sender);
                state.send(channel_event(
                    &m.text,
                    &[
                        ("chat_id", &chat_id(&m.number)),
                        ("kind", "signal"),
                        ("sender", &m.sender),
                    ],
                ));
            }
            Err(reason) => {
                let mut dropped = self.dropped.lock().unwrap();
                *dropped.entry(reason).or_default() += 1;
                eprintln!(
                    "sivrad: dropped a Signal envelope ({reason}); dropped so far: {dropped:?}"
                );
            }
        }
    }

    async fn learn_account(&self) -> Option<String> {
        let accounts = self.call("listAccounts", json!({})).await.ok()?;
        let accounts = accounts.as_array()?;
        if accounts.len() != 1 {
            eprintln!(
                "sivrad: signal-cli has {} accounts; expected one",
                accounts.len()
            );
            return None;
        }
        let account = accounts[0]["number"]
            .as_str()
            .or_else(|| accounts[0]["aci"].as_str())?
            .to_owned();
        *self.account.lock().unwrap() = Some(account.clone());
        Some(account)
    }

    /// A request for the account (multi-account mode wants it named).
    async fn request(&self, method: &str, mut params: Value) -> Result<Value, String> {
        if self.writer.lock().unwrap().is_none() {
            return Err("signal-cli is not running".into());
        }
        let known = self.account.lock().unwrap().clone();
        let account = match known {
            Some(a) => a,
            None => self
                .learn_account()
                .await
                .ok_or("signal-cli has no registered account")?,
        };
        params["account"] = json!(account);
        self.call(method, params).await
    }

    async fn call(&self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id, tx);
        let line = format!(
            "{}\n",
            json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params })
        );
        let sent = match &*self.writer.lock().unwrap() {
            Some(writer) => writer.send(line).is_ok(),
            None => false,
        };
        if !sent {
            self.pending.lock().unwrap().remove(&id);
            return Err("signal-cli is not running".into());
        }
        match tokio::time::timeout(REQUEST_TIMEOUT, rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err("lost the connection to signal-cli".into()),
            Err(_) => {
                self.pending.lock().unwrap().remove(&id);
                Err("signal-cli did not answer".into())
            }
        }
    }

    pub async fn send(&self, number: &str, text: &str) -> Result<(), String> {
        self.request("send", json!({ "recipient": [number], "message": text }))
            .await
            .map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn people() -> People {
        People::parse(r#"{ "alice": { "signal": "+15550000001" }, "bob": {} }"#).unwrap()
    }

    fn envelope(source: &str, data: Value) -> Value {
        json!({ "envelope": { "sourceNumber": source, "source": source, "timestamp": 1, "dataMessage": data }, "account": "+15559999999" })
    }

    #[test]
    fn accepts_a_known_sender() {
        let m = classify(
            &envelope("+15550000001", json!({ "message": "hi" })),
            &people(),
        )
        .unwrap();
        assert_eq!(
            m,
            Inbound {
                number: "+15550000001".into(),
                sender: "alice".into(),
                text: "hi".into()
            }
        );
        // the subscription form wraps the envelope in `result`
        let wrapped = json!({ "subscription": 0, "result": envelope("+15550000001", json!({ "message": "hi" })) });
        assert_eq!(classify(&wrapped, &people()).unwrap().sender, "alice");
    }

    #[test]
    fn drops_everything_else() {
        let p = people();
        assert_eq!(
            classify(&envelope("+15550000002", json!({ "message": "hi" })), &p),
            Err("unknown sender")
        );
        assert_eq!(
            classify(
                &envelope(
                    "+15550000001",
                    json!({ "message": "hi", "groupInfo": { "groupId": "x" } })
                ),
                &p
            ),
            Err("group")
        );
        assert_eq!(
            classify(&envelope("+15550000001", json!({ "message": "" })), &p),
            Err("empty")
        );
        assert_eq!(
            classify(&envelope("+15550000001", json!({ "attachments": [] })), &p),
            Err("empty")
        );
        let receipt = json!({ "envelope": { "sourceNumber": "+15550000001", "receiptMessage": { "isDelivery": true } } });
        assert_eq!(classify(&receipt, &p), Err("non-message"));
        let typing = json!({ "envelope": { "sourceNumber": "+15550000001", "typingMessage": { "action": "STARTED" } } });
        assert_eq!(classify(&typing, &p), Err("non-message"));
        let sync = json!({ "envelope": { "sourceNumber": "+15550000001", "syncMessage": { "sentMessage": { "message": "x" } } } });
        assert_eq!(classify(&sync, &p), Err("non-message"));
        assert_eq!(classify(&json!({}), &p), Err("malformed"));
    }

    #[test]
    fn chat_ids() {
        assert_eq!(chat_id("+15550000001"), "signal:+15550000001");
        assert_eq!(number_of_chat("signal:+15550000001"), Some("+15550000001"));
        assert_eq!(number_of_chat("signal:"), None);
        assert_eq!(number_of_chat("c1"), None);
    }

    #[tokio::test]
    async fn sending_without_signal_cli_fails_cleanly() {
        let signal = Signal::new("/nonexistent.sock".into());
        *signal.account.lock().unwrap() = Some("+15559999999".into());
        assert_eq!(
            signal.send("+15550000001", "hi").await,
            Err("signal-cli is not running".into())
        );
        assert!(signal.pending.lock().unwrap().is_empty());
    }
}
