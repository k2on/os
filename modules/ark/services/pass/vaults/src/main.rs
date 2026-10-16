//! pass-vaults: shared vaults (Bitwarden organizations) in Vaultwarden,
//! from configuration.
//!
//!   pass-vaults <config.json>
//!
//! Joining someone to an organization takes the organization's key,
//! encrypted to that person's public key, and only a client holding the key
//! can do it: the server never sees it. Vaultwarden can sign people in
//! through OpenID but has no way to put them in an organization, so this is
//! that client. It holds each organization's key (a secret per vault) and
//! writes Vaultwarden's database directly, one transaction per run. For
//! every configured vault:
//!
//!   - the organization and its collections, created the first time under
//!     fixed ids, with an RSA key pair of its own like the web vault makes;
//!   - every configured member who has an account with keys (signed in
//!     once and chose a master password), confirmed, with the key and every
//!     configured collection; owners as owners, everyone else as users;
//!   - nobody else: a membership of anyone not configured is removed.
//!
//! People without keys yet are skipped and picked up on a later run: the
//! patched Vaultwarden says when an account gets its keys, and ../default.nix
//! runs this then. Everyone touched gets a new revision date, which is what
//! makes their clients sync. Collections made by hand in a vault are left
//! alone. Config is JSON rendered by ../default.nix (config.rs).
use std::path::Path;

mod config;
mod crypto;
mod vault;

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
        [path] => config::Config::load(Path::new(path)).and_then(|c| vault::reconcile(&c)),
        _ => Err("usage: pass-vaults <config.json>".into()),
    };
    if let Err(e) = result {
        eprintln!("pass-vaults: {e}");
        std::process::exit(1);
    }
}
