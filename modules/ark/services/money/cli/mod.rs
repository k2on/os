//! `ark service money ...`: connect banks through Plaid from a laptop and
//! record the result in the secrets repo. Nothing here needs Actual or the
//! money host to be running; the host picks the new bank up on deploy.
//!
//! This file is found by ../../../cli/build.rs and compiled as a module of
//! the `ark` crate, so `crate::` below is that crate. plaid.rs next to it is
//! shared with the money-sync daemon (../sync); manage.rs holds the commands
//! for running the budget itself (categories, amounts, transactions...).
mod manage;
mod plaid;

use std::collections::BTreeMap;
use std::fs;

use anyhow::{bail, Context, Result};
use clap::{Arg, ArgAction, ArgMatches, Command};
use clap_complete::{ArgValueCandidates, CompletionCandidate};
use serde::Deserialize;

use crate::secrets::Manifest;
use crate::service::{Ctx, Service};
use plaid::{Account, LinkMode, Plaid};

pub static SERVICE: Service = Service {
    name: "money",
    about: "Actual Budget and its Plaid bank sync",
    command,
    run,
};

fn bank_arg() -> Arg {
    Arg::new("bank")
        .required(true)
        .help("Your short handle for the bank, [a-z0-9_]+, e.g. chase")
        .add(ArgValueCandidates::new(linked_banks))
}

fn command() -> Command {
    Command::new("money")
        .subcommand_required(true)
        .arg_required_else_help(true)
        .subcommand(
            Command::new("link")
                .about("Connect a bank through Plaid")
                .long_about(
                    "Connect a bank through Plaid. Asks for the Plaid keys the first time, opens Plaid Link in \
                     your browser, saves the connection (secrets/services/money/links/<bank>.nix and the \
                     money_plaid_<bank> secret) the moment the bank is connected, then asks which of its \
                     accounts should show up in Actual. Commit secrets/ and deploy the money host to start syncing.",
                )
                .arg(bank_arg())
                .arg(
                    Arg::new("update")
                        .long("update")
                        .action(ArgAction::SetTrue)
                        .help("Re-authenticate a linked bank that asked for a fresh login"),
                ),
        )
        .subcommand(
            Command::new("select")
                .about("Choose again which of a linked bank's accounts show up in Actual")
                .arg(bank_arg()),
        )
        .subcommand(Command::new("accounts").about("List the linked banks' accounts and which ones sync into Actual"))
        .subcommand(Command::new("budgets").about("List the budget files on the Actual server (over ssh)"))
        .subcommand(
            Command::new("delete-budget")
                .about("Delete a budget file from the Actual server, e.g. one someone created by accident")
                .long_about(
                    "Delete a budget file from the Actual server, e.g. one someone created by accident by \
                     clicking through Actual's onboarding. Shows the budget and asks before deleting. Runs on \
                     the money host over ssh.",
                )
                .arg(Arg::new("budget").required(true).help("The budget's name, or its file id from `budgets`")),
        )
        .subcommand(
            Command::new("sync")
                .about("Import now: starts money-sync on the money host over ssh and shows its log")
                .long_about(
                    "Import now instead of waiting for the timer: runs `systemctl start money-sync` on the host \
                     that has the money service (see `ark hosts`) over ssh and prints that run's journal.",
                ),
        )
        .subcommands(manage::commands())
}

fn run(ctx: &Ctx, m: &ArgMatches) -> Result<()> {
    let bank = |m: &ArgMatches| m.get_one::<String>("bank").expect("required").clone();
    match m.subcommand() {
        Some(("link", m)) => link(ctx, &bank(m), m.get_flag("update")),
        Some(("select", m)) => select(ctx, &bank(m)),
        Some(("accounts", _)) => accounts(ctx),
        Some(("budgets", _)) => budgets(ctx),
        Some(("delete-budget", m)) => delete_budget(ctx, m.get_one::<String>("budget").expect("required")),
        Some(("sync", _)) => sync(ctx),
        Some((name, m)) => manage::run(ctx, name, m).unwrap_or_else(|| unreachable!("clap only accepts known commands")),
        None => unreachable!("subcommand_required"),
    }
}

