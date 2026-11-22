//! The calendars in prefs.js, Thunderbird's own settings file (user.js is
//! home-manager's, read-only): one `calendar.registry.<id>.*` group each.
//!
//! The ones made here have ids starting `ark_`, from their URL, so the same
//! calendar keeps its id (and Thunderbird its cache and what was changed in
//! it, such as hiding it). Each time, these are set from the server: what
//! kind it is, where, whose, its name and its colour (when it has one). A
//! calendar no longer there loses its whole group; anything not `ark_` is
//! never touched.
use std::collections::BTreeSet;

pub const PREFIX: &str = "calendar.registry.ark_";

/// A calendar as ark-dav found it.
pub struct Calendar<'a> {
    pub url: &'a str,
    pub name: &'a str,
    pub color: Option<&'a str>,
}

/// The settings a calendar's group gets from the server, each time.
const OWNED: &[&str] = &["type", "uri", "username", "name", "color", "cache.enabled"];

/// `prefs` with `calendars`' groups up to date, and whether that changed it.
pub fn with_calendars(prefs: &str, calendars: &[Calendar], user: &str) -> (String, bool) {
    let ids: BTreeSet<String> = calendars.iter().map(|c| id(c.url)).collect();
    let mut known = BTreeSet::new();
    let mut lines: Vec<String> = Vec::new();
    for line in prefs.lines() {
        if let Some((id, key)) = name(line).and_then(ours) {
            known.insert(id.to_string());
            if !ids.contains(id) || OWNED.contains(&key) {
                continue;
            }
        }
        lines.push(line.to_string());
    }
    for c in calendars {
        let id = id(c.url);
        let set = |key: &str, value: String| format!("user_pref(\"{PREFIX}{id}.{key}\", {value});");
        let text = |s: &str| serde_json::to_string(s).expect("a string");
        lines.push(set("type", text("caldav")));
        lines.push(set("uri", text(c.url)));
        lines.push(set("username", text(user)));
        lines.push(set("name", text(c.name)));
        if let Some(color) = c.color {
            lines.push(set("color", text(color)));
        }
        lines.push(set("cache.enabled", "true".into()));
        if !known.contains(&id) {
            // Shown at first; hiding it afterwards is the person's to keep.
            lines.push(set("calendar-main-in-composite", "true".into()));
        }
    }
    let mut out = lines.join("\n");
    out.push('\n');
    let changed = sorted(&out) != sorted(prefs);
    (out, changed)
}

/// A calendar's id after `ark_`: its URL's FNV-1a hash, for a pref name
/// without dots.
pub fn id(url: &str) -> String {
    let hash = url
        .bytes()
        .fold(0xcbf29ce484222325u64, |h, b| (h ^ b as u64).wrapping_mul(0x100000001b3));
    format!("{hash:016x}")
}

/// The pref a `user_pref("…", …);` line sets.
fn name(line: &str) -> Option<&str> {
    let rest = line.trim_start().strip_prefix("user_pref(\"")?;
    Some(&rest[..rest.find('"')?])
}

/// (id, key) of one of ours.
fn ours(name: &str) -> Option<(&str, &str)> {
    name.strip_prefix(PREFIX)?.split_once('.')
}

/// The lines as a set: Thunderbird writes them in its own order, so order
/// alone isn't a change.
fn sorted(prefs: &str) -> BTreeSet<&str> {
    prefs.lines().filter(|l| !l.trim().is_empty()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const FAMILY: &str = "https://radicale.example/max/family-1/";

    fn family(name: &str) -> Calendar<'_> {
        Calendar {
            url: FAMILY,
            name,
            color: Some("#ff0000"),
        }
    }

    #[test]
    fn adds_a_calendar_then_keeps_what_was_changed_in_it() {
        let start = "// Mozilla User Preferences\nuser_pref(\"mail.foo\", 1);\n";
        let (prefs, changed) = with_calendars(start, &[family("Family")], "max");
        assert!(changed);
        let id = id(FAMILY);
        assert!(prefs.contains(&format!("\"{PREFIX}{id}.uri\", \"{FAMILY}\"")));
        assert!(prefs.contains(&format!("\"{PREFIX}{id}.calendar-main-in-composite\", true")));
        assert!(prefs.contains("user_pref(\"mail.foo\", 1);"));

        // Hidden in Thunderbird: it stays hidden; renamed on the server: renamed.
        let hidden = prefs.replace(
            &format!("\"{PREFIX}{id}.calendar-main-in-composite\", true"),
            &format!("\"{PREFIX}{id}.calendar-main-in-composite\", false"),
        );
        let (again, changed) = with_calendars(&hidden, &[family("Family")], "max");
        assert!(!changed);
        assert!(again.contains("composite\", false"));
        let (renamed, changed) = with_calendars(&hidden, &[family("Home")], "max");
        assert!(changed);
        assert!(renamed.contains(&format!("\"{PREFIX}{id}.name\", \"Home\"")));
        assert!(!renamed.contains("\"Family\""));
    }

    #[test]
    fn drops_a_calendar_no_longer_there_and_nothing_else() {
        let (prefs, _) = with_calendars("", &[family("Family")], "max");
        let prefs = format!("{prefs}user_pref(\"calendar.registry.abc.name\", \"Mine\");\n");
        let (gone, changed) = with_calendars(&prefs, &[], "max");
        assert!(changed);
        assert!(!gone.contains(PREFIX));
        assert!(gone.contains("calendar.registry.abc.name"));
    }

    #[test]
    fn ids_are_stable_and_plain() {
        assert_eq!(id(FAMILY), id(FAMILY));
        assert_ne!(id(FAMILY), id("https://radicale.example/max/family-2/"));
        assert!(id(FAMILY).chars().all(|c| c.is_ascii_hexdigit()));
    }
}
