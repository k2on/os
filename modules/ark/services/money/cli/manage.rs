//! `ark service money ...` for running the budget itself: categories, the
//! month's amounts, transactions and their categories, spending totals,
//! payees, rules. Each command is one `money-sync actual <op> <json>` on the
//! money host over ssh (ops live in ../sync/actual-import/src/ops.ts); this
//! side turns arguments into JSON and answers into tables.
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{bail, Context, Result};
use clap::{Arg, ArgAction, ArgMatches, Command};
use serde_json::{json, Value};

use crate::service::Ctx;

// ---------------------------------------------------------------- plumbing

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// One op on the host, its JSON result back.
fn op(ctx: &Ctx, op: &str, args: Value) -> Result<Value> {
    let hosts = ctx.hosts()?;
    let out = hosts.running("money")?.ssh_output(&format!("sudo money-sync actual {op} {}", shell_quote(&args.to_string())))?;
    serde_json::from_str(out.trim()).with_context(|| format!("reading the answer to {op}"))
}

/// Cents as people read them: 1,234.56 and -1,234.56.
pub fn money(cents: i64) -> String {
    let whole = (cents.abs() / 100).to_string();
    let mut grouped = String::new();
    for (i, ch) in whole.chars().enumerate() {
        if i > 0 && (whole.len() - i) % 3 == 0 {
            grouped.push(',');
        }
        grouped.push(ch);
    }
    format!("{}{grouped}.{:02}", if cents < 0 { "-" } else { "" }, cents.abs() % 100)
}

/// "12.34", "-12.34", "$1,234.5" -> cents.
fn cents(text: &str) -> Result<i64> {
    let s: String = text.chars().filter(|c| *c != '$' && *c != ',' && !c.is_whitespace()).collect();
    let (neg, s) = match s.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, s.as_str()),
    };
    let (whole, frac) = s.split_once('.').unwrap_or((s, ""));
    if whole.is_empty() && frac.is_empty() || !whole.chars().all(|c| c.is_ascii_digit()) || !frac.chars().all(|c| c.is_ascii_digit()) || frac.len() > 2 {
        bail!("'{text}' is not an amount like 12.34 or -1,234.56");
    }
    let whole: i64 = if whole.is_empty() { 0 } else { whole.parse()? };
    let frac: i64 = if frac.is_empty() { 0 } else { format!("{frac:0<2}").parse()? };
    let value = whole * 100 + frac;
    Ok(if neg { -value } else { value })
}

/// Today's month as YYYY-MM, from the clock alone (civil-from-days).
fn current_month() -> String {
    let days = (SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0) / 86_400) as i64;
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}")
}

fn month_of(m: &ArgMatches) -> Result<String> {
    let month = m.get_one::<String>("month").cloned().unwrap_or_else(current_month);
    let ok = month.len() == 7 && month.as_bytes()[4] == b'-' && month[..4].chars().all(|c| c.is_ascii_digit()) && month[5..].chars().all(|c| c.is_ascii_digit());
    if !ok {
        bail!("'{month}' is not a month like 2026-09");
    }
    Ok(month)
}

/// --month, or --since/--until; the current month by default. Dates compare
/// as text in Actual, so a 31st is a fine upper bound for any month.
fn period_of(m: &ArgMatches) -> Result<(String, String)> {
    match (m.get_one::<String>("since"), m.get_one::<String>("until")) {
        (None, None) => {
            let month = month_of(m)?;
            Ok((format!("{month}-01"), format!("{month}-31")))
        }
        (since, until) => Ok((
            since.cloned().unwrap_or_else(|| "2000-01-01".to_string()),
            until.cloned().unwrap_or_else(|| "2100-01-01".to_string()),
        )),
    }
}

fn month_arg() -> Arg {
    Arg::new("month").short('m').long("month").value_name("YYYY-MM").help("The month (this month by default)")
}

