//! Each vault's organization, collections and memberships, straight in
//! Vaultwarden's database (its schema: src/db/schema.rs upstream). One
//! immediate transaction per vault, so a half-done run never shows and one
//! vault's trouble (a key that does not fit, say) leaves the others be.
//! Vaultwarden keeps none of this in memory and reads the result on its
//! next request.
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};

use crate::config::{Config, Vault};
use crate::crypto::{self, SymKey};
use crate::{bail, Result};

// users_organizations.status and .atype (src/db/models/organization.rs upstream).
const CONFIRMED: i64 = 2;
const OWNER: i64 = 0;
const USER: i64 = 2;

// How Vaultwarden writes its timestamps; bumping users.updated_at is what
// makes a client sync (GET /api/accounts/revision-date).
const NOW: &str = "strftime('%Y-%m-%d %H:%M:%f', 'now')";

pub fn reconcile(config: &Config) -> Result<()> {
    let mut db = Connection::open(&config.db).map_err(|e| format!("opening {}: {e}", config.db.display()))?;
    db.busy_timeout(std::time::Duration::from_secs(30))?;
    if !migrated(&db)? {
        println!("Vaultwarden has not set up {} yet; next time", config.db.display());
        return Ok(());
    }

    let mut failed = Vec::new();
    for vault in &config.vaults {
        if let Err(e) = reconcile_vault(&mut db, vault) {
            eprintln!("{}: {e}", vault.name);
            failed.push(vault.name.as_str());
        }
    }
    if !failed.is_empty() {
        bail!("not in step: {}", failed.join(", "));
    }
    Ok(())
}

