//! The aliases: address, who made it, where its mail goes, the site it was
//! made for, and whether it is on. The one thing here that is not anywhere
//! else; people and groups are configuration (config.rs). An alias's
//! creator is a person; its target is that person, or a group whose vault
//! the login holding it was saved in (retarget).
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use rusqlite::{params, Connection};
use serde::Serialize;

use crate::config::Config;
use crate::{names, Result};

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS aliases (
  address TEXT PRIMARY KEY,
  creator TEXT NOT NULL,
  target TEXT NOT NULL,
  site TEXT,
  created TEXT NOT NULL DEFAULT (datetime('now')),
  active INTEGER NOT NULL DEFAULT 1
);
";

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct Alias {
    pub address: String,
    pub creator: String,
    pub target: String,
    pub site: Option<String>,
    pub created: String,
    pub active: bool,
}

#[derive(Serialize, Debug, PartialEq)]
pub struct Moved {
    pub address: String,
    pub from: String,
    pub to: String,
}

pub struct Db(Connection);

impl Db {
    pub fn open(path: &Path) -> Result<Db> {
        let conn = Connection::open(path).map_err(|e| format!("opening {}: {e}", path.display()))?;
        conn.busy_timeout(std::time::Duration::from_secs(30))?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.execute_batch(SCHEMA)?;
        Ok(Db(conn))
    }

    /// Against who is configured now: an alias whose creator left is turned
    /// off; one whose target left goes back to its creator.
    pub fn sync(&mut self, config: &Config) -> Result<()> {
        let people: BTreeSet<&str> = config.persons.iter().map(|p| p.name.as_str()).collect();
        let accounts: BTreeSet<&str> = people.iter().copied().chain(config.groups.iter().map(|g| g.name.as_str())).collect();
        for alias in self.list()? {
            if !people.contains(alias.creator.as_str()) && alias.active {
                self.0.execute("UPDATE aliases SET active = 0 WHERE address = ?1", [&alias.address])?;
            } else if !accounts.contains(alias.target.as_str()) {
                self.0.execute("UPDATE aliases SET target = creator WHERE address = ?1", [&alias.address])?;
            }
        }
        Ok(())
    }

    /// A new alias for `creator`, at `domain`, going to them; never one of
    /// the `taken` addresses (people's and groups').
    pub fn create(&mut self, creator: &str, domain: &str, site: Option<&str>, taken: &BTreeSet<String>) -> Result<String> {
        for _ in 0..20 {
            let address = format!("{}@{domain}", names::local_part(site)).to_lowercase();
            let exists: bool =
                self.0.query_row("SELECT EXISTS (SELECT 1 FROM aliases WHERE address = ?1)", [&address], |r| r.get(0))?;
            if !exists && !taken.contains(&address) {
                self.0.execute(
                    "INSERT INTO aliases (address, creator, target, site) VALUES (?1, ?2, ?2, ?3)",
                    params![address, creator, site],
                )?;
                return Ok(address);
            }
        }
        Err("no free address in 20 tries".into())
    }