fn period_args(cmd: Command) -> Command {
    cmd.arg(month_arg())
        .arg(Arg::new("since").long("since").value_name("YYYY-MM-DD").help("Start of a range instead of a month"))
        .arg(Arg::new("until").long("until").value_name("YYYY-MM-DD").help("End of that range (inclusive)"))
}

struct Table {
    head: Vec<&'static str>,
    right: Vec<bool>,
    rows: Vec<Vec<String>>,
}

impl Table {
    fn new(head: Vec<&'static str>, right: Vec<bool>) -> Table {
        Table { head, right, rows: vec![] }
    }
    fn row(&mut self, cells: Vec<String>) {
        self.rows.push(cells);
    }
    fn print(&self) {
        if self.rows.is_empty() {
            println!("(nothing)");
            return;
        }
        let widths: Vec<usize> = (0..self.head.len())
            .map(|i| self.rows.iter().map(|r| r.get(i).map_or(0, |c| c.chars().count())).chain([self.head[i].len()]).max().unwrap_or(0))
            .collect();
        let line = |cells: Vec<String>| {
            cells
                .iter()
                .enumerate()
                .map(|(i, c)| if self.right[i] { format!("{c:>w$}", w = widths[i]) } else { format!("{c:<w$}", w = widths[i]) })
                .collect::<Vec<_>>()
                .join("  ")
                .trim_end()
                .to_string()
        };
        println!("{}", line(self.head.iter().map(|h| h.to_string()).collect()));
        for r in &self.rows {
            println!("{}", line(r.clone()));
        }
    }
}

fn s(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}
fn n(v: &Value) -> i64 {
    v.as_i64().unwrap_or(0)
}
fn arr(v: &Value) -> Vec<Value> {
    v.as_array().cloned().unwrap_or_default()
}
fn strings(m: &ArgMatches, id: &str) -> Vec<String> {
    m.get_many::<String>(id).map(|v| v.cloned().collect()).unwrap_or_default()
}
fn get(m: &ArgMatches, id: &str) -> Option<String> {
    m.get_one::<String>(id).cloned()
}
fn need(m: &ArgMatches, id: &str) -> String {
    get(m, id).expect("required by clap")
}

// ---------------------------------------------------------------- commands

