//! The slice of the Plaid API this service uses, over ureq.
//!
//! One source file, two crates: a module of `ark` (through mod.rs next to it)
//! and of money-sync (../sync/src/main.rs pulls it in with #[path]). It only
//! depends on serde, serde_json and ureq, which both crates have. Each crate
//! uses a different half of it, hence the allow.
#![allow(dead_code)]
use std::fmt;
use std::thread;
use std::time::{Duration, Instant};

use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Debug)]
pub enum PlaidError {
    /// Plaid answered with an error object.
    Api { code: String, kind: String, message: String },
    /// Could not get an answer, or could not read it.
    Transport(String),
}

impl PlaidError {
    /// Plaid's error_code, e.g. ITEM_LOGIN_REQUIRED.
    pub fn code(&self) -> Option<&str> {
        match self {
            PlaidError::Api { code, .. } => Some(code),
            PlaidError::Transport(_) => None,
        }
    }
}

impl fmt::Display for PlaidError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PlaidError::Api { code, kind, message } => write!(f, "plaid: {kind}/{code}: {message}"),
            PlaidError::Transport(msg) => write!(f, "plaid: {msg}"),
        }
    }
}

impl std::error::Error for PlaidError {}

type Res<T> = Result<T, PlaidError>;

#[derive(Deserialize, Clone, Debug)]
pub struct Account {
    pub account_id: String,
    pub name: String,
    /// Last digits of the account number.
    pub mask: Option<String>,
    /// depository, credit, loan, investment, ...
    #[serde(rename = "type")]
    pub kind: String,
    pub subtype: Option<String>,
    #[serde(default)]
    pub balances: Balances,
}

#[derive(Deserialize, Clone, Debug, Default)]
pub struct Balances {
    pub current: Option<f64>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Transaction {
    pub transaction_id: String,
    pub account_id: String,
    /// Positive for money leaving the account.
    pub amount: f64,
    pub date: String,
    pub name: String,
    #[serde(default)]
    pub merchant_name: Option<String>,
    #[serde(default)]
    pub original_description: Option<String>,
    #[serde(default)]
    pub pending: bool,
    /// Set on a posted transaction that replaces a pending one.
    #[serde(default)]
    pub pending_transaction_id: Option<String>,
}

#[derive(Deserialize, Clone, Debug)]
pub struct Removed {
    pub transaction_id: String,
    pub account_id: String,
}

#[derive(Deserialize)]
struct SyncPage {
    added: Vec<Transaction>,
    modified: Vec<Transaction>,
    removed: Vec<Removed>,
    next_cursor: String,
    has_more: bool,
}

/// Everything that changed at the bank since a cursor.
pub struct Pulled {
    pub added: Vec<Transaction>,
    pub modified: Vec<Transaction>,
    pub removed: Vec<Removed>,
    pub cursor: String,
}

pub enum LinkMode {
    /// Connect a new bank, asking for this many days of history.
    New { days: u32 },
    /// Re-authenticate the item behind this access token.
    Update(String),
}

pub struct LinkSession {
    /// The Hosted Link page for the user to open.
    pub url: String,
    link_token: String,
}

pub struct Plaid {
    base: String,
    client_id: String,
    secret: String,
}

impl Plaid {
    /// `env` is production or sandbox; `base_url` overrides the host (tests).
    pub fn new(env: &str, base_url: Option<&str>, client_id: String, secret: String) -> Plaid {
        Plaid {
            base: base_url.map(str::to_string).unwrap_or_else(|| format!("https://{env}.plaid.com")),
            client_id,
            secret,
        }
    }

    pub fn call<T: DeserializeOwned>(&self, endpoint: &str, body: Value) -> Res<T> {
        let transport = |e: &dyn fmt::Display| PlaidError::Transport(format!("{endpoint}: {e}"));
        let request = ureq::post(&format!("{}{}", self.base, endpoint))
            .set("Content-Type", "application/json")
            .set("PLAID-CLIENT-ID", &self.client_id)
            .set("PLAID-SECRET", &self.secret)
            .set("Plaid-Version", "2020-09-14");
        match request.send_json(body) {
            Ok(resp) => resp.into_json().map_err(|e| transport(&e)),
            Err(ureq::Error::Status(_, resp)) => {
                let v: Value = resp.into_json().map_err(|e| transport(&e))?;
                let field = |k: &str| v[k].as_str().unwrap_or("?").to_string();
                Err(PlaidError::Api {
                    code: field("error_code"),
                    kind: field("error_type"),
                    message: format!("{endpoint}: {}", field("error_message")),
                })
            }
            Err(e) => Err(transport(&e)),
        }
    }

