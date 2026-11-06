//! Everyone's picture as last synced, for the long poll (http.rs): kept in
//! memory (a few people, a picture each) with a tag that changes with the
//! bytes, and woken whenever a sync changes anything. Each new picture is
//! also cropped to a circle (image.rs), once.
use std::collections::HashMap;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

#[derive(Clone)]
pub struct Picture {
    /// As a PNG (sync.rs).
    pub bytes: Arc<Vec<u8>>,
    pub tag: String,
    /// As a circle, a PNG; None when it could not be made.
    pub circle: Option<Arc<Vec<u8>>>,
}

impl Picture {
    /// Tagged by what Immich has, so the tag does not hang on how
    /// ImageMagick encodes it.
    pub fn new(original: &[u8], png: Vec<u8>) -> Picture {
        Picture { tag: tag(original), bytes: Arc::new(png), circle: None }
    }

    /// What a client asking for `shape` is sent: its tag and its bytes, a
    /// PNG. A circle that could not be made is the picture as it is, under
    /// the picture's own tag, so a client has it again once the circle
    /// exists.
    pub fn served(&self, shape: Shape) -> Served {
        match (shape, &self.circle) {
            (Shape::Circle, Some(circle)) => (format!("{}-circle", self.tag), circle.clone()),
            _ => (self.tag.clone(), self.bytes.clone()),
        }
    }
}

/// What is sent: the tag and the bytes.
pub type Served = (String, Arc<Vec<u8>>);

#[derive(Clone, Copy, PartialEq)]
pub enum Shape {
    AsIs,
    Circle,
}

/// The tag of someone without a picture.
pub const NONE: &str = "none";

/// FNV-1a: the same bytes always get the same tag, across restarts too,
/// so a client that has the picture is not sent it again.
fn tag(bytes: &[u8]) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in bytes {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}

/// Per person: absent until the first sync has seen them, then None
/// without a picture or Some(picture).
#[derive(Default)]
pub struct Pictures {
    by_person: Mutex<HashMap<String, Option<Picture>>>,
    changed: Condvar,
}

impl Pictures {
    /// What a sync found; people it could not decide about are left as
    /// they were. `circle` crops a new picture.
    pub fn update(
        &self,
        found: HashMap<String, Option<Picture>>,
        circle: impl Fn(&Picture) -> Option<Vec<u8>>,
    ) {
        let mut by_person = self.by_person.lock().unwrap();
        let mut any = false;
        for (person, picture) in found {
            let same = match (by_person.get(&person), &picture) {
                (Some(Some(old)), Some(new)) => old.tag == new.tag,
                (Some(None), None) => true,
                _ => false,
            };
            if same {
                continue;
            }
            let picture = picture.map(|mut p| {
                p.circle = circle(&p).map(Arc::new);
                p
            });
            by_person.insert(person, picture);
            any = true;
        }
        if any {
            self.changed.notify_all();
        }
    }

    /// Their picture in `shape`, unless its tag is `have` (or nobody knows
    /// yet), in which case it waits up to `timeout` for a change: Some
    /// (served, or None for no picture) when it differs, None when not.
    pub fn differing(
        &self,
        person: &str,
        have: &str,
        shape: Shape,
        timeout: Duration,
    ) -> Option<Option<Served>> {
        let differs = |m: &HashMap<String, Option<Picture>>| match m.get(person) {
            Some(Some(p)) => Some(p.served(shape)).filter(|(tag, _)| tag != have).map(Some),
            Some(None) if have != NONE => Some(None),
            _ => None,
        };
        let by_person = self.by_person.lock().unwrap();
        if let Some(d) = differs(&by_person) {
            return Some(d);
        }
        let (by_person, _) = self.changed.wait_timeout(by_person, timeout).unwrap();
        differs(&by_person)
    }
}
