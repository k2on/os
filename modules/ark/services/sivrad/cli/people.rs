//! `ark service sivrad people ...`: the identity table, the sivrad_people
//! secret, and the Kanidm group that follows it.
//!
//! The secret is what the channel reads (people.json in the VM, re-read on
//! every request): a JSON object keyed by Kanidm username,
//!
//!     { "alice": { "signal": "+15551234567" } }
//!
//! Every change also rewrites secrets/services/sivrad/people.nix, the flake
//! module that sets `ark.sivrad.people` (../default.nix) and with it the
//! sivrad_users group in Kanidm, so who may sign in to the app always
//! matches who is in the table. The group needs a deploy of adam; the
//! table itself only needs the secret on adam, which the same deploy brings.
use std::collections::BTreeMap;
use std::fs;

use anyhow::{bail, Context, Result};
use clap::{Arg, ArgMatches, Command};
use serde_json::{Map, Value};

use super::Config;
use crate::secrets::Manifest;
use crate::service::Ctx;

pub const SECRET: &str = "sivrad_people";
/// Inside the secrets submodule.
const PEOPLE_NIX: &str = "services/sivrad/people.nix";

pub fn command() -> Command {
    Command::new("people")
        .about("Who may talk to sivrad: the sivrad_people table and the Kanidm group")
        .long_about(
            "Who may talk to sivrad: the sivrad_people secret (Kanidm username -> Signal number), \
             which the channel reads, and secrets/services/sivrad/people.nix, which puts the same \
             usernames in the Kanidm group sivrad_users so they can sign in to the app. Commit secrets/ \
             and deploy adam afterwards.",
        )
        .subcommand_required(true)
        .arg_required_else_help(true)
        .subcommand(
            Command::new("add")
                .about("Add a person, or change their Signal number")
                .arg(Arg::new("username").required(true).help("Their Kanidm username, as in secrets/ark.nix"))
                .arg(
                    Arg::new("number")
                        .required(true)
                        .allow_hyphen_values(true)
                        .help("Their Signal number in E.164, e.g. +15551234567"),
                ),
        )
        .subcommand(
            Command::new("remove")
                .about("Remove a person")
                .arg(Arg::new("username").required(true).help("Their Kanidm username")),
        )
        .subcommand(Command::new("list").about("List the people in the table"))
}

pub fn run(ctx: &Ctx, m: &ArgMatches) -> Result<()> {
    let arg = |m: &ArgMatches, name: &str| m.get_one::<String>(name).expect("required").clone();
    match m.subcommand() {
        Some(("add", m)) => {
            let cfg = Config::load(ctx)?;
            let manifest = Manifest::load(ctx)?;
            let mut people = load(ctx, &manifest)?;
            let user = arg(m, "username");
            check_person(&cfg, &user)?;
            let change = add(&mut people, &user, &arg(m, "number"))?;
            save(ctx, &manifest, &people)?;
            println!("{change}");
            applied();
            Ok(())
        }
        Some(("remove", m)) => {
            let manifest = Manifest::load(ctx)?;
            let mut people = load(ctx, &manifest)?;
            let user = arg(m, "username");
            remove(&mut people, &user)?;
            save(ctx, &manifest, &people)?;
            println!("removed {user}");
            applied();
            Ok(())
        }
        Some(("list", _)) => {
            let manifest = Manifest::load(ctx)?;
            let people = load(ctx, &manifest)?;
            if people.is_empty() {
                println!("nobody yet; add someone with `ark service sivrad people add <username> <+number>`");
            }
            for line in list(&people) {
                println!("{line}");
            }
            Ok(())
        }
        _ => unreachable!("subcommand_required"),
    }
}

fn applied() {
    println!(
        "Apply it: commit secrets/, then deploy adam. The channel re-reads the table as soon as adam has \
         the new secret; the Kanidm group sivrad_users changes with the same deploy."
    );
}

/// The table as stored, or empty when the secret does not exist yet (or is
/// empty). Decrypts it (one yubikey touch).
pub fn load(ctx: &Ctx, manifest: &Manifest) -> Result<Map<String, Value>> {
    if !manifest.present(ctx, SECRET) {
        return Ok(Map::new());
    }
    eprintln!("decrypting {SECRET} (touch the yubikey when it blinks)");
    parse(&manifest.read(ctx, SECRET)?)
}

/// Stores the table and rewrites people.nix to match.
pub fn save(ctx: &Ctx, manifest: &Manifest, people: &Map<String, Value>) -> Result<()> {
    let file = manifest.spec(SECRET)?.file.clone();
    manifest
        .store(
            ctx,
            &file,
            &BTreeMap::from([(SECRET.to_string(), render(people))]),
        )
        .with_context(|| format!("storing {SECRET}"))?;
    write_people_nix(ctx, people)
}