/// A budget file as `money-sync budgets --json` reports it (sync/src/budgets.rs).
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Budget {
    file_id: String,
    name: String,
    #[serde(default)]
    users_with_access: Vec<BudgetAccess>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BudgetAccess {
    user_name: Option<String>,
    display_name: Option<String>,
    #[serde(default)]
    owner: bool,
}

impl Budget {
    fn owner(&self) -> String {
        self.users_with_access
            .iter()
            .find(|a| a.owner)
            .and_then(|a| a.display_name.clone().filter(|s| !s.is_empty()).or(a.user_name.clone()))
            .unwrap_or_else(|| "?".to_string())
    }
}

/// `ark service money budgets`: the budget files on the server.
fn budgets(ctx: &Ctx) -> Result<()> {
    let hosts = ctx.hosts()?;
    hosts.running("money")?.ssh("sudo money-sync budgets")
}

/// `ark service money delete-budget <name|id>`: with a look and a yes first.
fn delete_budget(ctx: &Ctx, which: &str) -> Result<()> {
    let hosts = ctx.hosts()?;
    let host = hosts.running("money")?;
    let listed: Vec<Budget> = serde_json::from_str(&host.ssh_output("sudo money-sync budgets --json")?)
        .context("reading the budget list from the host")?;
    let matches: Vec<&Budget> = listed.iter().filter(|b| b.file_id == which || b.name == which).collect();
    let budget = match matches[..] {
        [one] => one,
        [] => bail!("no budget named '{which}' (nor with that file id); `ark service money budgets` lists them"),
        _ => bail!("{} budgets are named '{which}'; pick one by file id from `ark service money budgets`", matches.len()),
    };
    println!("Budget '{}' ({}), owned by {}.", budget.name, budget.file_id, budget.owner());
    println!("Deleting removes it from the server for everyone; what people have open locally is not touched.");
    let answer = ctx.prompt("Delete it? [y/N]")?;
    if !matches!(answer.trim(), "y" | "Y" | "yes") {
        println!("left alone");
        return Ok(());
    }
    host.ssh(&format!("sudo money-sync delete-budget {}", budget.file_id))
}

/// `ark service money sync`: one import on the host, right now, with its log.
fn sync(ctx: &Ctx) -> Result<()> {
    let hosts = ctx.hosts()?;
    let host = hosts.running("money")?;
    println!("starting money-sync on {host} (this waits for the import to finish)...");
    // The journal of exactly this run: systemctl start blocks until the
    // oneshot is done, and the invocation id picks out its lines.
    host.ssh(
        "sudo systemctl start money-sync; status=$?; \
         sudo journalctl -o cat --no-pager _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value money-sync); \
         exit $status",
    )
    .context("the import failed; the log above says why")
}

/// Tab completion for <bank>: the banks already linked (their files under
/// secrets/services/money/links). Reads the directory rather than `nix eval`,
/// which is too slow for a keystroke.
fn linked_banks() -> Vec<CompletionCandidate> {
    let Ok(ctx) = Ctx::discover() else { return vec![] };
    let Ok(entries) = fs::read_dir(ctx.root.join("secrets/services/money/links")) else { return vec![] };
    let mut names: Vec<String> = entries
        .flatten()
        .filter_map(|e| e.file_name().into_string().ok()?.strip_suffix(".nix").map(str::to_string))
        .collect();
    names.sort();
    names.into_iter().map(|n| CompletionCandidate::new(n).help(Some("linked bank".into()))).collect()
}

const CLIENT_ID: &str = "money_plaid_client_id";
const SECRET: &str = "money_plaid_secret";

fn item_secret(bank: &str) -> String {
    format!("money_plaid_{bank}")
}

/// Plaid for the configured environment; ARK_PLAID_URL points it at a mock (tests).
fn plaid(cfg: &Config, client_id: String, secret: String) -> Plaid {
    Plaid::new(&cfg.plaid.env, std::env::var("ARK_PLAID_URL").ok().as_deref(), client_id, secret)
}

/// What the nix side exports for us: the `arkServiceConfig.money` flake
/// output, defined in ../default.nix.
#[derive(Deserialize)]
struct Config {
    plaid: PlaidConfig,
    /// Actual account name -> the Plaid account feeding it.
    accounts: BTreeMap<String, Mapping>,
    /// Days of history to ask for when linking.
    history: u32,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlaidConfig {
    env: String,
    client_name: String,
    /// Linked banks, as declared by secrets/services/money/links/*.nix.
    items: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Mapping {
    item: String,
    mask: Option<String>,
    account_id: Option<String>,
}

impl Config {
    fn load(ctx: &Ctx) -> Result<Config> {
        serde_json::from_value(ctx.nix_eval("arkServiceConfig.money")?).context("reading arkServiceConfig.money")
    }

    fn linked(&self, bank: &str) -> bool {
        self.plaid.items.iter().any(|i| i == bank)
    }

    /// The Actual account a Plaid account feeds, if it is synced.
    fn synced_as(&self, item: &str, account: &Account) -> Option<&str> {
        self.accounts
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
}

/// Plaid, with API credentials from the secrets repo, or asked for the first
/// time. Freshly typed keys are checked with Plaid before they are stored, so
/// a typo never ends up encrypted where only the yubikey can fix it.
fn plaid_client(ctx: &Ctx, manifest: &Manifest, cfg: &Config) -> Result<Plaid> {
    let stored = manifest.present(ctx, CLIENT_ID) && manifest.present(ctx, SECRET);
    let (client_id, secret) = if stored {
        eprintln!("decrypting the Plaid keys (touch the yubikey when it blinks)");
        (manifest.read(ctx, CLIENT_ID)?, manifest.read(ctx, SECRET)?)
    } else {
        eprintln!("The Plaid keys are not in secrets/vars yet. They are under Developers -> Keys in");
        eprintln!("dashboard.plaid.com; the secret must be the one for the {} environment.", cfg.plaid.env);
        let client_id = ctx.prompt_hidden("Plaid client id")?;
        let secret = ctx.prompt_hidden("Plaid secret")?;
        if client_id.is_empty() || secret.is_empty() {
            bail!("the Plaid keys cannot be empty");
        }
        (client_id, secret)
    };

    let plaid = plaid(cfg, client_id.clone(), secret.clone());
    if let Err(e) = plaid.check_keys() {
        if e.code() == Some("INVALID_API_KEYS") {
            if stored {
                bail!(
                    "Plaid rejected the stored keys ({e}). Fix them with `ark sops money.yaml` (they must be the \
                     {} pair from dashboard.plaid.com -> Developers -> Keys)",
                    cfg.plaid.env
                );
            }
            bail!(
                "Plaid rejected these keys ({e}); nothing was stored. Check them against dashboard.plaid.com -> \
                 Developers -> Keys (the secret must be the {} one) and run again",
                cfg.plaid.env
            );
        }
        return Err(e).context("reaching Plaid");
    }

    if !stored {
        let file = manifest.spec(CLIENT_ID)?.file.clone();
        let values = BTreeMap::from([(CLIENT_ID.to_string(), client_id), (SECRET.to_string(), secret)]);
        manifest.store(ctx, &file, &values).context("storing the Plaid keys")?;
        eprintln!("stored the Plaid keys in secrets/vars/{file}.yaml");
    }
    Ok(plaid)
}

fn describe(a: &Account) -> String {
    format!(
        "{}  mask {}  {}/{}",
        a.name,
        a.mask.as_deref().unwrap_or("????"),
        a.kind,
        a.subtype.as_deref().unwrap_or("-")
    )
}

fn link(ctx: &Ctx, bank: &str, update: bool) -> Result<()> {
    if bank.is_empty() || !bank.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_') {
        bail!("the bank name is your short handle for it, [a-z0-9_]+, e.g. chase");
    }

    let cfg = Config::load(ctx)?;
    let manifest = Manifest::load(ctx)?;
    let key = item_secret(bank);
    if update && !cfg.linked(bank) {
        bail!("'{bank}' is not linked yet; run without --update");
    }
    if cfg.linked(bank) && !update && manifest.present(ctx, &key) {
        bail!(
            "'{bank}' is already linked: `ark service money select {bank}` changes which accounts sync, \
             --update re-authenticates it. To start over, delete secrets/services/money/links/{bank}.nix \
             and the {key} entry in secrets/vars/money.yaml first"
        );
    }

    let plaid = plaid_client(ctx, &manifest, &cfg)?;
    let mode = if update {
        eprintln!("decrypting {key}");
        LinkMode::Update(manifest.read(ctx, &key)?)
    } else {
        LinkMode::New { days: cfg.history }
    };

    let session = plaid.link_start(&cfg.plaid.client_name, &mode)?;
    println!("Open this in a browser and log in to the bank (the link is good for 30 minutes):\n\n  {}\n\nWaiting for Plaid...", session.url);
    let public_token = match (plaid.link_wait(&session)?, &mode) {
        (Some(token), _) => token,
        (None, LinkMode::Update(_)) => {
            println!("\n{bank} is re-authenticated; the next sync carries on where it stopped.");
            return Ok(());
        }
        (None, LinkMode::New { .. }) => bail!("Link was closed without connecting a bank; nothing changed"),
    };
    let token = plaid.exchange(&public_token)?;
    let found = plaid.accounts(&token)?;

    // Save first. The connection now exists at Plaid and counts against the
    // plan, so nothing asked below may lose it: every account starts out
    // synced, and the choice that follows only edits the file.
    write_link(ctx, bank, &found, &vec![true; found.len()])?;
    let manifest = Manifest::load(ctx)?; // the token's secret is declared by the file just written
    let file = manifest.spec(&key)?.file.clone();
    manifest
        .store(ctx, &file, &BTreeMap::from([(key.clone(), token)]))
        .with_context(|| format!("storing {key}"))?;
    println!("\nConnected and saved: secrets/services/money/links/{bank}.nix and the {key} secret.");

    choose(ctx, bank, &found)?;
    println!("\nAll done, you can apply the changes: commit secrets/ and deploy the money host.");
    Ok(())
}

/// `ark service money select <bank>`: redo the choice of accounts.
fn select(ctx: &Ctx, bank: &str) -> Result<()> {
    let cfg = Config::load(ctx)?;
    let manifest = Manifest::load(ctx)?;
    let key = item_secret(bank);
    if !cfg.linked(bank) || !manifest.present(ctx, &key) {
        bail!("'{bank}' is not linked; run `ark service money link {bank}` first");
    }
    let plaid = plaid_client(ctx, &manifest, &cfg)?;
    let found = plaid.accounts(&manifest.read(ctx, &key)?)?;
    choose(ctx, bank, &found)?;
    println!("\nApply the change: commit secrets/ and deploy the money host.");
    Ok(())
}

/// Asks which of the bank's accounts should show up in Actual and rewrites the
/// link file accordingly.
fn choose(ctx: &Ctx, bank: &str, found: &[Account]) -> Result<()> {
    println!("\nAccounts at this bank:\n");
    for (i, a) in found.iter().enumerate() {
        println!("  {}. {}", i + 1, describe(a));
    }
    println!("\nEach one you pick becomes an account of the same name in Actual, created on the first sync.");
    let selected = loop {
        let answer = ctx.prompt("Which should show up in Actual? Numbers like `1 3`, or Enter for all")?;
        let answer = answer.trim();
        if answer.is_empty() {
            break vec![true; found.len()];
        }
        let mut selected = vec![false; found.len()];
        let mut ok = true;
        for word in answer.split(|c: char| c.is_whitespace() || c == ',').filter(|w| !w.is_empty()) {
            match word.parse::<usize>() {
                Ok(n) if (1..=found.len()).contains(&n) => selected[n - 1] = true,
                _ => {
                    eprintln!("'{word}' is not one of the numbers above");
                    ok = false;
                }
            }
        }
        if ok {
            break selected;
        }
    };

    write_link(ctx, bank, found, &selected)?;
    let names = actual_names(found, &selected);
    let synced: Vec<&str> = names.iter().flatten().map(String::as_str).collect();
    let skipped: Vec<String> = found.iter().zip(&selected).filter(|(_, s)| !**s).map(|(a, _)| a.name.clone()).collect();
    println!("\nSyncing into Actual: {}", if synced.is_empty() { "nothing".to_string() } else { synced.join(", ") });
    if !skipped.is_empty() {
        println!("Not syncing: {}", skipped.join(", "));
    }
    println!("Change your mind later with `ark service money select {bank}`, or edit secrets/services/money/links/{bank}.nix.");
    Ok(())
}

/// The Actual account name for each selected account: the bank's name for it,
/// with the mask appended where two selected accounts share a name.
fn actual_names(found: &[Account], selected: &[bool]) -> Vec<Option<String>> {
    found
        .iter()
        .zip(selected)
        .map(|(a, &s)| {
            if !s {
                return None;
            }
            let twins = found.iter().zip(selected).filter(|(o, &os)| os && o.name == a.name).count();
            Some(if twins > 1 {
                format!("{} (…{})", a.name, a.mask.as_deref().unwrap_or(&a.account_id))
            } else {
                a.name.clone()
            })
        })
        .collect()
}

fn nix_str(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\"").replace("${", "\\${"))
}

/// Writes (and stages) secrets/services/money/links/<bank>.nix: the flake
/// module that declares the bank and which of its accounts feed Actual.
fn write_link(ctx: &Ctx, bank: &str, found: &[Account], selected: &[bool]) -> Result<()> {
    let names = actual_names(found, selected);
    let mut s = format!(
        "# Written by `ark service money link {bank}`; `ark service money select {bank}`\n\
         # redoes the choice below. Each entry is an account of that name in Actual,\n\
         # created on the first sync if it does not exist yet. Rename the key before\n\
         # that first sync to pick a different name; remove an entry to stop syncing it.\n\
         {{ ... }}:\n\
         {{\n\
         \x20 ark.money.plaid.items.{bank} = {{ }};\n\
         \x20 ark.money.accounts = {{\n"
    );
    for (a, name) in found.iter().zip(&names) {
        match name {
            Some(name) => {
                let by = match &a.mask {
                    Some(mask) => format!("mask = {};", nix_str(mask)),
                    None => format!("accountId = {};", nix_str(&a.account_id)),
                };
                s += &format!(
                    "    {} = {{\n      item = {};\n      {by}\n    }}; # {}/{}\n",
                    nix_str(name),
                    nix_str(bank),
                    a.kind,
                    a.subtype.as_deref().unwrap_or("-")
                );
            }
            None => s += &format!("    # not synced: {}  {}\n", describe(a), a.account_id),
        }
    }
    s += "  };\n}\n";

    // Inside the secrets submodule; staged there so the flake (which only
    // sees tracked files) picks the declaration up.
    let rel = format!("services/money/links/{bank}.nix");
    let path = ctx.root.join("secrets").join(&rel);
    fs::create_dir_all(path.parent().expect("parent"))?;
    fs::write(&path, s).with_context(|| format!("writing secrets/{rel}"))?;
    ctx.git_secrets(&["add", &rel])
}

fn accounts(ctx: &Ctx) -> Result<()> {
    let cfg = Config::load(ctx)?;
    if cfg.plaid.items.is_empty() {
        println!("no banks linked yet; run `ark service money link <bank>`");
        return Ok(());
    }
    let manifest = Manifest::load(ctx)?;
    let plaid = plaid_client(ctx, &manifest, &cfg)?;

    for item in &cfg.plaid.items {
        println!("{item}:");
        let key = item_secret(item);
        if !manifest.present(ctx, &key) {
            println!("  token {key} is missing; run `ark service money link {item}`");
            continue;
        }
        match plaid.accounts(&manifest.read(ctx, &key)?) {
            Ok(found) => {
                for a in &found {
                    match cfg.synced_as(item, a) {
                        Some(name) if name == a.name => println!("  {}  -> synced", describe(a)),
                        Some(name) => println!("  {}  -> synced as '{name}'", describe(a)),
                        None => println!("  {}  -> not synced", describe(a)),
                    }
                }
            }
            Err(e) if e.code() == Some("ITEM_LOGIN_REQUIRED") => {
                println!("  the bank wants a fresh login: ark service money link {item} --update")
            }
            Err(e) => println!("  {e}"),
        }
    }
    for (name, m) in &cfg.accounts {
        if !cfg.linked(&m.item) {
            println!("warning: '{name}' maps to '{}', which is not linked", m.item);
        }
    }
    Ok(())
}
