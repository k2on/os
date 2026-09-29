//! money-sync: the server side of the Plaid -> Actual import.
//!
//!   money-sync [sync]                              import what changed since the last run
//!   money-sync seed <account.sqlite> <token-file>  give the importer a way into Actual,
//!                                                  and every user access to the budget
//!   money-sync budgets [--json]                    the budget files on the server
//!   money-sync delete-budget <file-id>             remove one (a stray, say)
//!   money-sync actual <op> [json]                  anything else: categories, budgets,
//!                                                  transactions... (actual-import/src/ops.ts)
//!
//! Config is JSON at $MONEY_SYNC_CONFIG, rendered by ../default.nix; secrets
//! only as file paths. Plaid is talked to directly (cli/plaid.rs, shared with
//! the `ark` CLI). The Actual half goes through actual-import/, a small Node
//! program on Actual's official client library: there is no HTTP API for
//! transactions, only the client's CRDT sync protocol, reconciler and rules
//! engine, and those exist in that library alone. money-sync hands it one
//! JSON change set per run and reads a JSON report back.
use std::path::Path;

#[path = "../../cli/plaid.rs"]
mod plaid;

mod actual;
mod budgets;
mod config;
mod seed;
mod sync;

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

#[macro_export]
macro_rules! bail {
    ($($arg:tt)*) => {
        return Err(format!($($arg)*).into())
    };
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.iter().map(String::as_str).collect::<Vec<_>>()[..] {
        [] | ["sync"] => sync::run(),
        ["seed", db, token_file] => seed::run(Path::new(db), Path::new(token_file)),
        ["budgets"] => budgets::list(false),
        ["budgets", "--json"] => budgets::list(true),
        ["delete-budget", file_id] => budgets::delete(file_id),
        ["actual", op] => actual::run(op, "{}"),
        ["actual", op, args] => actual::run(op, args),
        _ => Err("usage: money-sync [sync] | seed <account.sqlite> <token-file> | budgets [--json] | delete-budget <file-id> | actual <op> [json]".into()),
    };
    if let Err(e) = result {
        eprintln!("money-sync: {e}");
        std::process::exit(1);
    }
}
