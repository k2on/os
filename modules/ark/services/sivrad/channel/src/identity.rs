//! The identity table: who may talk to sivrad. A JSON object keyed by Kanidm
//! username (the phone's `preferred_username`), with each person's Signal
//! number:
//!
//!   { "alice": { "signal": "+15551234567" }, "bob": { "signal": "+15557654321" } }
//!
//! The same person may write from the phone or from Signal. A missing or
//! unreadable file is an empty table: nobody gets in.

use std::collections::BTreeMap;
use std::path::Path;

use serde::Deserialize;

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
pub struct Person {
    /// The person's Signal number (E.164).
    #[serde(default)]
    pub signal: Option<String>,
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
        self.0
            .iter()
            .find(|(_, p)| p.signal.as_deref() == Some(number))
            .map(|(user, _)| user.as_str())
    }

    /// A person's Signal number.
    pub fn number_of(&self, username: &str) -> Option<&str> {
        self.0.get(username)?.signal.as_deref()
    }

    /// Everyone reachable over Signal.
    pub fn on_signal(&self) -> Vec<&str> {
        self.0
            .iter()
            .filter(|(_, p)| p.signal.is_some())
            .map(|(user, _)| user.as_str())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TABLE: &str = r#"{ "alice": { "signal": "+15551234567" }, "bob": {} }"#;

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
        assert_eq!(people.number_of("alice"), Some("+15551234567"));
        assert_eq!(people.number_of("bob"), None);
        assert_eq!(people.number_of("mallory"), None);
        assert_eq!(people.on_signal(), ["alice"]);
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
