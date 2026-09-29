//! `money-sync seed <account.sqlite> <token-file>`: give money-sync a way into Actual.
//!
//! Actual's API can only log in with a server password, and our server is
//! OpenID-only. The API does accept a ready-made session token, though, so
//! this creates a 'money-sync' user and a never-expiring session for it
//! straight in Actual's account database. The user is a server ADMIN: that is
//! what lets it reach a budget it does not own (Actual checks owner, admin,
//! or an explicit grant).
//!
//! While there, it makes sure whoever kanidm lets into the money service
//! (the config's `members`) already has an Actual user and access to every
//! budget on the server, so their first login lands in the family budget
//! instead of Actual's "start budgeting" screen, which would create a second
//! one. The money-access timer runs this every couple of minutes, so a budget
//! created later, or a user who logged in before being listed, is covered too.
//!
//! Idempotent, and points the session at whatever the token file holds now,
//! so rotating the secret just works. Runs as root: the database is 0700 actual.
use std::fs;
use std::io::Read;
use std::path::Path;

use rusqlite::{Connection, OptionalExtension};

use crate::config::Config;
use crate::{bail, Result};

const USER: &str = "money-sync";

pub fn run(db: &Path, token_file: &Path) -> Result<()> {
    // Right after actual's first start its migrations are still creating the database.
    for attempt in 0..60 {
        if db.exists() {
            break;
        }
        if attempt == 0 {
            println!("waiting for {} (actual starting up?)...", db.display());
        }
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
    if !db.exists() {
        bail!("{} did not appear within a minute; is actual running?", db.display());
    }
    let token = fs::read_to_string(token_file)?.trim().to_string();
    if token.is_empty() {
        bail!("{} is empty", token_file.display());
    }

    let conn = Connection::open(db)?;
    let tx = conn.unchecked_transaction()?;
    let existing: Option<String> = tx
        .query_row("SELECT id FROM users WHERE user_name = ?1", [USER], |row| row.get(0))
        .optional()?;
    let user_id = match existing {
        Some(id) => {
            tx.execute("UPDATE users SET enabled = 1, role = 'ADMIN' WHERE id = ?1", [&id])?;
            id
        }
        None => {
            let id = uuid_v4()?;
            tx.execute(
                "INSERT INTO users (id, user_name, display_name, role, enabled, owner) \
                 VALUES (?1, ?2, 'Money sync', 'ADMIN', 1, 0)",
                [&id, USER],
            )?;
            id
        }
    };
    tx.execute("DELETE FROM sessions WHERE user_id = ?1 AND token <> ?2", [&user_id, &token])?;

    // The family, ahead of their first login. Only once the server has been
    // bootstrapped (it has an owner): before that Actual's own first-login
    // logic is what sets the server up, and pre-created users would derail it.
    // Members of the service's admin group become Actual admins; the first
    // of them also the owner, if no one with a name is yet.
    let bootstrapped: i64 = tx.query_row("SELECT count(*) FROM users WHERE owner = 1", [], |r| r.get(0))?;
    if bootstrapped > 0 {
        let cfg = Config::load()?;
        let mut named_owner: i64 =
            tx.query_row("SELECT count(*) FROM users WHERE owner = 1 AND user_name <> ''", [], |r| r.get(0))?;
        let mut created = Vec::new();
        for member in &cfg.members {
            let exists: i64 =
                tx.query_row("SELECT count(*) FROM users WHERE user_name = ?1", [&member.name], |r| r.get(0))?;
            if exists > 0 {
                continue;
            }
            let owner = member.admin && named_owner == 0;
            tx.execute(
                "INSERT INTO users (id, user_name, display_name, role, enabled, owner) VALUES (?1, ?2, ?2, ?3, 1, ?4)",
                rusqlite::params![uuid_v4()?, member.name, if member.admin { "ADMIN" } else { "BASIC" }, owner as i64],
            )?;
            if owner {
                named_owner += 1;
            }
            created.push(member.name.as_str());
        }
        if !created.is_empty() {
            println!("created Actual user(s) ahead of their first login: {}", created.join(", "));
        }
    }
    tx.execute(
        "INSERT INTO sessions (token, expires_at, user_id, auth_method) VALUES (?1, -1, ?2, 'openid') \
         ON CONFLICT(token) DO UPDATE SET expires_at = -1, user_id = excluded.user_id",
        [&token, &user_id],
    )?;
    // Everyone (people, not the machine user) gets every live budget they do not own.
    let granted = tx.execute(
        "INSERT OR IGNORE INTO user_access (user_id, file_id) \
         SELECT users.id, files.id FROM users, files \
         WHERE users.user_name <> '' AND users.user_name <> ?1 AND users.enabled = 1 \
           AND files.deleted = 0 AND files.owner IS NOT users.id",
        [USER],
    )?;
    tx.commit()?;
    if granted > 0 {
        println!("gave {granted} user/budget pair(s) access");
    }
    Ok(())
}

/// A random UUID (Actual's user ids are uuid v4 strings), from /dev/urandom.
fn uuid_v4() -> Result<String> {
    let mut b = [0u8; 16];
    fs::File::open("/dev/urandom")?.read_exact(&mut b)?;
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let hex: String = b.iter().map(|x| format!("{x:02x}")).collect();
    Ok(format!("{}-{}-{}-{}-{}", &hex[0..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..32]))
}
