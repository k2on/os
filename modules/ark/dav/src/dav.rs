//! What a person's Radicale folder holds, by asking it (WebDAV PROPFIND, one
//! level down).
use std::time::Duration;

use base64::{engine::general_purpose::STANDARD, Engine};
use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Calendar,
    AddressBook,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Collection {
    pub url: String,
    pub kind: Kind,
    pub name: String,
    /// `#rrggbb`, when it has one.
    pub color: Option<String>,
}

/// What the folder holds, and the realm Radicale asks for a password in
/// (what a password store files the login under).
#[derive(Debug, Serialize)]
pub struct Found {
    pub realm: Option<String>,
    pub collections: Vec<Collection>,
}

const QUERY: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<propfind xmlns="DAV:" xmlns:I="http://apple.com/ns/ical/">
  <prop><resourcetype/><displayname/><I:calendar-color/></prop>
</propfind>"#;

/// Asks `url` (the person's folder, ending in /) what it holds. Quick to give
/// up: a program is waiting to start.
pub fn discover(url: &str, user: &str, password: &str) -> Result<Found, String> {
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(3))
        .build();
    let propfind = || {
        agent
            .request("PROPFIND", url)
            .set("Depth", "1")
            .set("Content-Type", "application/xml; charset=utf-8")
    };
    // Without a login first: the refusal names the realm.
    let realm = match propfind().send_string(QUERY) {
        Err(ureq::Error::Status(401, r)) => r.header("WWW-Authenticate").and_then(realm),
        _ => None,
    };
    let login = STANDARD.encode(format!("{user}:{password}"));
    let body = propfind()
        .set("Authorization", &format!("Basic {login}"))
        .send_string(QUERY)
        .map_err(|e| format!("asking {url}: {e}"))?
        .into_string()
        .map_err(|e| format!("reading {url}'s answer: {e}"))?;
    Ok(Found {
        realm,
        collections: collections(&body, url),
    })
}

/// The realm of a `WWW-Authenticate: Basic realm="…"`.
pub fn realm(header: &str) -> Option<String> {
    let (_, rest) = header.split_once("realm=\"")?;
    Some(rest.split('"').next()?.to_string())
}

/// The calendars and address books in a PROPFIND's multistatus, `base`'s own
/// entry aside. Read loosely, by local names whatever the prefixes: enough
/// for what Radicale writes.
pub fn collections(xml: &str, base: &str) -> Vec<Collection> {
    let origin = origin(base);
    let mut found = Vec::new();
    let mut current: Option<Entry> = None;
    let mut open: Vec<String> = Vec::new();
    let mut rest = xml;
    while let Some(start) = rest.find('<') {
        if let (Some(e), Some(tag)) = (current.as_mut(), open.last()) {
            let text = unescape(rest[..start].trim());
            match tag.as_str() {
                "href" => e.href.push_str(&text),
                "displayname" => e.name.push_str(&text),
                "calendar-color" => e.color.push_str(&text),
                _ => {}
            }
        }
        let Some(end) = rest[start..].find('>') else {
            break;
        };
        let tag = &rest[start + 1..start + end];
        rest = &rest[start + end + 1..];
        if tag.starts_with('?') || tag.starts_with('!') {
            continue;
        }
        let name = local(tag.trim_start_matches('/').trim_end_matches('/'));
        if tag.starts_with('/') {
            open.pop();
            if name == "response" {
                found.extend(current.take().and_then(|e| e.collection(&origin, base)));
            }
            continue;
        }
        if name == "response" {
            current = Some(Entry::default());
        }
        if let Some(e) = current.as_mut() {
            if open.last().map(String::as_str) == Some("resourcetype") {
                match name.as_str() {
                    "calendar" => e.kind = Some(Kind::Calendar),
                    "addressbook" => e.kind = Some(Kind::AddressBook),
                    _ => {}
                }
            }
        }
        if !tag.ends_with('/') {
            open.push(name);
        }
    }
    found
}

#[derive(Default)]
struct Entry {
    href: String,
    kind: Option<Kind>,
    name: String,
    color: String,
}

