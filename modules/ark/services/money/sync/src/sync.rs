//! `money-sync sync`: for every linked bank, pull what changed since the last
//! run and hand it to actual-import.
//!
//! One Plaid cursor per bank lives in the state file, so a run only sees what
//! changed. Plaid's transaction id travels as Actual's imported_id, which is
//! what makes re-runs idempotent; the pending -> posted and dedup logic sits
//! in actual-import, next to the budget data it needs.
use std::collections::BTreeMap;
use std::fs;
use std::io::ErrorKind;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::config::{read_secret, Config};
use crate::plaid::{Account, Plaid, PlaidError, Transaction};
use crate::{bail, Result};

trait OrContext<T> {
    fn context(self, what: &str) -> Result<T>;
}

impl<T> OrContext<T> for Option<T> {
    fn context(self, what: &str) -> Result<T> {
        self.ok_or_else(|| what.to_string().into())
    }
}

#[derive(Serialize, Deserialize, Default)]
struct State {
    items: BTreeMap<String, ItemState>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ItemState {
    cursor: String,
    synced_at: u64,
}

impl State {
    fn load(path: &Path) -> Result<State> {
        match fs::read_to_string(path) {
            Ok(text) => Ok(serde_json::from_str(&text)?),
            Err(e) if e.kind() == ErrorKind::NotFound => Ok(State::default()),
            Err(e) => Err(e.into()),
        }
    }

    fn save(&self, path: &Path) -> Result<()> {
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        let tmp = path.with_extension("json.tmp");
        fs::write(&tmp, serde_json::to_string_pretty(self)?)?;
        fs::rename(&tmp, path)?;
        Ok(())
    }
}

/// One Actual account's changes, as actual-import takes them.
#[derive(Serialize)]
struct Batch<'a> {
    name: &'a str,
    /// Plaid's account type; decides on/off budget if Actual has to create the account.
    #[serde(rename = "type")]
    kind: &'a str,
    /// The bank's current balance in cents, Actual's sign; sets the opening
    /// balance if Actual has to create the account.
    balance: Option<i64>,
    upserts: Vec<Upsert>,
    removed: Vec<String>,
}

#[derive(Serialize)]
struct Upsert {
    transaction_id: String,
    pending_transaction_id: Option<String>,
    entity: Value,
}

#[derive(Deserialize)]
struct Report {
    accounts: Vec<AccountReport>,
}

#[derive(Deserialize)]
struct AccountReport {
    name: String,
    /// The Actual account did not exist and was created on this run.
    #[serde(default)]
    created: bool,
    /// The opening balance transaction that came with creating it, in cents.
    opening: Option<i64>,
    #[serde(default)]
    added: u32,
    #[serde(default)]
    updated: u32,
    #[serde(default)]
    deleted: u32,
    /// Reconciled transactions left alone.
    #[serde(default)]
    locked: u32,
    /// Actual's balance for the account, in cents.
    balance: Option<i64>,
}

fn cents(amount: f64) -> i64 {
    (amount * 100.0).round() as i64
}

/// The bank's balance as Actual counts it: what you owe on a card or loan is negative.
fn bank_balance(account: &Account, current: f64) -> i64 {
    let owed = account.kind == "credit" || account.kind == "loan";
    cents(if owed { -current } else { current })
}

fn money(cents: i64) -> String {
    format!("{}{}.{:02}", if cents < 0 { "-" } else { "" }, cents.abs() / 100, cents.abs() % 100)
}

/// A Plaid transaction as Actual wants it. Plaid's amount is positive for
/// money leaving the account; Actual's is the opposite.
fn entity(t: &Transaction) -> Value {
    let non_empty = |s: &Option<String>| s.clone().filter(|s| !s.is_empty());
    json!({
        "date": t.date,
        "amount": cents(-t.amount),
        "imported_id": t.transaction_id,
        "imported_payee": non_empty(&t.original_description).unwrap_or_else(|| t.name.clone()),
        "payee_name": non_empty(&t.merchant_name).unwrap_or_else(|| t.name.clone()),
        "cleared": !t.pending,
    })
}

/// The Actual account a Plaid account feeds, per the config's mapping.
fn mapped<'c>(cfg: &'c Config, item: &str, account: &Account) -> Option<&'c str> {
    cfg.accounts
        .iter()
        .find(|(_, m)| {
            m.item == item
                && match &m.account_id {
                    Some(id) => *id == account.account_id,
                    None => m.mask == account.mask,
                }
        })
        .map(|(name, _)| name.as_str())
}