pub fn commands() -> Vec<Command> {
    let category_arg = |help: &'static str| Arg::new("category").required(true).help(help);
    vec![
        Command::new("balances").about("Actual's accounts and their balances"),
        Command::new("categories").about("The category groups and categories"),
        Command::new("category")
            .about("Add, rename, move, hide or delete a category")
            .subcommand_required(true)
            .arg_required_else_help(true)
            .subcommand(
                Command::new("add")
                    .about("Add a category (and its group, if new)")
                    .arg(Arg::new("group").required(true).help("Group, e.g. Bills"))
                    .arg(Arg::new("name").required(true).help("Category, e.g. Internet")),
            )
            .subcommand(Command::new("rename").arg(Arg::new("name").required(true)).arg(Arg::new("new").required(true)))
            .subcommand(Command::new("move").about("Move a category to another group").arg(Arg::new("name").required(true)).arg(Arg::new("group").required(true)))
            .subcommand(Command::new("hide").arg(Arg::new("name").required(true)))
            .subcommand(Command::new("unhide").arg(Arg::new("name").required(true)))
            .subcommand(
                Command::new("delete")
                    .arg(Arg::new("name").required(true))
                    .arg(Arg::new("move-to").long("move-to").value_name("CATEGORY").help("Where its transactions and budget go")),
            ),
        Command::new("group")
            .about("Add, rename or delete a category group")
            .subcommand_required(true)
            .arg_required_else_help(true)
            .subcommand(
                Command::new("add")
                    .arg(Arg::new("name").required(true))
                    .arg(Arg::new("income").long("income").action(ArgAction::SetTrue).help("An income group")),
            )
            .subcommand(Command::new("rename").arg(Arg::new("name").required(true)).arg(Arg::new("new").required(true)))
            .subcommand(
                Command::new("delete")
                    .arg(Arg::new("name").required(true))
                    .arg(Arg::new("move-to").long("move-to").value_name("CATEGORY").help("Where its categories' transactions go")),
            ),
        Command::new("budget")
            .about("A month's budget: what is assigned, spent and left per category")
            .arg(month_arg())
            .subcommand(
                Command::new("set")
                    .about("Assign an amount to a category for the month")
                    .arg(category_arg("Category, e.g. Groceries or Everyday/Groceries"))
                    .arg(Arg::new("amount").required(true).help("Dollars, e.g. 450 or 450.00"))
                    .arg(month_arg()),
            )
            .subcommand(
                Command::new("carryover")
                    .about("Roll a category's overspending into next month (on) or not (off)")
                    .arg(category_arg("Category"))
                    .arg(Arg::new("flag").required(true).value_parser(["on", "off"]))
                    .arg(month_arg()),
            )
            .subcommand(
                Command::new("copy")
                    .about("Copy every category's assigned amount from one month to another")
                    .arg(Arg::new("from").long("from").required(true).value_name("YYYY-MM"))
                    .arg(month_arg().help("The month to copy onto (this month by default)")),
            )
            .subcommand(
                Command::new("hold")
                    .about("Hold an amount of this month's To Budget for next month")
                    .arg(Arg::new("amount").required(true))
                    .arg(month_arg()),
            ),
        period_args(
            Command::new("transactions")
                .about("List transactions (this month by default)")
                .arg(Arg::new("account").short('a').long("account").help("Only this account"))
                .arg(Arg::new("payee").short('p').long("payee").help("Only payees containing this"))
                .arg(Arg::new("category").short('c').long("category").help("Only this category"))
                .arg(Arg::new("uncategorized").short('u').long("uncategorized").action(ArgAction::SetTrue).help("Only what still needs a category"))
                .arg(Arg::new("limit").short('n').long("limit").value_name("N").value_parser(clap::value_parser!(u64)).help("At most the last N")),
        ),
        Command::new("categorize")
            .about("Put transactions in a category")
            .long_about(
                "Put transactions in a category, by id (the first characters shown by `transactions` are enough) \
                 and/or every uncategorized transaction of a payee with --payee. `none` clears the category.",
            )
            .arg(category_arg("Category, or none"))
            .arg(Arg::new("ids").num_args(0..).help("Transaction ids"))
            .arg(Arg::new("payee").short('p').long("payee").help("Every uncategorized transaction of this payee")),
        Command::new("transaction")
            .about("Change, add or delete transactions")
            .subcommand_required(true)
            .arg_required_else_help(true)
            .subcommand(
                Command::new("set")
                    .about("Change a transaction's category, payee, notes or cleared state")
                    .arg(Arg::new("ids").required(true).num_args(1..).help("Transaction ids (prefixes are fine)"))
                    .arg(Arg::new("category").short('c').long("category"))
                    .arg(Arg::new("payee").short('p').long("payee"))
                    .arg(Arg::new("notes").long("notes"))
                    .arg(Arg::new("cleared").long("cleared").action(ArgAction::SetTrue))
                    .arg(Arg::new("uncleared").long("uncleared").action(ArgAction::SetTrue)),
            )
            .subcommand(
                Command::new("add")
                    .about("Add a transaction by hand")
                    .arg(Arg::new("account").required(true))
                    .arg(Arg::new("amount").required(true).help("Dollars; negative for spending, e.g. -12.34"))
                    .arg(Arg::new("payee").required(true))
                    .arg(Arg::new("date").long("date").value_name("YYYY-MM-DD").help("Today by default"))
                    .arg(Arg::new("category").short('c').long("category"))
                    .arg(Arg::new("notes").long("notes")),
            )
            .subcommand(Command::new("delete").arg(Arg::new("ids").required(true).num_args(1..))),
        period_args(
            Command::new("spending")
                .about("Totals by category (default), group, payee or account")
                .arg(Arg::new("by").long("by").value_parser(["category", "group", "payee", "account"]).default_value("category")),
        ),
        Command::new("payees").about("The payees and how many transactions each has"),
        Command::new("payee")
            .about("Rename or merge payees")
            .subcommand_required(true)
            .arg_required_else_help(true)
            .subcommand(Command::new("rename").arg(Arg::new("name").required(true)).arg(Arg::new("new").required(true)))
            .subcommand(
                Command::new("merge")
                    .about("Fold payees into one; their transactions move over")
                    .arg(Arg::new("into").required(true))
                    .arg(Arg::new("from").required(true).num_args(1..)),
            ),
        Command::new("rules").about("The rules Actual applies to incoming transactions"),
        Command::new("rule")
            .about("Add or delete a rule")
            .subcommand_required(true)
            .arg_required_else_help(true)
            .subcommand(
                Command::new("add")
                    .about("Categorize automatically: by payee, or by text in the bank's description")
                    .arg(category_arg("Category to set"))
                    .arg(Arg::new("payee").short('p').long("payee").help("When the payee is exactly this"))
                    .arg(Arg::new("contains").long("contains").value_name("TEXT").help("When the bank's description contains this")),
            )
            .subcommand(Command::new("delete").arg(Arg::new("id").required(true))),
    ]
}

