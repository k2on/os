//! Signal, through signal-cli's JSON-RPC daemon on a unix socket
//! (`signal-cli daemon --socket`, newline-delimited JSON-RPC 2.0).
//!
//! Incoming `receive` notifications become turns of the agent (codex.rs)
//! only for messages from a person in the identity table; everything else (unknown
//! senders, receipts, typing, sync messages) is dropped and counted on
//! stderr, never echoing message text. Replies go out with `send`.
//! A message's attachments, which signal-cli has downloaded by the time it
//! reports the message, are moved into the workspace (files.rs) and listed
//! in the event; a reply may attach workspace files the same way.
//! The socket may be absent (signal-cli not running or not yet registered):
//! we keep reconnecting with backoff and the phone side carries on.
//!
//! A sender is known by the number in the envelope or, for people who do
//! not share their number (the envelope then only carries their account
//! id), by that id: their Signal username from the identity table is
//! resolved to it with getUserStatus when signal-cli connects, and again
//! when an unknown account id turns up while a username is still unresolved
//! (at most once a minute). Such a person is addressed by the account id
//! from then on: chat_ids are signal:<number or account id>, and signal-cli
//! takes either as a recipient.
//!
//! Groups: a message in a group from a trusted person is an event too, with
//! chat_id signal:group:<id>, answered in the group (so everyone in it reads
//! the answer); messages from anyone else in the group are dropped, and only
//! groups a trusted person has written in can be written to.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::{mpsc, oneshot};

use crate::files;
use crate::codex::{self, Event, Source};
use crate::identity::{People, SignalId};
use crate::state::State;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_BACKOFF: Duration = Duration::from_secs(60);
/// Between resolutions prompted by unknown senders.
const RESOLVE_COOLDOWN: Duration = Duration::from_secs(60);

type Pending = HashMap<u64, oneshot::Sender<Result<Value, String>>>;

pub struct Signal {
    socket: PathBuf,
    writer: Mutex<Option<mpsc::UnboundedSender<String>>>,
    pending: Mutex<Pending>,
    next_id: AtomicU64,
    /// The daemon runs in multi-account mode, where requests name the
    /// account; learned with listAccounts.
    account: Mutex<Option<String>>,
    /// Signal username -> account id (ACI), from getUserStatus.
    resolved: Mutex<HashMap<String, String>>,
    last_resolve: Mutex<Option<Instant>>,
    /// Groups a trusted person has written in, the only ones answered.
    groups: Mutex<HashSet<String>>,
    dropped: Mutex<BTreeMap<&'static str, u64>>,
}

/// A Signal conversation: one person, by their number or account id, or a
/// group, by its id.
#[derive(Debug, Clone, PartialEq)]
pub enum Chat {
    Direct(String),
    Group(String),
}

impl Chat {
    /// The chat_id: `signal:<address>` or `signal:group:<id>`.
    pub fn id(&self) -> String {
        match self {
            Chat::Direct(address) => format!("signal:{address}"),
            Chat::Group(group) => format!("signal:group:{group}"),
        }
    }

    /// The chat behind a chat_id; None for phone conversations.
    pub fn parse(chat_id: &str) -> Option<Chat> {
        let rest = chat_id.strip_prefix("signal:")?;
        if let Some(group) = rest.strip_prefix("group:") {
            return (!group.is_empty()).then(|| Chat::Group(group.to_owned()));
        }
        (!rest.is_empty()).then(|| Chat::Direct(rest.to_owned()))
    }
}

#[derive(Debug, PartialEq)]
pub struct Inbound {
    /// Where to answer.
    pub chat: Chat,
    pub sender: String,
    /// The sender's number or account id, for the read receipt.
    pub sender_address: String,
    /// Empty when the message is only attachments.
    pub text: String,
    pub attachments: Vec<Attachment>,
    /// The message's timestamp, which a read receipt refers to.
    pub timestamp: Option<u64>,
}

/// An attachment as signal-cli reports it: `id` is the name of the file it
/// saved in its attachments directory.
#[derive(Debug, Clone, PartialEq)]
pub struct Attachment {
    pub id: String,
    pub content_type: String,
}

