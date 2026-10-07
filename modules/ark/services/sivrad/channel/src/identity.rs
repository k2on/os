//! The identity table: who may talk to sivrad. A JSON object keyed by Kanidm
//! username (the phone's `preferred_username`), with how each person is
//! reached on Signal: their number (E.164) or their Signal username
//! (`name.NN`), for people who do not share their number:
//!
//!   { "alice": { "signal": "+15551234567" }, "bob": { "signal": "bob.42" } }
//!
//! The same person may write from the phone or from Signal. A missing or
//! unreadable file is an empty table: nobody gets in.

use std::collections::BTreeMap;
use std::path::Path;

use serde::Deserialize;

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
pub struct Person {
    /// The person's Signal number (E.164) or Signal username.
    #[serde(default)]
    pub signal: Option<String>,
}

/// How a person is reached on Signal.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SignalId<'a> {
    Number(&'a str),
    Username(&'a str),
}

impl Person {
    pub fn signal_id(&self) -> Option<SignalId<'_>> {
        let s = self.signal.as_deref()?;
        Some(if s.starts_with('+') {
            SignalId::Number(s)
        } else {
            SignalId::Username(s)
        })
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct People(BTreeMap<String, Person>);

impl People {
    pub fn parse(json: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json).map(People)
    }

    pub fn load(path: &Path) -> Self {
        let parsed = std::fs::read_to_string(path)
            .map_err(|e| e.to_string())
            .and_then(|s| People::parse(&s).map_err(|e| e.to_string()));
        parsed.unwrap_or_else(|e| {
            eprintln!("sivrad: identity table {}: {e}", path.display());
            People::default()
        })
    }

    pub fn contains(&self, username: &str) -> bool {
        self.0.contains_key(username)
    }

    /// Who owns a Signal number.
    pub fn by_number(&self, number: &str) -> Option<&str> {
        self.find(SignalId::Number(number))
    }

    /// Who owns a Signal username.
    pub fn by_signal_username(&self, username: &str) -> Option<&str> {
        self.find(SignalId::Username(username))
    }

    fn find(&self, id: SignalId) -> Option<&str> {
        self.0
            .iter()
            .find(|(_, p)| p.signal_id() == Some(id))
            .map(|(user, _)| user.as_str())
    }

    /// How a person is reached on Signal.
    pub fn signal_of(&self, username: &str) -> Option<SignalId<'_>> {
        self.0.get(username)?.signal_id()
    }

    /// Everyone reachable over Signal.
    pub fn on_signal(&self) -> Vec<&str> {
        self.0
            .iter()
            .filter(|(_, p)| p.signal.is_some())
            .map(|(user, _)| user.as_str())
            .collect()
    }

    /// The Signal usernames in the table, which have to be resolved to
    /// account ids before their messages can be told apart.
    pub fn signal_usernames(&self) -> Vec<&str> {
        self.0
            .values()
            .filter_map(|p| match p.signal_id() {
                Some(SignalId::Username(u)) => Some(u),
                _ => None,
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TABLE: &str = r#"{ "alice": { "signal": "+15551234567" }, "bob": {}, "carol": { "signal": "carol.42" } }"#;

    #[test]
    fn parses_the_table() {
        let people = People::parse(TABLE).unwrap();
        assert!(people.contains("alice"));
        assert!(people.contains("bob"));
        assert!(!people.contains("mallory"));
        assert_eq!(people.0["bob"].signal, None);
    }

    #[test]
    fn lookups() {
        let people = People::parse(TABLE).unwrap();
        assert_eq!(people.by_number("+15551234567"), Some("alice"));
        assert_eq!(people.by_number("+15550000000"), None);
        assert_eq!(people.by_number("carol.42"), None);
        assert_eq!(people.by_signal_username("carol.42"), Some("carol"));
        assert_eq!(people.by_signal_username("+15551234567"), None);
        assert_eq!(
            people.signal_of("alice"),
            Some(SignalId::Number("+15551234567"))
        );
        assert_eq!(
            people.signal_of("carol"),
            Some(SignalId::Username("carol.42"))
        );
        assert_eq!(people.signal_of("bob"), None);
        assert_eq!(people.signal_of("mallory"), None);
        assert_eq!(people.on_signal(), ["alice", "carol"]);
        assert_eq!(people.signal_usernames(), ["carol.42"]);
    }

    #[test]
    fn rejects_other_shapes() {
        assert!(People::parse(r#"["alice"]"#).is_err());
        assert!(People::parse(r#"{ "alice": "+1555" }"#).is_err());
    }

    #[test]
    fn missing_file_is_empty() {
        assert_eq!(
            People::load(Path::new("/nonexistent/people.json")),
            People::default()
        );
    }
}