/// Runs one of the commands above; None if `name` is not one of them.
pub fn run(ctx: &Ctx, name: &str, m: &ArgMatches) -> Option<Result<()>> {
    Some(match name {
        "balances" => balances(ctx),
        "categories" => categories(ctx),
        "category" => category(ctx, m),
        "group" => group(ctx, m),
        "budget" => budget(ctx, m),
        "transactions" => transactions(ctx, m),
        "categorize" => categorize(ctx, m),
        "transaction" => transaction(ctx, m),
        "spending" => spending(ctx, m),
        "payees" => payees(ctx),
        "payee" => payee(ctx, m),
        "rules" => rules(ctx),
        "rule" => rule(ctx, m),
        _ => return None,
    })
}

fn balances(ctx: &Ctx) -> Result<()> {
    let mut t = Table::new(vec!["ACCOUNT", "BALANCE", ""], vec![false, true, false]);
    let mut total = 0;
    for a in arr(&op(ctx, "balances", json!({}))?) {
        let flags: Vec<&str> = [(a["offbudget"] == true, "off budget"), (a["closed"] == true, "closed")].iter().filter(|(f, _)| *f).map(|(_, l)| *l).collect();
        if a["offbudget"] != true && a["closed"] != true {
            total += n(&a["balance"]);
        }
        t.row(vec![s(&a["name"]), money(n(&a["balance"])), flags.join(", ")]);
    }
    t.row(vec!["on budget".to_string(), money(total), String::new()]);
    t.print();
    Ok(())
}

fn categories(ctx: &Ctx) -> Result<()> {
    let mut t = Table::new(vec!["GROUP", "CATEGORY", ""], vec![false, false, false]);
    for g in arr(&op(ctx, "categories", json!({}))?) {
        let tag = if g["is_income"] == true { "income" } else { "" };
        let cats = arr(&g["categories"]);
        if cats.is_empty() {
            t.row(vec![s(&g["name"]), "(empty)".to_string(), tag.to_string()]);
        }
        for c in cats {
            t.row(vec![s(&g["name"]), s(&c["name"]), if c["hidden"] == true { "hidden".to_string() } else { tag.to_string() }]);
        }
    }
    t.print();
    Ok(())
}

