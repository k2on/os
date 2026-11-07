//! Stalwart's accounts, as the TOML its in-memory directory reads at start
//! (appended to its config by ../../default.nix): every group and person,
//! with their addresses. Groups come first, because an address on several
//! accounts delivers to the first; so a group's address, and an alias going
//! to a group, deliver to the group's mailbox while its members carry them
//! too, which is what lets them send as them. A person carries their own
//! address, their groups', and every alias that is on and goes to them, to
//! one of their groups, or that they made. Turned-off aliases are nowhere,
//! so mail to them is refused. Senders (a service's alerts) come last: their
//! own address only.
use std::fmt::Write;

use crate::config::Config;
use crate::db::Alias;

fn quote(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

fn list<'a>(items: impl IntoIterator<Item = &'a str>) -> String {
    let mut seen = Vec::new();
    for item in items {
        if !seen.contains(&item) {
            seen.push(item);
        }
    }
    format!("[{}]", seen.iter().map(|s| quote(s)).collect::<Vec<_>>().join(", "))
}

pub fn render(config: &Config, aliases: &[Alias]) -> String {
    let live: Vec<&Alias> = aliases.iter().filter(|a| a.active).collect();
    let mut out = String::from("\n# Accounts, from mail-aliases render\n");
    for group in &config.groups {
        let emails = std::iter::once(group.address.as_str())
            .chain(live.iter().filter(|a| a.target == group.name).map(|a| a.address.as_str()));
        let _ = write!(
            out,
            "\n[[directory.ark.principals]]\nclass = \"group\"\nname = {}\nemail = {}\n",
            quote(&group.name),
            list(emails),
        );
    }
    for person in &config.persons {
        let groups = config.groups.iter().filter(|g| person.groups.contains(&g.name));
        let mine = |a: &&&Alias| a.target == person.name || a.creator == person.name || person.groups.contains(&a.target);
        let emails = std::iter::once(person.address.as_str())
            .chain(groups.map(|g| g.address.as_str()))
            .chain(live.iter().filter(mine).map(|a| a.address.as_str()));
        let _ = write!(
            out,
            "\n[[directory.ark.principals]]\nclass = \"individual\"\nname = {}\nsecret = {}\nemail = {}\nmember-of = {}\n",
            quote(&person.name),
            quote(&format!("%{{file:{}}}%", person.password_file.display())),
            list(emails),
            list(person.groups.iter().map(String::as_str)),
        );
    }
    for sender in &config.senders {
        let _ = write!(
            out,
            "\n[[directory.ark.principals]]\nclass = \"individual\"\nname = {}\nsecret = {}\nemail = {}\n",
            quote(&sender.name),
            quote(&format!("%{{file:{}}}%", sender.password_file.display())),
            list([sender.address.as_str()]),
        );
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::tests::{config, tempdir};

    fn alias(address: &str, creator: &str, target: &str, active: bool) -> Alias {
        Alias {
            address: address.into(),
            creator: creator.into(),
            target: target.into(),
            site: None,
            created: String::new(),
            active,
        }
    }

    #[test]
    fn groups_first_and_aliases_where_they_go() {
        let dir = tempdir("render");
        let cfg = config(&dir, &[("alice", &["family"]), ("carol", &[])], &["family"]);
        let out = render(
            &cfg,
            &[
                alias("shop-1@test.example", "alice", "alice", true),
                alias("trip-2@test.example", "carol", "family", true),
                alias("dead-3@test.example", "alice", "alice", false),
            ],
        );
        let family = out.find("name = \"family\"").unwrap();
        let alice = out.find("name = \"alice\"").unwrap();
        assert!(family < alice, "{out}");
        assert!(out.contains("email = [\"family@test.example\", \"trip-2@test.example\"]"), "{out}");
        assert!(out.contains(
            "email = [\"alice@test.example\", \"family@test.example\", \"shop-1@test.example\", \"trip-2@test.example\"]"
        ));
        // carol made trip-2 and may still send as it; she is in no group.
        assert!(out.contains("email = [\"carol@test.example\", \"trip-2@test.example\"]\nmember-of = []"), "{out}");
        assert!(!out.contains("dead-3"));
        assert!(out.contains(&format!("secret = \"%{{file:{}}}%\"", dir.join("alice.pw").display())));
    }

    #[test]
    fn senders_carry_their_address_only() {
        let dir = tempdir("render-senders");
        let mut cfg = config(&dir, &[("alice", &["family"])], &["family"]);
        cfg.senders.push(crate::config::Sender {
            name: "alerts".into(),
            address: "alerts@test.example".into(),
            password_file: dir.join("alerts.pw"),
        });
        let out = render(&cfg, &[alias("a-1@test.example", "alice", "alerts", true)]);
        let sender = &out[out.find("name = \"alerts\"").unwrap()..];
        assert!(sender.contains("email = [\"alerts@test.example\"]\n"), "{out}");
        assert!(!sender.contains("member-of"), "{out}");
        assert!(sender.contains(&format!("secret = \"%{{file:{}}}%\"", dir.join("alerts.pw").display())));
    }
}