/// Actual has no readiness signal, and this runs right after it starts: wait
/// until the server answers at all (any HTTP status), up to a minute.
fn wait_for_actual(server_url: &str) -> Result<()> {
    for attempt in 0..60 {
        match ureq::get(server_url).call() {
            Ok(_) | Err(ureq::Error::Status(..)) => return Ok(()),
            Err(_) if attempt == 0 => println!("waiting for actual at {server_url}..."),
            Err(_) => {}
        }
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
    bail!("actual at {server_url} did not answer within a minute");
}

pub fn run() -> Result<()> {
    let cfg = Config::load()?;
    if cfg.plaid.items.is_empty() {
        println!("no banks linked (ark.money.plaid.items); nothing to do");
        return Ok(());
    }
    let server_url = cfg.actual["serverURL"].as_str().context("actual.serverURL missing from the config")?;
    wait_for_actual(server_url)?;
    let plaid = Plaid::new(
        &cfg.plaid.env,
        cfg.plaid.base_url.as_deref(),
        read_secret(&cfg.plaid.client_id_file)?,
        read_secret(&cfg.plaid.secret_file)?,
    );
    let mut state = State::load(&cfg.state_file)?;
    for (name, m) in &cfg.accounts {
        if !cfg.plaid.items.contains_key(&m.item) {
            println!("warning: '{name}' maps to '{}', which is not linked", m.item);
        }
    }

    let mut failed = 0;
    for (item, spec) in &cfg.plaid.items {
        let result = read_secret(&spec.access_token_file).and_then(|token| sync_item(&cfg, &plaid, item, &token, &mut state));
        if let Err(e) = result {
            failed += 1;
            match e.downcast_ref::<PlaidError>().and_then(PlaidError::code) {
                Some("ITEM_LOGIN_REQUIRED") => {
                    println!("{item}: the bank wants a fresh login; run `ark service money link {item} --update` from a laptop")
                }
                _ => println!("{item}: failed: {e}"),
            }
        }
    }
    if failed > 0 {
        bail!("{failed} bank(s) failed; see above");
    }
    Ok(())
}

fn sync_item(cfg: &Config, plaid: &Plaid, item: &str, token: &str, state: &mut State) -> Result<()> {
    let accounts = plaid.accounts(token)?;
    // plaid account_id -> (plaid account, Actual account name)
    let mut targets: BTreeMap<&str, (&Account, &str)> = BTreeMap::new();
    for a in &accounts {
        match mapped(cfg, item, a) {
            Some(name) => {
                targets.insert(&a.account_id, (a, name));
            }
            None => println!(
                "{item}: '{}' (mask {}) is not mapped to an Actual account; skipping",
                a.name,
                a.mask.as_deref().unwrap_or("????")
            ),
        }
    }
    if targets.is_empty() {
        println!("{item}: no mapped accounts; skipping");
        return Ok(());
    }

    let cursor = state.items.get(item).map(|s| s.cursor.as_str());
    let Some(pulled) = plaid.pull(token, cursor)? else {
        println!("{item}: Plaid has not finished the initial pull yet; will pick it up next run");
        return Ok(());
    };
    println!(
        "{item}: {} added, {} modified, {} removed at the bank",
        pulled.added.len(),
        pulled.modified.len(),
        pulled.removed.len()
    );

    let mut batches: BTreeMap<&str, Batch> = targets
        .iter()
        .map(|(id, (account, name))| {
            let balance = account.balances.current.map(|c| bank_balance(account, c));
            (*id, Batch { name, kind: &account.kind, balance, upserts: vec![], removed: vec![] })
        })
        .collect();
    for t in pulled.added.iter().chain(&pulled.modified) {
        if let Some(batch) = batches.get_mut(t.account_id.as_str()) {
            batch.upserts.push(Upsert {
                transaction_id: t.transaction_id.clone(),
                pending_transaction_id: t.pending_transaction_id.clone(),
                entity: entity(t),
            });
        }
    }
    for r in &pulled.removed {
        if let Some(batch) = batches.get_mut(r.account_id.as_str()) {
            batch.removed.push(r.transaction_id.clone());
        }
    }

    let report = actual_import(cfg, batches.values().collect())?;
    for r in &report.accounts {
        if r.created {
            match r.opening {
                Some(opening) => println!(
                    "{item}: created the Actual account '{}' with an opening balance of {} (bank balance minus the imported history)",
                    r.name,
                    money(opening)
                ),
                None => println!("{item}: created the Actual account '{}'", r.name),
            }
        }
        let locked = if r.locked > 0 { format!(", {} left alone (reconciled)", r.locked) } else { String::new() };
        println!("{item}: {}: {} added, {} updated, {} deleted{locked}", r.name, r.added, r.updated, r.deleted);
    }

    let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    state.items.insert(item.to_string(), ItemState { cursor: pulled.cursor, synced_at: now });
    state.save(&cfg.state_file)?;

    // Informational: pending transactions and timing make small differences normal.
    for (account, name) in targets.values() {
        let (Some(current), Some(r)) = (account.balances.current, report.accounts.iter().find(|r| r.name == *name)) else {
            continue;
        };
        let bank = bank_balance(account, current);
        if let Some(ours) = r.balance {
            if ours != bank {
                println!("{item}: {name}: Actual {} vs bank {}", money(ours), money(bank));
            }
        }
    }
    Ok(())
}

/// Runs actual-import with the change set and reads its report.
fn actual_import(cfg: &Config, batches: Vec<&Batch>) -> Result<Report> {
    let answer = crate::actual::call(cfg, json!({ "actual": cfg.actual, "accounts": batches }))?;
    Ok(serde_json::from_value(answer).map_err(|e| format!("actual-import: unreadable report: {e}"))?)
}
