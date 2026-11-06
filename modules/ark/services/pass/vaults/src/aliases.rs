//! `pass-vaults aliases <config.json>`: tells mail-aliases (on the mail
//! host) which aliases are in which group's vault, so mail to an alias goes
//! to the group whose vault holds its login (../../mail/aliases).
//!
//! For every vault: the logins in it (not in the trash), and of each only
//! its username, decrypted with the vault's key, or with the item's own key
//! when it has one (which the vault's key opens). Usernames at the alias
//! domain are what is sent; nothing else leaves, and nothing is kept. The
//! personal vaults are not read, and cannot be: only their owners' devices
//! hold their keys. mail-aliases sends an alias that left every group's
//! vault back to whoever made it.
use std::collections::BTreeMap;

use rusqlite::{Connection, OpenFlags};
use serde_json::{json, Value};

use crate::config::Config;
use crate::crypto::SymKey;
use crate::{bail, Result};

pub fn report(config: &Config) -> Result<()> {
    let Some(aliases) = &config.aliases else {
        bail!("no `aliases` in the config: nothing to report to");
    };
    let conn = Connection::open_with_flags(&config.db, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| format!("opening {}: {e}", config.db.display()))?;
    conn.busy_timeout(std::time::Duration::from_secs(30))?;
    let ready: bool =
        conn.query_row("SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE name = 'ciphers')", [], |r| r.get(0))?;
    if !ready {
        println!("Vaultwarden has not set up its database yet; next time");
        return Ok(());
    }

    let suffix = format!("@{}", aliases.domain.to_lowercase());
    let mut groups: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for vault in &config.vaults {
        let key_text = std::fs::read_to_string(&vault.key_file)
            .map_err(|e| format!("reading {}: {e}", vault.key_file.display()))?;
        let key = SymKey::from_base64(&key_text).map_err(|e| format!("{}: {e}", vault.key_file.display()))?;
        let found = in_vault(&conn, &vault.id, &key, &suffix).map_err(|e| format!("{}: {e}", vault.name))?;
        groups.insert(vault.group.clone(), found);
    }

    let key = std::fs::read_to_string(&aliases.key_file)
        .map_err(|e| format!("reading {}: {e}", aliases.key_file.display()))?;
    let reply: Value = ureq::put(&format!("{}/targets", aliases.endpoint.trim_end_matches('/')))
        .set("Authorization", &format!("Bearer {}", key.trim()))
        .send_json(json!({ "groups": groups }))
        .map_err(|e| format!("telling mail-aliases at {}: {e}", aliases.endpoint))?
        .into_json()?;
    let moved = reply["moved"].as_array().cloned().unwrap_or_default();
    for m in &moved {
        println!("{} now goes to {} (was {})", m["address"].as_str().unwrap_or("?"), m["to"].as_str().unwrap_or("?"), m["from"].as_str().unwrap_or("?"));
    }
    if moved.is_empty() {
        println!("aliases: nothing moved");
    }
    Ok(())
}

/// The usernames at the alias domain of the logins in one vault.
fn in_vault(conn: &Connection, org: &str, key: &SymKey, suffix: &str) -> Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT uuid, key, data FROM ciphers
         WHERE organization_uuid = ?1 AND atype = 1 AND deleted_at IS NULL",
    )?;
    let rows = stmt
        .query_map([org], |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, String>(2)?)))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut found = Vec::new();
    for (id, item_key, data) in rows {
        match username(key, item_key.as_deref(), &data) {
            Ok(Some(name)) if name.ends_with(suffix) => found.push(name),
            Ok(_) => {}
            // One unreadable item should not keep the rest from moving.
            Err(e) => eprintln!("pass-vaults: item {id}: {e}"),
        }
    }
    found.sort();
    found.dedup();
    Ok(found)
}

fn username(vault_key: &SymKey, item_key: Option<&str>, data: &str) -> Result<Option<String>> {
    let own;
    let key = match item_key {
        Some(enc) => {
            own = SymKey::from_bytes(&vault_key.decrypt(enc)?)?;
            &own
        }
        None => vault_key,
    };
    let data: Value = serde_json::from_str(data)?;
    let Some(enc) = data.get("username").or_else(|| data.get("Username")).and_then(Value::as_str) else {
        return Ok(None);
    };
    let plain = String::from_utf8(key.decrypt(enc)?).map_err(|_| "the username is not text")?;
    Ok(Some(plain.trim().to_lowercase()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(byte: u8) -> SymKey {
        SymKey::from_bytes(&[byte; 64]).unwrap()
    }

    #[test]
    fn usernames_open_with_the_vault_key_or_the_item_key() {
        let vault = key(1);
        let data = json!({ "username": vault.encrypt(b"Shop-Ab12c@Mail.Example") }).to_string();
        assert_eq!(username(&vault, None, &data).unwrap().as_deref(), Some("shop-ab12c@mail.example"));

        let item = key(2);
        let wrapped = vault.encrypt(item.bytes());
        let data = json!({ "username": item.encrypt(b"trip-9z9z9@mail.example") }).to_string();
        assert_eq!(username(&vault, Some(&wrapped), &data).unwrap().as_deref(), Some("trip-9z9z9@mail.example"));

        assert_eq!(username(&vault, None, "{}").unwrap(), None);
        assert!(username(&key(3), None, &json!({ "username": vault.encrypt(b"x") }).to_string()).is_err());
    }
}