/// Accepts a `receive` notification's params, or says why it is dropped.
/// `accounts` maps resolved account ids to the person owning them.
pub fn classify(
    params: &Value,
    people: &People,
    accounts: &HashMap<String, String>,
) -> Result<Inbound, &'static str> {
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
    // Group messages are answered in the group, as long as the sender is a
    // trusted person; anyone else in the group is ignored.
    let group = match &message["groupInfo"] {
        Value::Null => None,
        info => Some(info["groupId"].as_str().ok_or("group")?),
    };
    // Any file: images, documents, voice notes. The id is the name signal-cli
    // saved it under.
    let attachments: Vec<Attachment> = message["attachments"]
        .as_array()
        .map(|list| {
            list.iter()
                .filter_map(|a| {
                    Some(Attachment {
                        id: a["id"].as_str()?.to_owned(),
                        content_type: a["contentType"]
                            .as_str()
                            .unwrap_or("application/octet-stream")
                            .to_owned(),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let text = message["message"].as_str().unwrap_or("").trim();
    if text.is_empty() && attachments.is_empty() {
        return Err("empty");
    }
    let source = envelope["source"].as_str();
    let by_number = envelope["sourceNumber"]
        .as_str()
        .or_else(|| source.filter(|s| s.starts_with('+')))
        .and_then(|n| people.by_number(n).map(|p| (n, p)));
    let (address, sender) = match by_number {
        Some(found) => found,
        None => {
            let aci = envelope["sourceUuid"]
                .as_str()
                .or_else(|| source.filter(|s| !s.starts_with('+')))
                .ok_or("unknown sender")?;
            let person = accounts.get(aci).ok_or("unknown sender")?;
            (aci, person.as_str())
        }
    };
    Ok(Inbound {
        chat: match group {
            Some(g) => Chat::Group(g.to_owned()),
            None => Chat::Direct(address.to_owned()),
        },
        sender: sender.to_owned(),
        sender_address: address.to_owned(),
        text: text.to_owned(),
        attachments,
        timestamp: envelope["timestamp"].as_u64(),
    })
}

/// The recipient half of a send/sendTyping request for a chat.
fn target(chat: &Chat) -> Value {
    match chat {
        Chat::Direct(address) => json!({ "recipient": [address] }),
        Chat::Group(group) => json!({ "groupId": group }),
    }
}

/// Hands the message to the agent, and shows the sender it was read and
/// is being answered (a read receipt and a typing indicator, which the
/// reply itself ends); whether their phone shows those is up to its own
/// settings.
fn deliver(state: &Arc<State>, m: Inbound) {
    let chat_kind = match m.chat {
        Chat::Direct(_) => "direct",
        Chat::Group(_) => "group",
    };
    eprintln!(
        "sivrad: Signal message from {} ({chat_kind}, {} files)",
        m.sender,
        m.attachments.len()
    );
    if let Chat::Group(group) = &m.chat {
        state.signal.groups.lock().unwrap().insert(group.clone());
    }
    // The text, then one line per file now in the inbox.
    let mut content = m.text.clone();
    for file in files::receive(&state.config, &m.attachments) {
        if !content.is_empty() {
            content.push('\n');
        }
        content.push_str(&file.line());
    }
    codex::run(
        state.clone(),
        Event {
            chat_id: m.chat.id(),
            sender: m.sender.clone(),
            source: Source::Signal {
                chat: m.chat.clone(),
            },
            content,
        },
    );
    let state = state.clone();
    tokio::spawn(async move {
        let signal = &state.signal;
        if let Some(ts) = m.timestamp {
            // Unlike send and sendTyping, sendReceipt takes one recipient,
            // not a list (a list is read as a phone number and fails). In a
            // group it goes to the sender too.
            let receipt =
                json!({ "recipient": &m.sender_address, "targetTimestamp": [ts], "type": "read" });
            if let Err(e) = signal.request("sendReceipt", receipt).await {
                eprintln!("sivrad: read receipt: {e}");
            }
        }
        if let Err(e) = signal.request("sendTyping", target(&m.chat)).await {
            eprintln!("sivrad: typing indicator: {e}");
        }
    });
}

impl Signal {
    pub fn new(socket: PathBuf) -> Self {
        Signal {
            socket,
            writer: Mutex::new(None),
            pending: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            account: Mutex::new(None),
            resolved: Mutex::new(HashMap::new()),
            last_resolve: Mutex::new(None),
            groups: Mutex::new(HashSet::new()),
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
        // Learn the account and resolve usernames in the background;
        // responses arrive below.
        let learner = tokio::spawn({
            let state = state.clone();
            async move {
                state.signal.learn_account().await;
                state.signal.resolve(&state.people()).await;
            }
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

    fn receive(&self, state: &Arc<State>, params: &Value) {
        let people = state.people();
        match classify(params, &people, &self.accounts(&people)) {
            Ok(m) => deliver(state, m),
            // Maybe someone whose username is not resolved yet (added since
            // signal-cli connected, or unresolvable then): try again, once
            // in a while.
            Err("unknown sender") if self.unresolved(&people) && self.cooldown_over() => {
                let state = state.clone();
                let params = params.clone();
                tokio::spawn(async move {
                    let signal = &state.signal;
                    signal.resolve(&people).await;
                    match classify(&params, &people, &signal.accounts(&people)) {
                        Ok(m) => deliver(&state, m),
                        Err(reason) => signal.drop(reason),
                    }
                });
            }
            Err(reason) => self.drop(reason),
        }
    }

    fn drop(&self, reason: &'static str) {
        let mut dropped = self.dropped.lock().unwrap();
        *dropped.entry(reason).or_default() += 1;
        eprintln!("sivrad: dropped a Signal envelope ({reason}); dropped so far: {dropped:?}");
    }

    /// Resolved account ids -> the person owning each, for the usernames in
    /// the table.
    fn accounts(&self, people: &People) -> HashMap<String, String> {
        let resolved = self.resolved.lock().unwrap();
        people
            .signal_usernames()
            .into_iter()
            .filter_map(|u| {
                let aci = resolved.get(u)?;
                let person = people.by_signal_username(u)?;
                Some((aci.clone(), person.to_owned()))
            })
            .collect()
    }

    fn unresolved(&self, people: &People) -> bool {
        let resolved = self.resolved.lock().unwrap();
        people
            .signal_usernames()
            .iter()
            .any(|u| !resolved.contains_key(*u))
    }

    fn cooldown_over(&self) -> bool {
        self.last_resolve
            .lock()
            .unwrap()
            .is_none_or(|t| t.elapsed() >= RESOLVE_COOLDOWN)
    }

    /// Looks up the account ids of the table's Signal usernames that are
    /// not known yet.
    async fn resolve(&self, people: &People) {
        let pending: Vec<String> = {
            let resolved = self.resolved.lock().unwrap();
            people
                .signal_usernames()
                .into_iter()
                .filter(|u| !resolved.contains_key(*u))
                .map(str::to_owned)
                .collect()
        };
        if pending.is_empty() {
            return;
        }
        *self.last_resolve.lock().unwrap() = Some(Instant::now());
        let result = match self
            .request("getUserStatus", json!({ "username": pending }))
            .await
        {
            Ok(r) => r,
            Err(e) => {
                eprintln!("sivrad: resolving Signal usernames: {e}");
                return;
            }
        };
        let Some(entries) = result.as_array() else {
            eprintln!("sivrad: getUserStatus answered with no list");
            return;
        };
        for (i, entry) in entries.iter().enumerate() {
            // Each entry names its username; if not, they come in order.
            let username = entry["username"]
                .as_str()
                .map(str::to_owned)
                .or_else(|| pending.get(i).cloned());
            let aci = entry["uuid"].as_str().or_else(|| entry["aci"].as_str());
            match (username, aci) {
                (Some(u), Some(a)) => {
                    eprintln!("sivrad: Signal username {u} resolved");
                    self.resolved.lock().unwrap().insert(u, a.to_owned());
                }
                (Some(u), None) => eprintln!("sivrad: Signal username {u} is not registered"),
                (None, _) => eprintln!("sivrad: getUserStatus entry without a username"),
            }
        }
    }

    /// Whether a chat may be written to: a person in the table, or a group
    /// one of them has written in.
    pub fn is_trusted(&self, people: &People, chat: &Chat) -> bool {
        match chat {
            Chat::Direct(address) => {
                people.by_number(address).is_some() || self.accounts(people).contains_key(address)
            }
            Chat::Group(group) => self.groups.lock().unwrap().contains(group),
        }
    }

    /// The address to send to a person: their number, or the account id
    /// their Signal username resolves to.
    pub async fn address_of(&self, people: &People, person: &str) -> Result<String, String> {
        match people.signal_of(person) {
            None => Err(format!(
                "unknown person; known: {}",
                people.on_signal().join(", ")
            )),
            Some(SignalId::Number(n)) => Ok(n.to_owned()),
            Some(SignalId::Username(u)) => {
                let known = self.resolved.lock().unwrap().get(u).cloned();
                if let Some(aci) = known {
                    return Ok(aci);
                }
                self.resolve(people).await;
                let known = self.resolved.lock().unwrap().get(u).cloned();
                known.ok_or_else(|| {
                    format!("{person}'s Signal username {u} could not be resolved; is it right, and registered?")
                })
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

    /// Sends to a chat: a number, an account id, or a group. `files` are
    /// paths signal-cli can read (files::outgoing has checked them).
    pub async fn send(&self, chat: &Chat, text: &str, files: &[String]) -> Result<(), String> {
        let mut params = target(chat);
        params["message"] = json!(text);
        if !files.is_empty() {
            params["attachments"] = json!(files);
        }
        self.request("send", params).await.map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn people() -> People {
        People::parse(
            r#"{ "alice": { "signal": "+15550000001" }, "bob": {}, "carol": { "signal": "carol.42" } }"#,
        )
        .unwrap()
    }

    fn envelope(source: &str, data: Value) -> Value {
        json!({ "envelope": { "sourceNumber": source, "source": source, "timestamp": 1, "dataMessage": data }, "account": "+15559999999" })
    }

    /// From someone who does not share their number.
    fn envelope_by_account(aci: &str, data: Value) -> Value {
        json!({ "envelope": { "source": aci, "sourceUuid": aci, "sourceNumber": null, "timestamp": 1, "dataMessage": data }, "account": "+15559999999" })
    }

    fn none() -> HashMap<String, String> {
        HashMap::new()
    }

    #[test]
    fn accepts_a_known_sender() {
        let m = classify(
            &envelope("+15550000001", json!({ "message": "hi" })),
            &people(),
            &none(),
        )
        .unwrap();
        assert_eq!(
            m,
            Inbound {
                chat: Chat::Direct("+15550000001".into()),
                sender: "alice".into(),
                sender_address: "+15550000001".into(),
                text: "hi".into(),
                attachments: vec![],
                timestamp: Some(1),
            }
        );
        // the subscription form wraps the envelope in `result`
        let wrapped = json!({ "subscription": 0, "result": envelope("+15550000001", json!({ "message": "hi" })) });
        assert_eq!(
            classify(&wrapped, &people(), &none()).unwrap().sender,
            "alice"
        );
    }

    #[test]
    fn knows_a_sender_by_account_id() {
        let p = people();
        let message = envelope_by_account("aci-carol", json!({ "message": "hi" }));
        assert_eq!(classify(&message, &p, &none()), Err("unknown sender"));
        let accounts = HashMap::from([("aci-carol".to_owned(), "carol".to_owned())]);
        assert_eq!(
            classify(&message, &p, &accounts).unwrap(),
            Inbound {
                chat: Chat::Direct("aci-carol".into()),
                sender: "carol".into(),
                sender_address: "aci-carol".into(),
                text: "hi".into(),
                attachments: vec![],
                timestamp: Some(1),
            }
        );
        let stranger = envelope_by_account("aci-mallory", json!({ "message": "hi" }));
        assert_eq!(classify(&stranger, &p, &accounts), Err("unknown sender"));
    }

    #[test]
    fn groups_from_trusted_people_only() {
        let p = people();
        let n = none();
        let in_group = |source: &str| {
            envelope(
                source,
                json!({ "message": "hi all", "groupInfo": { "groupId": "g1==", "type": "DELIVER" } }),
            )
        };
        assert_eq!(
            classify(&in_group("+15550000001"), &p, &n).unwrap(),
            Inbound {
                chat: Chat::Group("g1==".into()),
                sender: "alice".into(),
                sender_address: "+15550000001".into(),
                text: "hi all".into(),
                attachments: vec![],
                timestamp: Some(1),
            }
        );
        assert_eq!(
            classify(&in_group("+15550000002"), &p, &n),
            Err("unknown sender")
        );
        let no_id = envelope("+15550000001", json!({ "message": "hi", "groupInfo": {} }));
        assert_eq!(classify(&no_id, &p, &n), Err("group"));
    }

    #[test]
    fn carries_attachments() {
        let p = people();
        let n = none();
        let data = json!({
            "message": "look",
            "attachments": [
                { "contentType": "image/jpeg", "id": "abc.jpg", "size": 3 },
                { "contentType": "application/pdf", "id": "def.pdf" },
                { "contentType": "image/png" }
            ]
        });
        let m = classify(&envelope("+15550000001", data), &p, &n).unwrap();
        assert_eq!(m.text, "look");
        assert_eq!(
            m.attachments,
            [
                Attachment {
                    id: "abc.jpg".into(),
                    content_type: "image/jpeg".into()
                },
                Attachment {
                    id: "def.pdf".into(),
                    content_type: "application/pdf".into()
                }
            ]
        );
        // a file with no text is a message too
        let only_file = json!({ "message": null, "attachments": [{ "id": "x.bin" }] });
        let m = classify(&envelope("+15550000001", only_file), &p, &n).unwrap();
        assert_eq!(m.text, "");
        assert_eq!(m.attachments[0].content_type, "application/octet-stream");
    }

    #[test]
    fn drops_everything_else() {
        let p = people();
        let n = none();
        assert_eq!(
            classify(
                &envelope("+15550000002", json!({ "message": "hi" })),
                &p,
                &n
            ),
            Err("unknown sender")
        );
        assert_eq!(
            classify(&envelope("+15550000001", json!({ "message": "" })), &p, &n),
            Err("empty")
        );
        assert_eq!(
            classify(
                &envelope("+15550000001", json!({ "attachments": [] })),
                &p,
                &n
            ),
            Err("empty")
        );
        let receipt = json!({ "envelope": { "sourceNumber": "+15550000001", "receiptMessage": { "isDelivery": true } } });
        assert_eq!(classify(&receipt, &p, &n), Err("non-message"));
        let typing = json!({ "envelope": { "sourceNumber": "+15550000001", "typingMessage": { "action": "STARTED" } } });
        assert_eq!(classify(&typing, &p, &n), Err("non-message"));
        let sync = json!({ "envelope": { "sourceNumber": "+15550000001", "syncMessage": { "sentMessage": { "message": "x" } } } });
        assert_eq!(classify(&sync, &p, &n), Err("non-message"));
        assert_eq!(classify(&json!({}), &p, &n), Err("malformed"));
    }

    #[test]
    fn chat_ids() {
        assert_eq!(
            Chat::Direct("+15550000001".into()).id(),
            "signal:+15550000001"
        );
        assert_eq!(Chat::Group("g1==".into()).id(), "signal:group:g1==");
        assert_eq!(
            Chat::parse("signal:+15550000001"),
            Some(Chat::Direct("+15550000001".into()))
        );
        assert_eq!(
            Chat::parse("signal:aci-carol"),
            Some(Chat::Direct("aci-carol".into()))
        );
        assert_eq!(
            Chat::parse("signal:group:g1=="),
            Some(Chat::Group("g1==".into()))
        );
        assert_eq!(Chat::parse("signal:group:"), None);
        assert_eq!(Chat::parse("signal:"), None);
        assert_eq!(Chat::parse("c1"), None);
    }

    #[test]
    fn trust() {
        let p = people();
        let signal = Signal::new("/nonexistent.sock".into());
        let direct = |a: &str| Chat::Direct(a.into());
        assert!(signal.is_trusted(&p, &direct("+15550000001")));
        assert!(!signal.is_trusted(&p, &direct("+15550000009")));
        assert!(!signal.is_trusted(&p, &direct("aci-carol")));
        signal
            .resolved
            .lock()
            .unwrap()
            .insert("carol.42".into(), "aci-carol".into());
        assert!(signal.is_trusted(&p, &direct("aci-carol")));
        assert!(!signal.is_trusted(&p, &direct("aci-mallory")));
        // a group only once a trusted person has written in it
        assert!(!signal.is_trusted(&p, &Chat::Group("g1==".into())));
        signal.groups.lock().unwrap().insert("g1==".into());
        assert!(signal.is_trusted(&p, &Chat::Group("g1==".into())));
    }

    #[tokio::test]
    async fn addresses_of_people() {
        let p = people();
        let signal = Signal::new("/nonexistent.sock".into());
        assert_eq!(
            signal.address_of(&p, "alice").await,
            Ok("+15550000001".into())
        );
        assert_eq!(
            signal.address_of(&p, "mallory").await,
            Err("unknown person; known: alice, carol".into())
        );
        // unresolved, and signal-cli is not there to ask
        assert!(signal.address_of(&p, "carol").await.is_err());
        signal
            .resolved
            .lock()
            .unwrap()
            .insert("carol.42".into(), "aci-carol".into());
        assert_eq!(signal.address_of(&p, "carol").await, Ok("aci-carol".into()));
    }

    #[tokio::test]
    async fn sending_without_signal_cli_fails_cleanly() {
        let signal = Signal::new("/nonexistent.sock".into());
        *signal.account.lock().unwrap() = Some("+15559999999".into());
        assert_eq!(
            signal
                .send(&Chat::Direct("+15550000001".into()), "hi", &[])
                .await,
            Err("signal-cli is not running".into())
        );
        assert!(signal.pending.lock().unwrap().is_empty());
    }
}
