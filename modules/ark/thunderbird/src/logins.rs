//! logins.json, Thunderbird's password store: one entry per server, the
//! user name and password each sealed (./nss.rs). Only the entries named
//! here are touched, and only when their password differs; the rest
//! (passwords saved by hand) and every field this doesn't know stay as
//! they were.
use serde_json::{json, Value};

/// Seals and opens a store's values.
pub trait Cipher {
    fn encrypt(&self, text: &str) -> Result<String, String>;
    fn decrypt(&self, sealed: &str) -> Option<String>;
}

/// One password, as Thunderbird looks it up: by `origin` (imap://host,
/// smtp://host, https://host) and `realm` (the same origin for mail, the
/// server's realm for HTTP), and the user name.
pub struct Login<'a> {
    pub origin: &'a str,
    /// None when it isn't known (the server didn't answer): then only an
    /// entry already there is brought up to date, whatever its realm.
    pub realm: Option<&'a str>,
    pub user: &'a str,
    pub password: &'a str,
}

/// A store with nothing in it.
pub fn empty() -> Value {
    json!({
        "nextId": 1,
        "logins": [],
        "potentiallyVulnerablePasswords": [],
        "dismissedBreachAlertsByLoginGUID": {},
        "version": 3,
    })
}

#[derive(Debug, PartialEq)]
pub enum Outcome {
    Current,
    Changed,
    Added,
    /// Not there, and the realm to file it under unknown.
    Skipped,
}

/// Brings `login` up to date in `store`. `now` is in milliseconds, `guid`
/// a new entry's id.
pub fn seed(
    store: &mut Value,
    cipher: &impl Cipher,
    login: &Login,
    now: i64,
    guid: impl FnOnce() -> String,
) -> Result<Outcome, String> {
    let entries = store
        .get_mut("logins")
        .and_then(Value::as_array_mut)
        .ok_or("logins.json has no logins")?;
    let text = |e: &Value, k: &str| e.get(k).and_then(Value::as_str).map(str::to_string);
    let found = entries.iter_mut().find(|e| {
        text(e, "hostname").as_deref() == Some(login.origin)
            && login
                .realm
                .is_none_or(|r| text(e, "httpRealm").as_deref() == Some(r))
            && text(e, "encryptedUsername").and_then(|u| cipher.decrypt(&u)).as_deref()
                == Some(login.user)
    });
    if let Some(entry) = found {
        let password = text(entry, "encryptedPassword").and_then(|p| cipher.decrypt(&p));
        if password.as_deref() == Some(login.password) {
            return Ok(Outcome::Current);
        }
        entry["encryptedPassword"] = json!(sealed(cipher, login.password)?);
        entry["timePasswordChanged"] = json!(now);
        return Ok(Outcome::Changed);
    }
    let Some(realm) = login.realm else {
        return Ok(Outcome::Skipped);
    };
    let id = store.get("nextId").and_then(Value::as_i64).unwrap_or(1);
    let entry = json!({
        "id": id,
        "hostname": login.origin,
        "httpRealm": realm,
        "formSubmitURL": null,
        "usernameField": "",
        "passwordField": "",
        "encryptedUsername": sealed(cipher, login.user)?,
        "encryptedPassword": sealed(cipher, login.password)?,
        "guid": guid(),
        "encType": 1,
        "timeCreated": now,
        "timeLastUsed": now,
        "timePasswordChanged": now,
        "timesUsed": 1,
        "syncCounter": 0,
        "everSynced": false,
        "encryptedUnknownFields": null,
    });
    store["logins"].as_array_mut().expect("checked above").push(entry);
    store["nextId"] = json!(id + 1);
    Ok(Outcome::Added)
}

/// `text` sealed, and only if it opens again: never write what can't be read.
fn sealed(cipher: &impl Cipher, text: &str) -> Result<String, String> {
    let s = cipher.encrypt(text)?;
    if cipher.decrypt(&s).as_deref() != Some(text) {
        return Err("a sealed password didn't open again".into());
    }
    Ok(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Reversal stands in for NSS.
    struct Mirror;
    impl Cipher for Mirror {
        fn encrypt(&self, text: &str) -> Result<String, String> {
            Ok(format!("~{}", text.chars().rev().collect::<String>()))
        }
        fn decrypt(&self, sealed: &str) -> Option<String> {
            Some(sealed.strip_prefix('~')?.chars().rev().collect())
        }
    }

    fn login<'a>(origin: &'a str, realm: Option<&'a str>, password: &'a str) -> Login<'a> {
        Login {
            origin,
            realm,
            user: "max",
            password,
        }
    }

    fn seed_at(store: &mut Value, l: &Login) -> Outcome {
        seed(store, &Mirror, l, 1000, || "{guid}".into()).unwrap()
    }

    #[test]
    fn adds_then_leaves_then_changes() {
        let mut store = empty();
        let imap = "imap://mail.example";
        assert_eq!(seed_at(&mut store, &login(imap, Some(imap), "a")), Outcome::Added);
        assert_eq!(store["logins"][0]["encryptedPassword"], "~a");
        assert_eq!(store["logins"][0]["httpRealm"], imap);
        assert_eq!(store["nextId"], 2);
        assert_eq!(seed_at(&mut store, &login(imap, Some(imap), "a")), Outcome::Current);
        assert_eq!(seed_at(&mut store, &login(imap, Some(imap), "b")), Outcome::Changed);
        assert_eq!(store["logins"][0]["encryptedPassword"], "~b");
        assert_eq!(store["logins"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn without_a_realm_only_updates() {
        let mut store = empty();
        let dav = "https://radicale.example";
        assert_eq!(seed_at(&mut store, &login(dav, None, "a")), Outcome::Skipped);
        assert_eq!(seed_at(&mut store, &login(dav, Some("Radicale"), "a")), Outcome::Added);
        // Radicale didn't answer, and the password changed: still updated.
        assert_eq!(seed_at(&mut store, &login(dav, None, "b")), Outcome::Changed);
        assert_eq!(store["logins"][0]["httpRealm"], "Radicale");
    }

    #[test]
    fn leaves_other_entries_and_fields_alone() {
        let mut store = empty();
        store["logins"] = json!([
            {"hostname": "imap://other", "httpRealm": "imap://other",
             "encryptedUsername": "~xam", "encryptedPassword": "~kept", "extra": 1}
        ]);
        let imap = "imap://mail.example";
        assert_eq!(seed_at(&mut store, &login(imap, Some(imap), "a")), Outcome::Added);
        assert_eq!(store["logins"][0]["encryptedPassword"], "~kept");
        assert_eq!(store["logins"][0]["extra"], 1);
    }
}