fn category(ctx: &Ctx, m: &ArgMatches) -> Result<()> {
    let (sub, m) = m.subcommand().expect("subcommand_required");
    let name = get(m, "name");
    let r = match sub {
        "add" => {
            let r = op(ctx, "category.add", json!({ "group": need(m, "group"), "name": need(m, "name") }))?;
            if r["groupCreated"] == true {
                println!("created the group '{}'", s(&r["group"]));
            }
            r
        }
        "rename" => op(ctx, "category.rename", json!({ "name": name, "newName": need(m, "new") }))?,
        "move" => op(ctx, "category.move", json!({ "name": name, "group": need(m, "group") }))?,
        "hide" => op(ctx, "category.hide", json!({ "name": name, "hidden": true }))?,
        "unhide" => op(ctx, "category.hide", json!({ "name": name, "hidden": false }))?,
        "delete" => op(ctx, "category.delete", json!({ "name": name, "moveTo": get(m, "move-to") }))?,
        _ => unreachable!(),
    };
    let _ = r;
    println!("done");
    Ok(())
}

fn group(ctx: &Ctx, m: &ArgMatches) -> Result<()> {
    let (sub, m) = m.subcommand().expect("subcommand_required");
    let name = need(m, "name");
    match sub {
        "add" => op(ctx, "group.add", json!({ "name": name, "income": m.get_flag("income") }))?,
        "rename" => op(ctx, "group.rename", json!({ "name": name, "newName": need(m, "new") }))?,
        "delete" => op(ctx, "group.delete", json!({ "name": name, "moveTo": get(m, "move-to") }))?,
        _ => unreachable!(),
    };
    println!("done");
    Ok(())
}

fn budget(ctx: &Ctx, m: &ArgMatches) -> Result<()> {
    match m.subcommand() {
        None => {
            let month = month_of(m)?;
            let b = op(ctx, "budget.month", json!({ "month": month }))?;
            println!(
                "{month}: to budget {}   income {}   budgeted {}   spent {}   left {}",
                money(n(&b["toBudget"])),
                money(n(&b["totalIncome"])),
                money(n(&b["totalBudgeted"])),
                money(n(&b["totalSpent"])),
                money(n(&b["totalBalance"]))
            );
            if n(&b["forNextMonth"]) != 0 {
                println!("held for next month: {}", money(n(&b["forNextMonth"])));
            }
            println!();
            let mut t = Table::new(vec!["GROUP", "CATEGORY", "BUDGETED", "SPENT", "BALANCE", ""], vec![false, false, true, true, true, false]);
            for g in arr(&b["groups"]) {
                if g["hidden"] == true {
                    continue;
                }
                for c in arr(&g["categories"]) {
                    if c["hidden"] == true {
                        continue;
                    }
                    let note = if c["carryover"] == true { "carryover" } else { "" };
                    if g["is_income"] == true {
                        t.row(vec![s(&g["name"]), s(&c["name"]), String::new(), money(n(&c["spent"])), String::new(), "income".to_string()]);
                    } else {
                        t.row(vec![s(&g["name"]), s(&c["name"]), money(n(&c["budgeted"])), money(n(&c["spent"])), money(n(&c["balance"])), note.to_string()]);
                    }
                }
            }
            t.print();
            Ok(())
        }
        Some(("set", m)) => {
            let r = op(ctx, "budget.set", json!({ "month": month_of(m)?, "category": need(m, "category"), "amount": cents(&need(m, "amount"))? }))?;
            println!("{}: {} budgeted for {}", month_of(m)?, money(cents(&need(m, "amount"))?), s(&r["category"]));
            Ok(())
        }
        Some(("carryover", m)) => {
            op(ctx, "budget.carryover", json!({ "month": month_of(m)?, "category": need(m, "category"), "flag": need(m, "flag") == "on" }))?;
            println!("done");
            Ok(())
        }
        Some(("copy", m)) => {
            let r = op(ctx, "budget.copy", json!({ "from": need(m, "from"), "to": month_of(m)? }))?;
            println!("copied {} categories' amounts from {} onto {}", n(&r["copied"]), need(m, "from"), month_of(m)?);
            Ok(())
        }
        Some(("hold", m)) => {
            let r = op(ctx, "budget.hold", json!({ "month": month_of(m)?, "amount": cents(&need(m, "amount"))? }))?;
            println!("{}", if r["held"] == true { "held" } else { "could not hold that much (more than To Budget?)" });
            Ok(())
        }
        _ => unreachable!(),
    }
}