    pub fn list(&self) -> Result<Vec<Alias>> {
        let mut stmt = self
            .0
            .prepare("SELECT address, creator, target, site, created, active FROM aliases ORDER BY created, address")?;
        let rows = stmt.query_map([], |r| {
            Ok(Alias {
                address: r.get(0)?,
                creator: r.get(1)?,
                target: r.get(2)?,
                site: r.get(3)?,
                created: r.get(4)?,
                active: r.get(5)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// Turns an alias on or off; false if there is no such alias.
    pub fn set_active(&mut self, address: &str, active: bool) -> Result<bool> {
        let n = self
            .0
            .execute("UPDATE aliases SET active = ?2 WHERE address = ?1", params![address.to_lowercase(), active])?;
        Ok(n > 0)
    }

    /// Points aliases at the groups whose vaults hold them. `seen` is, for
    /// every group whose vault was read, the addresses found in it. An alias
    /// found goes to that group (the first, if in several); one going to a
    /// group that was read but no longer has it goes back to its creator.
    /// Aliases going to groups that were not read are left alone, and so
    /// are groups that are not configured.
    pub fn retarget(&mut self, seen: &BTreeMap<String, Vec<String>>, groups: &BTreeSet<String>) -> Result<Vec<Moved>> {
        let mut found: BTreeMap<String, &str> = BTreeMap::new();
        for (group, addresses) in seen.iter().filter(|(g, _)| groups.contains(*g)) {
            for address in addresses {
                found.entry(address.to_lowercase()).or_insert(group);
            }
        }
        let mut moved = Vec::new();
        for alias in self.list()? {
            let want = match found.get(&alias.address) {
                Some(group) => group.to_string(),
                None if seen.contains_key(&alias.target) => alias.creator.clone(),
                None => continue,
            };
            if want != alias.target {
                self.0.execute("UPDATE aliases SET target = ?2 WHERE address = ?1", params![alias.address, want])?;
                moved.push(Moved { address: alias.address, from: alias.target, to: want });
            }
        }
        Ok(moved)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::config::{Group, Person};
    use std::fs;

    pub fn config(dir: &Path, persons: &[(&str, &[&str])], groups: &[&str]) -> Config {
        Config {
            db: dir.join("db"),
            changed_file: dir.join("changed"),
            domain: "test.example".into(),
            listen: String::new(),
            internal_listen: String::new(),
            internal_key_file: dir.join("key"),
            persons: persons
                .iter()
                .map(|(name, groups)| Person {
                    name: name.to_string(),
                    address: format!("{name}@test.example"),
                    password_file: dir.join(format!("{name}.pw")),
                    token_file: dir.join("token"),
                    groups: groups.iter().map(|g| g.to_string()).collect(),
                })
                .collect(),
            groups: groups
                .iter()
                .map(|g| Group { name: g.to_string(), address: format!("{g}@test.example") })
                .collect(),
            senders: Vec::new(),
        }
    }

    pub fn tempdir(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("mail-aliases-{name}-{}", names::random(8)));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn aliases_follow_the_vault_they_are_in() {
        let dir = tempdir("retarget");
        let cfg = config(&dir, &[("alice", &["family"]), ("bob", &["family"])], &["family", "admin"]);
        let groups: BTreeSet<String> = ["family".to_string(), "admin".to_string()].into();
        let mut db = Db::open(&cfg.db).unwrap();
        let a = db.create("alice", "test.example", Some("expedia"), &BTreeSet::new()).unwrap();
        let b = db.create("bob", "test.example", None, &BTreeSet::new()).unwrap();
        assert!(a.starts_with("expedia-") && a.ends_with("@test.example"));

        // a is saved in the family vault.
        let seen = BTreeMap::from([("family".to_string(), vec![a.to_uppercase()])]);
        let moved = db.retarget(&seen, &groups).unwrap();
        assert_eq!(moved, vec![Moved { address: a.clone(), from: "alice".into(), to: "family".into() }]);
        assert!(db.retarget(&seen, &groups).unwrap().is_empty());

        // An admin vault read that does not have it changes nothing; a
        // group that is not configured moves nothing.
        let other = BTreeMap::from([("admin".to_string(), vec![]), ("family".to_string(), vec![a.clone()])]);
        assert!(db.retarget(&other, &groups).unwrap().is_empty());
        let unknown = BTreeMap::from([("work".to_string(), vec![b.clone()])]);
        assert!(db.retarget(&unknown, &groups).unwrap().is_empty());

        // Out of the family vault: back to alice. b was never anywhere.
        let empty = BTreeMap::from([("family".to_string(), vec![])]);
        let moved = db.retarget(&empty, &groups).unwrap();
        assert_eq!(moved, vec![Moved { address: a.clone(), from: "family".into(), to: "alice".into() }]);
        assert_eq!(db.list().unwrap().iter().find(|x| x.address == b).unwrap().target, "bob");

        // Off and on again; bob leaving turns his off.
        assert!(db.set_active(&a, false).unwrap());
        assert!(!db.list().unwrap().iter().find(|x| x.address == a).unwrap().active);
        assert!(!db.set_active("nobody@test.example", false).unwrap());
        db.sync(&config(&dir, &[("alice", &["family"])], &["family"])).unwrap();
        assert!(!db.list().unwrap().iter().find(|x| x.address == b).unwrap().active);
    }

}