/// Writes (and stages) secrets/services/sivrad/people.nix from the table.
pub fn write_people_nix(ctx: &Ctx, people: &Map<String, Value>) -> Result<()> {
    let path = ctx.root.join("secrets").join(PEOPLE_NIX);
    fs::create_dir_all(path.parent().expect("parent"))?;
    fs::write(&path, people_nix(people.keys().map(String::as_str)))
        .with_context(|| format!("writing secrets/{PEOPLE_NIX}"))?;
    // Staged so the flake, which only sees tracked files, picks it up.
    ctx.git_secrets(&["add", PEOPLE_NIX])
}

pub fn people_nix_exists(ctx: &Ctx) -> bool {
    ctx.root.join("secrets").join(PEOPLE_NIX).is_file()
}

/// Refuses usernames Kanidm does not know: a group member must be a person
/// provisioned from secrets/ark.nix (ark.persons).
fn check_person(cfg: &Config, user: &str) -> Result<()> {
    if !valid_username(user) {
        bail!("'{user}' is not a Kanidm username ([a-z][a-z0-9_-]*)");
    }
    if !cfg.persons.iter().any(|p| p == user) {
        bail!("'{user}' has no Kanidm account: add them to ark.persons in secrets/ark.nix first");
    }
    Ok(())
}

/// Asks for people until an empty username, for `init`. Kanidm accounts are
/// checked like `people add` does.
pub fn prompt_people(ctx: &Ctx, cfg: &Config) -> Result<Map<String, Value>> {
    let mut people = Map::new();
    println!("Who may talk to sivrad? One person at a time; an empty username ends the list.");
    loop {
        let user = ctx.prompt("  Kanidm username")?.trim().to_string();
        if user.is_empty() {
            if people.is_empty() {
                eprintln!("  at least one person, please");
                continue;
            }
            return Ok(people);
        }
        if let Err(e) = check_person(cfg, &user) {
            eprintln!("  {e}");
            continue;
        }
        let number = ctx.prompt(&format!(
            "  {user}'s Signal number (E.164, e.g. +15551234567)"
        ))?;
        match add(&mut people, &user, number.trim()) {
            Ok(change) => println!("  {change}"),
            Err(e) => eprintln!("  {e}"),
        }
    }
}

