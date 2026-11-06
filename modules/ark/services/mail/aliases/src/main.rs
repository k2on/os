//! mail-aliases: aliases made from Bitwarden, and the accounts Stalwart reads.
//!
//!   mail-aliases render <config.json>   Stalwart's accounts, aliases included
//!   mail-aliases serve <config.json>    answer Bitwarden and the tailnet
//!
//! Bitwarden's "forwarded email alias" generator speaks addy.io's API
//! (http.rs); an alias is named after the site (names.rs) and kept in a
//! small database (db.rs). It goes to whoever made it; pass-vaults on adam
//! moves it to a group's mailbox when the login holding it is saved in that
//! group's vault, and back when it leaves.
//!
//! Stalwart's accounts are its in-memory directory, which it reads when it
//! starts: ../../default.nix appends `render`'s output to its config then,
//! and restarts it when an alias changes (`changed_file`). People and groups
//! come from Nix (ark.persons, ark.groups) through the config (config.rs).
use std::collections::BTreeSet;
use std::path::Path;
use std::sync::{Arc, Mutex};

mod config;
mod db;
mod http;
mod names;
mod render;

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

fn open(config: &config::Config) -> Result<db::Db> {
    let mut db = db::Db::open(&config.db)?;
    db.sync(config)?;
    Ok(db)
}

fn serve(config: config::Config) -> Result<()> {
    let db = open(&config)?;
    let mut tokens = Vec::new();
    for person in &config.persons {
        tokens.push((config::secret(&person.token_file)?, person.name.clone()));
    }
    let taken: BTreeSet<String> = config
        .persons
        .iter()
        .map(|p| p.address.to_lowercase())
        .chain(config.groups.iter().map(|g| g.address.to_lowercase()))
        .collect();
    let state = Arc::new(http::State {
        db: Mutex::new(db),
        domain: config.domain.to_lowercase(),
        taken,
        groups: config.groups.iter().map(|g| g.name.clone()).collect(),
        changed_file: config.changed_file.clone(),
        tokens,
        internal_key: config::secret(&config.internal_key_file)?,
    });
    eprintln!("mail-aliases: {} people, {} groups", config.persons.len(), config.groups.len());
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build()?;
    runtime.block_on(async {
        tokio::try_join!(
            http::serve(state.clone(), &config.listen, false),
            http::serve(state.clone(), &config.internal_listen, true),
        )
    })?;
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.iter().map(String::as_str).collect::<Vec<_>>()[..] {
        ["render", path] => config::Config::load(Path::new(path)).and_then(|config| {
            let aliases = open(&config)?.list()?;
            print!("{}", render::render(&config, &aliases));
            Ok(())
        }),
        ["serve", path] => config::Config::load(Path::new(path)).and_then(serve),
        _ => Err("usage: mail-aliases render|serve <config.json>".into()),
    };
    if let Err(e) = result {
        eprintln!("mail-aliases: {e}");
        std::process::exit(1);
    }
}