impl Entry {
    fn collection(self, origin: &str, base: &str) -> Option<Collection> {
        let url = if self.href.starts_with("http") {
            self.href
        } else {
            format!("{origin}{}", self.href)
        };
        if url.trim_end_matches('/') == base.trim_end_matches('/') {
            return None;
        }
        let name = if self.name.is_empty() {
            let folder = url.trim_end_matches('/').rsplit('/').next();
            folder.unwrap_or_default().to_string()
        } else {
            self.name
        };
        // Apple's #rrggbbaa, as #rrggbb.
        let color = (self.color.len() >= 7 && self.color.starts_with('#'))
            .then(|| self.color[..7].to_string());
        Some(Collection {
            url,
            kind: self.kind?,
            name,
            color,
        })
    }
}

/// `https://host` of a URL.
pub fn origin(url: &str) -> String {
    let after = url.find("://").map_or(0, |i| i + 3);
    let end = url[after..].find('/').map_or(url.len(), |i| after + i);
    url[..end].to_string()
}

fn local(tag: &str) -> String {
    let name = tag.split_whitespace().next().unwrap_or_default();
    name.rsplit(':').next().unwrap_or(name).to_string()
}

fn unescape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        let entity = rest.find(';').map(|end| (&rest[1..end], end));
        let c = entity.and_then(|(e, _)| match e {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            _ => e
                .strip_prefix("#x")
                .and_then(|h| u32::from_str_radix(h, 16).ok())
                .or_else(|| e.strip_prefix('#').and_then(|d| d.parse().ok()))
                .and_then(char::from_u32),
        });
        match (c, entity) {
            (Some(c), Some((_, end))) => {
                out.push(c);
                rest = &rest[end + 1..];
            }
            _ => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What Radicale answers for a folder with an address book, a group's
    /// calendar linked in, and a calendar with no name.
    const ANSWER: &str = r##"<?xml version='1.0' encoding='utf-8'?>
<multistatus xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:CR="urn:ietf:params:xml:ns:carddav" xmlns:ICAL="http://apple.com/ns/ical/">
  <response><href>/max/</href><propstat><prop><resourcetype><principal/><collection/></resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat></response>
  <response><href>/max/contacts/</href><propstat><prop><resourcetype><CR:addressbook/><collection/></resourcetype><displayname>Contacts</displayname></prop><status>HTTP/1.1 200 OK</status></propstat><propstat><prop><ICAL:calendar-color/></prop><status>HTTP/1.1 404 Not Found</status></propstat></response>
  <response><href>/max/family-38E31150/</href><propstat><prop><resourcetype><C:calendar/><collection/></resourcetype><displayname>Family &amp; Friends</displayname><ICAL:calendar-color>#FF2968FF</ICAL:calendar-color></prop><status>HTTP/1.1 200 OK</status></propstat></response>
  <response><href>/max/untitled/</href><propstat><prop><resourcetype><C:calendar/><collection/></resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat></response>
</multistatus>"##;

    #[test]
    fn reads_what_the_folder_holds() {
        assert_eq!(
            collections(ANSWER, "https://radicale.example/max/"),
            vec![
                Collection {
                    url: "https://radicale.example/max/contacts/".into(),
                    kind: Kind::AddressBook,
                    name: "Contacts".into(),
                    color: None,
                },
                Collection {
                    url: "https://radicale.example/max/family-38E31150/".into(),
                    kind: Kind::Calendar,
                    name: "Family & Friends".into(),
                    color: Some("#FF2968".into()),
                },
                // No name: its folder's.
                Collection {
                    url: "https://radicale.example/max/untitled/".into(),
                    kind: Kind::Calendar,
                    name: "untitled".into(),
                    color: None,
                },
            ]
        );
    }

    #[test]
    fn reads_the_realm() {
        assert_eq!(
            realm(r#"Basic realm="Radicale - Password Required""#).as_deref(),
            Some("Radicale - Password Required")
        );
        assert_eq!(realm("Bearer"), None);
    }

    #[test]
    fn origins() {
        assert_eq!(origin("https://radicale.example/max/"), "https://radicale.example");
        assert_eq!(origin("https://radicale.example"), "https://radicale.example");
    }

    #[test]
    fn unescapes() {
        assert_eq!(unescape("a &amp; b &#x41;&#66; &bogus c&"), "a & b AB &bogus c&");
    }
}