pub fn valid_username(s: &str) -> bool {
    let mut chars = s.chars();
    matches!(chars.next(), Some('a'..='z'))
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

/// E.164: a plus, a country code that does not start with 0, 7 to 15 digits
/// in all (`^\+[1-9][0-9]{6,14}$`).
pub fn valid_e164(s: &str) -> bool {
    let Some(digits) = s.strip_prefix('+') else {
        return false;
    };
    (7..=15).contains(&digits.len())
        && digits.chars().all(|c| c.is_ascii_digit())
        && !digits.starts_with('0')
}

pub fn parse(json: &str) -> Result<Map<String, Value>> {
    if json.trim().is_empty() {
        return Ok(Map::new());
    }
    match serde_json::from_str(json).context("sivrad_people is not valid JSON")? {
        Value::Object(people) => Ok(people),
        _ => bail!("sivrad_people is not a JSON object keyed by username"),
    }
}

pub fn render(people: &Map<String, Value>) -> String {
    serde_json::to_string(people).expect("a JSON map serializes")
}

/// Adds a person or changes their number; other fields of their entry are
/// kept. A number belongs to one person only, since the channel tells
/// Signal senders apart by it. Returns what changed, for the terminal.
pub fn add(people: &mut Map<String, Value>, user: &str, number: &str) -> Result<String> {
    if !valid_username(user) {
        bail!("'{user}' is not a Kanidm username ([a-z][a-z0-9_-]*)");
    }
    if !valid_e164(number) {
        bail!("'{number}' is not an E.164 number: a + and the country code, digits only, e.g. +15551234567");
    }
    if let Some((other, _)) = people.iter().find(|(name, p)| {
        name.as_str() != user && p.get("signal").and_then(Value::as_str) == Some(number)
    }) {
        bail!("{number} is already {other}'s number");
    }
    let entry = people
        .entry(user.to_string())
        .or_insert_with(|| Value::Object(Map::new()));
    let Value::Object(fields) = entry else {
        bail!("{user}'s entry in sivrad_people is not a JSON object");
    };
    let before = fields.insert("signal".to_string(), Value::String(number.to_string()));
    Ok(match before {
        None => format!("added {user} ({number})"),
        Some(Value::String(old)) if old == number => format!("{user} already has {number}"),
        Some(old) => format!("{user}: {} -> {number}", old.as_str().unwrap_or("?")),
    })
}

pub fn remove(people: &mut Map<String, Value>, user: &str) -> Result<()> {
    if people.remove(user).is_none() {
        bail!("{user} is not in sivrad_people");
    }
    Ok(())
}

pub fn list(people: &Map<String, Value>) -> Vec<String> {
    people
        .iter()
        .map(|(user, p)| {
            format!(
                "{user:<16} {}",
                p.get("signal")
                    .and_then(Value::as_str)
                    .unwrap_or("(no Signal number)")
            )
        })
        .collect()
}

fn nix_str(s: &str) -> String {
    format!(
        "\"{}\"",
        s.replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace("${", "\\${")
    )
}

/// secrets/services/sivrad/people.nix: a flake module (import-tree loads
/// every .nix under secrets/), formatted as nixfmt would.
pub fn people_nix<'a>(users: impl IntoIterator<Item = &'a str>) -> String {
    let users: Vec<String> = users.into_iter().map(nix_str).collect();
    let list = if users.is_empty() {
        "[ ]".to_string()
    } else {
        format!(
            "[\n{}  ]",
            users
                .iter()
                .map(|u| format!("    {u}\n"))
                .collect::<String>()
        )
    };
    format!(
        "# Written by `ark service sivrad people ...` from the sivrad_people secret;\n\
         # change it with that command, not by hand. These usernames make up the\n\
         # Kanidm group sivrad_users, who may sign in to the sivrad app.\n\
         {{\n\
         \x20 ark.sivrad.people = {list};\n\
         }}\n"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usernames() {
        for ok in ["alice", "a", "bob-2", "c_d"] {
            assert!(valid_username(ok), "{ok}");
        }
        for bad in ["", "Alice", "1bob", "-x", "_x", "al ice", "al.ice", "émile"] {
            assert!(!valid_username(bad), "{bad}");
        }
    }

    #[test]
    fn e164() {
        for ok in [
            "+15551234567",
            "+4930123456",
            "+1234567",
            "+123456789012345",
        ] {
            assert!(valid_e164(ok), "{ok}");
        }
        for bad in [
            "15551234567",
            "+05551234567",
            "+123456",
            "+1234567890123456",
            "+1 555 123 4567",
            "+1555123456a",
            "+",
            "",
        ] {
            assert!(!valid_e164(bad), "{bad}");
        }
    }

    #[test]
    fn editing_the_table() {
        let mut people = parse(r#"{"alice":{"signal":"+15551234567","note":"kept"}}"#).unwrap();
        assert_eq!(
            add(&mut people, "bob", "+15557654321").unwrap(),
            "added bob (+15557654321)"
        );
        assert_eq!(
            add(&mut people, "alice", "+15550000000").unwrap(),
            "alice: +15551234567 -> +15550000000"
        );
        assert_eq!(
            add(&mut people, "alice", "+15550000000").unwrap(),
            "alice already has +15550000000"
        );
        assert_eq!(
            render(&people),
            r#"{"alice":{"note":"kept","signal":"+15550000000"},"bob":{"signal":"+15557654321"}}"#
        );
        // One number, one person.
        assert!(add(&mut people, "carol", "+15557654321")
            .unwrap_err()
            .to_string()
            .contains("bob's number"));
        assert!(add(&mut people, "Carol", "+15550000001").is_err());
        assert!(add(&mut people, "carol", "5550000001").is_err());

        remove(&mut people, "alice").unwrap();
        assert!(remove(&mut people, "alice").is_err());
        assert_eq!(render(&people), r#"{"bob":{"signal":"+15557654321"}}"#);
        assert_eq!(list(&people), vec!["bob              +15557654321"]);
    }

    #[test]
    fn parsing() {
        assert!(parse("").unwrap().is_empty());
        assert!(parse("{}").unwrap().is_empty());
        assert!(parse("[]").is_err());
        assert!(parse("{").is_err());
        let people = parse(r#"{ "alice": { "signal": "+15551234567" }, "bob": {} }"#).unwrap();
        assert_eq!(
            list(&people),
            vec![
                "alice            +15551234567",
                "bob              (no Signal number)"
            ]
        );
    }

    #[test]
    fn rendering_people_nix() {
        assert_eq!(
            people_nix(["alice", "bob"]),
            "# Written by `ark service sivrad people ...` from the sivrad_people secret;\n\
             # change it with that command, not by hand. These usernames make up the\n\
             # Kanidm group sivrad_users, who may sign in to the sivrad app.\n\
             {\n  ark.sivrad.people = [\n    \"alice\"\n    \"bob\"\n  ];\n}\n"
        );
        assert!(people_nix([]).contains("  ark.sivrad.people = [ ];\n"));
        assert!(people_nix(["a\"${x}"]).contains(r#""a\"\${x}""#));
    }
}