fn transactions(ctx: &Ctx, m: &ArgMatches) -> Result<()> {
    let (since, until) = period_of(m)?;
    let rows = arr(&op(
        ctx,
        "transactions",
        json!({
            "since": since, "until": until,
            "account": get(m, "account"), "payee": get(m, "payee"), "category": get(m, "category"),
            "uncategorized": m.get_flag("uncategorized"), "limit": m.get_one::<u64>("limit"),
        }),
    )?);
    let mut t = Table::new(vec!["ID", "DATE", "ACCOUNT", "PAYEE", "CATEGORY", "AMOUNT", "NOTES"], vec![false, false, false, false, false, true, false]);
    let mut total = 0;
    for r in &rows {
        total += n(&r["amount"]);
        let payee = if r["payee"].is_null() { s(&r["imported_payee"]) } else { s(&r["payee"]) };
        let category = if r["transfer"] == true {
            "(transfer)".to_string()
        } else if r["split"] == "parent" {
            "(split)".to_string()
        } else if r["category"].is_null() {
            "-".to_string()
        } else {
            s(&r["category"])
        };
        let mut notes = s(&r["notes"]);
        if r["cleared"] != true {
            notes = format!("{notes} (pending)").trim().to_string();
        }
        t.row(vec![s(&r["id"]).chars().take(8).collect(), s(&r["date"]), s(&r["account"]), payee, category, money(n(&r["amount"])), notes]);
    }
    t.print();
    println!("\n{} transactions, net {}", rows.len(), money(total));
    Ok(())
}

fn categorize(ctx: &Ctx, m: &ArgMatches) -> Result<()> {
    let ids = strings(m, "ids");
    let payee = get(m, "payee");
    if ids.is_empty() && payee.is_none() {
        bail!("give transaction ids, or --payee NAME");
    }
    let r = op(ctx, "transaction.update", json!({ "ids": ids, "ofPayee": payee, "category": need(m, "category") }))?;
    println!("categorized {} transaction(s)", n(&r["updated"]));
    Ok(())
}

fn transaction(ctx: &Ctx, m: &ArgMatches) -> Result<()> {
    let (sub, m) = m.subcommand().expect("subcommand_required");
    match sub {
        "set" => {
            let cleared = if m.get_flag("cleared") { Some(true) } else if m.get_flag("uncleared") { Some(false) } else { None };
            let r = op(
                ctx,
                "transaction.update",
                json!({ "ids": strings(m, "ids"), "category": get(m, "category"), "payee": get(m, "payee"), "notes": get(m, "notes"), "cleared": cleared }),
            )?;
            println!("updated {} transaction(s)", n(&r["updated"]));
        }
        "add" => {
            let date = get(m, "date").unwrap_or_else(|| {
                let days = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0) / 86_400;
                // Only the month is derivable cheaply above; the day needs the same arithmetic.
                let _ = days;
                today()
            });
            op(
                ctx,
                "transaction.add",
                json!({
                    "account": need(m, "account"), "amount": cents(&need(m, "amount"))?, "payee": need(m, "payee"),
                    "date": date, "category": get(m, "category"), "notes": get(m, "notes"),
                }),
            )?;
            println!("added");
        }
        "delete" => {
            let r = op(ctx, "transaction.delete", json!({ "ids": strings(m, "ids") }))?;
            println!("deleted {} transaction(s)", n(&r["deleted"]));
        }
        _ => unreachable!(),
    }
    Ok(())
}

/// Today as YYYY-MM-DD (same civil-from-days arithmetic as current_month).
fn today() -> String {
    let days = (SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0) / 86_400) as i64;
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}")
}