fn reconcile_vault(db: &mut Connection, vault: &Vault) -> Result<()> {
    let key_text = std::fs::read_to_string(&vault.key_file)
        .map_err(|e| format!("reading {}: {e}", vault.key_file.display()))?;
    let key = SymKey::from_base64(&key_text).map_err(|e| format!("{}: {e}", vault.key_file.display()))?;

    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    ensure_org(&tx, vault, &key)?;
    for collection in &vault.collections {
        ensure_collection(&tx, vault, &collection.id, &collection.name, &key)?;
    }

    let mut wanted = Vec::new();
    for member in &vault.members {
        let email = member.email.to_lowercase();
        wanted.push(email.clone());
        let user: Option<(String, Option<String>)> = tx
            .query_row(
                "SELECT uuid, public_key FROM users WHERE lower(email) = ?1",
                [&email],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        match user {
            None => println!("{}: {email} has no account yet (signs in through OpenID once)", vault.name),
            Some((_, None)) => {
                println!("{}: {email} has no keys yet (chooses a master password on first sign-in)", vault.name)
            }
            Some((user, Some(public_key))) => {
                if ensure_member(&tx, vault, &key, &user, &public_key, member.owner)
                    .map_err(|e| format!("{email}: {e}"))?
                {
                    println!("{}: {email} is in", vault.name);
                    touch(&tx, &user)?;
                }
            }
        }
    }
    remove_others(&tx, vault, &wanted)?;
    tx.commit()?;
    Ok(())
}

fn migrated(db: &Connection) -> Result<bool> {
    let n: i64 = db.query_row(
        "SELECT count(*) FROM sqlite_master WHERE type = 'table'
           AND name IN ('users', 'organizations', 'users_organizations', 'collections', 'users_collections', 'groups_users')",
        [],
        |r| r.get(0),
    )?;
    Ok(n == 6)
}

/// The organization under its fixed id, with a key pair the first time.
/// After that its private key is how we know the key on file is still the
/// one its members hold.
fn ensure_org(tx: &Connection, vault: &Vault, key: &SymKey) -> Result<()> {
    let private: Option<Option<String>> = tx
        .query_row("SELECT private_key FROM organizations WHERE uuid = ?1", [&vault.id], |r| r.get(0))
        .optional()?;
    match private {
        None => {
            let (public, private) = crypto::org_keypair(key)?;
            tx.execute(
                "INSERT INTO organizations (uuid, name, billing_email, private_key, public_key) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![vault.id, vault.name, vault.billing_email, private, public],
            )?;
            println!("{}: created", vault.name);
        }
        Some(private) => {
            if let Some(private) = private {
                if let Err(e) = key.decrypt(&private) {
                    bail!(
                        "its private key does not open with {} ({e}): the key on file is not the one it was made with",
                        vault.key_file.display()
                    );
                }
            }
            tx.execute(
                "UPDATE organizations SET name = ?2, billing_email = ?3 WHERE uuid = ?1 AND (name != ?2 OR billing_email != ?3)",
                params![vault.id, vault.name, vault.billing_email],
            )?;
        }
    }
    Ok(())
}

/// A collection, its name encrypted with the organization's key; rewritten
/// when it says something else (or nothing this key opens).
fn ensure_collection(tx: &Connection, vault: &Vault, id: &str, name: &str, key: &SymKey) -> Result<()> {
    let current: Option<String> = tx
        .query_row("SELECT name FROM collections WHERE uuid = ?1", [id], |r| r.get(0))
        .optional()?;
    if current.as_deref().and_then(|n| key.decrypt(n).ok()).as_deref() == Some(name.as_bytes()) {
        return Ok(());
    }
    tx.execute(
        "INSERT INTO collections (uuid, org_uuid, name) VALUES (?1, ?2, ?3)
         ON CONFLICT (uuid) DO UPDATE SET org_uuid = excluded.org_uuid, name = excluded.name",
        params![id, vault.id, key.encrypt(name.as_bytes())],
    )?;
    Ok(())
}

/// A confirmed membership with the key, the right role, and every
/// configured collection. Whether anything changed.
fn ensure_member(tx: &Connection, vault: &Vault, key: &SymKey, user: &str, public_key: &str, owner: bool) -> Result<bool> {
    let atype = if owner { OWNER } else { USER };
    let existing: Option<(String, i64, i64, String)> = tx
        .query_row(
            "SELECT uuid, status, atype, akey FROM users_organizations WHERE user_uuid = ?1 AND org_uuid = ?2",
            [user, &vault.id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .optional()?;
    let mut changed = match existing {
        None => {
            tx.execute(
                "INSERT INTO users_organizations (uuid, user_uuid, org_uuid, access_all, akey, status, atype)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![crypto::uuid(), user, vault.id, owner, crypto::share(public_key, key)?, CONFIRMED, atype],
            )?;
            true
        }
        // Someone already confirmed keeps the key they were given: we
        // cannot read it back, and their client re-encrypts it when they
        // rotate their own keys.
        Some((id, status, have, akey)) if status != CONFIRMED || akey.is_empty() || have != atype => {
            let akey = if status == CONFIRMED && !akey.is_empty() { akey } else { crypto::share(public_key, key)? };
            tx.execute(
                "UPDATE users_organizations SET status = ?2, atype = ?3, access_all = ?4, akey = ?5 WHERE uuid = ?1",
                params![id, CONFIRMED, atype, owner, akey],
            )?;
            true
        }
        Some(_) => false,
    };
    for collection in &vault.collections {
        changed |= tx.execute(
            "INSERT INTO users_collections (user_uuid, collection_uuid, read_only, hide_passwords, manage)
             VALUES (?1, ?2, false, false, ?3)
             ON CONFLICT (user_uuid, collection_uuid) DO UPDATE SET read_only = false, hide_passwords = false, manage = excluded.manage
               WHERE read_only OR hide_passwords OR manage != excluded.manage",
            params![user, collection.id, owner],
        )? > 0;
    }
    Ok(changed)
}

/// Memberships of anyone not configured, with their collection access and
/// group places in this organization.
fn remove_others(tx: &Connection, vault: &Vault, wanted: &[String]) -> Result<()> {
    let mut stmt = tx.prepare(
        "SELECT m.uuid, m.user_uuid, lower(u.email) FROM users_organizations m JOIN users u ON u.uuid = m.user_uuid
         WHERE m.org_uuid = ?1",
    )?;
    let members: Vec<(String, String, String)> = stmt
        .query_map([&vault.id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
        .collect::<std::result::Result<_, _>>()?;
    for (membership, user, email) in members {
        if wanted.contains(&email) {
            continue;
        }
        tx.execute(
            "DELETE FROM users_collections WHERE user_uuid = ?1
               AND collection_uuid IN (SELECT uuid FROM collections WHERE org_uuid = ?2)",
            [&user, &vault.id],
        )?;
        tx.execute("DELETE FROM groups_users WHERE users_organizations_uuid = ?1", [&membership])?;
        tx.execute("DELETE FROM users_organizations WHERE uuid = ?1", [&membership])?;
        touch(tx, &user)?;
        println!("{}: {email} removed", vault.name);
    }
    Ok(())
}

fn touch(tx: &Connection, user: &str) -> Result<()> {
    tx.execute(&format!("UPDATE users SET updated_at = {NOW} WHERE uuid = ?1"), [user])?;
    Ok(())
}