    /// Fails with INVALID_API_KEYS if the client id and secret are not a pair
    /// Plaid knows for this environment. The cheapest call that checks them.
    pub fn check_keys(&self) -> Res<()> {
        let _: Value = self.call("/institutions/get", json!({ "count": 1, "offset": 0, "country_codes": ["US"] }))?;
        Ok(())
    }

    pub fn accounts(&self, access_token: &str) -> Res<Vec<Account>> {
        #[derive(Deserialize)]
        struct Reply {
            accounts: Vec<Account>,
        }
        let reply: Reply = self.call("/accounts/get", json!({ "access_token": access_token }))?;
        Ok(reply.accounts)
    }

    /// Everything that changed since `cursor` (all history when there is
    /// none). None while Plaid is still doing the initial pull for a new item.
    /// The cursor only advances once every page has been read, as Plaid asks.
    pub fn pull(&self, access_token: &str, cursor: Option<&str>) -> Res<Option<Pulled>> {
        let start = cursor.filter(|c| !c.is_empty()).map(str::to_string);
        for attempt in 1.. {
            let mut pulled = Pulled { added: vec![], modified: vec![], removed: vec![], cursor: String::new() };
            let mut next = start.clone();
            let pages: Res<()> = (|| loop {
                let mut body = json!({
                    "access_token": access_token,
                    "count": 500,
                    "options": { "include_original_description": true },
                });
                if let Some(c) = &next {
                    body["cursor"] = json!(c);
                }
                let page: SyncPage = self.call("/transactions/sync", body)?;
                pulled.added.extend(page.added);
                pulled.modified.extend(page.modified);
                pulled.removed.extend(page.removed);
                next = Some(page.next_cursor);
                if !page.has_more {
                    return Ok(());
                }
            })();
            match pages {
                Ok(()) => {}
                // Plaid changed the data under us mid-pagination: start over from the saved cursor.
                Err(e) if e.code() == Some("TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION") && attempt < 3 => continue,
                Err(e) => return Err(e),
            }
            return Ok(match next {
                Some(c) if !c.is_empty() => {
                    pulled.cursor = c;
                    Some(pulled)
                }
                _ => None,
            });
        }
        unreachable!()
    }

    /// Starts a Plaid Hosted Link session: Plaid hosts the page, we poll for
    /// the result, so no web server of our own is needed.
    pub fn link_start(&self, client_name: &str, mode: &LinkMode) -> Res<LinkSession> {
        let mut body = json!({
            "client_name": client_name,
            "language": "en",
            "country_codes": ["US"],
            "user": { "client_user_id": "money-sync" },
            "hosted_link": { "url_lifetime_seconds": 1800 },
        });
        match mode {
            LinkMode::New { days } => {
                body["products"] = json!(["transactions"]);
                body["transactions"] = json!({ "days_requested": days });
            }
            LinkMode::Update(access_token) => body["access_token"] = json!(access_token),
        }
        #[derive(Deserialize)]
        struct Reply {
            link_token: String,
            hosted_link_url: String,
        }
        let reply: Reply = self.call("/link/token/create", body)?;
        Ok(LinkSession { url: reply.hosted_link_url, link_token: reply.link_token })
    }

    /// Waits for the user to finish in the browser. Some(public_token) when a
    /// bank was connected; None when the session ended without one (normal in
    /// update mode, where there is nothing to exchange).
    pub fn link_wait(&self, session: &LinkSession) -> Res<Option<String>> {
        let deadline = Instant::now() + Duration::from_secs(30 * 60);
        loop {
            if Instant::now() > deadline {
                return Err(PlaidError::Transport("the link session expired; run the command again".into()));
            }
            thread::sleep(Duration::from_secs(5));
            let reply: Value = self.call("/link/token/get", json!({ "link_token": session.link_token }))?;
            let sessions = reply["link_sessions"].as_array().cloned().unwrap_or_default();
            let Some(done) = sessions.iter().find(|s| !s["finished_at"].is_null()) else {
                continue;
            };
            if let Some(token) = done["results"]["item_add_results"][0]["public_token"].as_str() {
                return Ok(Some(token.to_string()));
            }
            let exit = &done["on_exit"]["error"];
            return match exit["error_code"].as_str() {
                Some(code) => Err(PlaidError::Api {
                    code: code.to_string(),
                    kind: exit["error_type"].as_str().unwrap_or("?").to_string(),
                    message: format!("Link ended without connecting a bank: {}", exit["error_message"].as_str().unwrap_or("")),
                }),
                None => Ok(None),
            };
        }
    }

    /// Trades a public token from Link for the item's access token.
    pub fn exchange(&self, public_token: &str) -> Res<String> {
        #[derive(Deserialize)]
        struct Reply {
            access_token: String,
        }
        let reply: Reply = self.call("/item/public_token/exchange", json!({ "public_token": public_token }))?;
        Ok(reply.access_token)
    }
}