fn spending(ctx: &Ctx, m: &ArgMatches) -> Result<()> {
    let (since, until) = period_of(m)?;
    let by = need(m, "by");
    let rows = arr(&op(ctx, "spending", json!({ "since": since, "until": until, "by": by }))?);
    let head = match by.as_str() {
        "payee" => "PAYEE",
        "account" => "ACCOUNT",
        "group" => "GROUP",
        _ => "CATEGORY",
    };
    let mut t = Table::new(vec![head, "SPENT", "INCOME", "COUNT"], vec![false, true, true, true]);
    let (mut spent, mut income) = (0, 0);
    for r in &rows {
        spent += n(&r["spent"]);
        income += n(&r["income"]);
        t.row(vec![s(&r["name"]), money(n(&r["spent"])), money(n(&r["income"])), n(&r["count"]).to_string()]);
    }
    t.row(vec!["total".to_string(), money(spent), money(income), String::new()]);
    println!("{since} to {until}\n");
    t.print();
    Ok(())
}

fn payees(ctx: &Ctx) -> Result<()> {
    let mut t = Table::new(vec!["PAYEE", "TRANSACTIONS", ""], vec![false, true, false]);
    let mut rows = arr(&op(ctx, "payees", json!({}))?);
    rows.sort_by(|a, b| n(&b["transactions"]).cmp(&n(&a["transactions"])).then(s(&a["name"]).cmp(&s(&b["name"]))));
    for p in rows {
        t.row(vec![s(&p["name"]), n(&p["transactions"]).to_string(), if p["transfer"] == true { "transfer".to_string() } else { String::new() }]);
    }
    t.print();
    Ok(())
}

fn payee(ctx: &Ctx, m: &ArgMatches) -> Result<()> {
    let (sub, m) = m.subcommand().expect("subcommand_required");
    match sub {
        "rename" => {
            op(ctx, "payee.rename", json!({ "name": need(m, "name"), "newName": need(m, "new") }))?;
            println!("renamed");
        }
        "merge" => {
            let r = op(ctx, "payee.merge", json!({ "into": need(m, "into"), "from": strings(m, "from") }))?;
            println!("merged {} payee(s) into {}", n(&r["merged"]), s(&r["into"]));
        }
        _ => unreachable!(),
    }
    Ok(())
}

fn rules(ctx: &Ctx) -> Result<()> {
    let mut t = Table::new(vec!["ID", "WHEN", "THEN"], vec![false, false, false]);
    for r in arr(&op(ctx, "rules", json!({}))?) {
        let when: Vec<String> = arr(&r["conditions"]).iter().map(|c| format!("{} {} {}", s(&c["field"]), s(&c["op"]), s(&c["value"]))).collect();
        let then: Vec<String> = arr(&r["actions"])
            .iter()
            .map(|a| if a["field"].is_null() { format!("{} {}", s(&a["op"]), s(&a["value"])) } else { format!("{} {} = {}", s(&a["op"]), s(&a["field"]), s(&a["value"])) })
            .collect();
        t.row(vec![s(&r["id"]).chars().take(8).collect(), when.join(&format!(" {} ", s(&r["conditionsOp"]))), then.join("; ")]);
    }
    t.print();
    Ok(())
}

fn rule(ctx: &Ctx, m: &ArgMatches) -> Result<()> {
    let (sub, m) = m.subcommand().expect("subcommand_required");
    match sub {
        "add" => {
            if get(m, "payee").is_none() && get(m, "contains").is_none() {
                bail!("give --payee NAME or --contains TEXT");
            }
            let r = op(ctx, "rule.add", json!({ "category": need(m, "category"), "payee": get(m, "payee"), "contains": get(m, "contains") }))?;
            println!("rule added: -> {}", s(&r["category"]));
        }
        "delete" => {
            let all = arr(&op(ctx, "rules", json!({}))?);
            let id = need(m, "id");
            let hits: Vec<&Value> = all.iter().filter(|r| s(&r["id"]).starts_with(&id)).collect();
            let [hit] = hits[..] else {
                bail!("{} rule(s) match '{id}'; `rules` lists them", hits.len());
            };
            op(ctx, "rule.delete", json!({ "id": s(&hit["id"]) }))?;
            println!("deleted");
        }
        _ => unreachable!(),
    }
    Ok(())
}
