//! What each host builds at a commit, worked out here in the background so
//! the watch can draw meanwhile, and remembered: a commit's systems never
//! change, so a second watch of it (`--no-push`, a rerun) knows them at once,
//! and a host the commit leaves as it was shows done in the first frame.
//!
//! Remembered in $XDG_CACHE_HOME/ark/systems/<commit>.json, only when every
//! host evaluated: a failure may be this machine's (no network, no key).
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::thread::JoinHandle;

use super::{evaluate_these, Expected};

pub struct Evaluation {
    pending: Option<JoinHandle<BTreeMap<String, Expected>>>,
    done: Option<BTreeMap<String, Expected>>,
}

fn cache_file(commit: &str) -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))?;
    Some(
        base.join("ark")
            .join("systems")
            .join(format!("{commit}.json")),
    )
}

/// The systems remembered in `file`, if every one of `names` is there.
fn recall(file: &Path, names: &[String]) -> Option<BTreeMap<String, Expected>> {
    let text = std::fs::read_to_string(file).ok()?;
    let paths: BTreeMap<String, String> = serde_json::from_str(&text).ok()?;
    names
        .iter()
        .map(|n| Some((n.clone(), Expected::Path(paths.get(n)?.clone()))))
        .collect()
}

/// Remembers the systems in `file` when every host evaluated.
fn remember(file: &Path, expected: &BTreeMap<String, Expected>) {
    let paths: Option<BTreeMap<&String, &String>> = expected
        .iter()
        .map(|(n, e)| match e {
            Expected::Path(p) => Some((n, p)),
            _ => None,
        })
        .collect();
    let Some(json) = paths.and_then(|p| serde_json::to_string_pretty(&p).ok()) else {
        return;
    };
    // Written aside and moved in place, so a reader never sees half of it.
    let tmp = file.with_extension("json.tmp");
    if let Some(dir) = file.parent() {
        if std::fs::create_dir_all(dir).is_ok() && std::fs::write(&tmp, json).is_ok() {
            let _ = std::fs::rename(&tmp, file);
        }
    }
}

impl Evaluation {
    /// Starts evaluating `names` at `commit`, unless they're remembered.
    pub fn start(root: PathBuf, names: Vec<String>, commit: String) -> Self {
        let file = cache_file(&commit);
        if let Some(done) = file.as_deref().and_then(|f| recall(f, &names)) {
            return Evaluation {
                pending: None,
                done: Some(done),
            };
        }
        let pending = std::thread::spawn(move || {
            let expected = evaluate_these(&root, &names, &commit);
            if let Some(file) = file {
                remember(&file, &expected);
            }
            expected
        });
        Evaluation {
            pending: Some(pending),
            done: None,
        }
    }

    /// What each host builds, once worked out; never waits.
    pub fn get(&mut self) -> Option<&BTreeMap<String, Expected>> {
        if self.pending.as_ref().is_some_and(JoinHandle::is_finished) {
            self.done = self.pending.take().and_then(|p| p.join().ok());
        }
        self.done.as_ref()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(n: &[&str]) -> Vec<String> {
        n.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn remembers_only_a_whole_evaluation() {
        let dir = std::env::temp_dir().join(format!("ark-eval-test-{}", std::process::id()));
        let file = dir.join("systems").join("abc.json");
        let path = |p: &str| Expected::Path(p.into());

        // A failure isn't remembered: it may be this machine's.
        let partial = BTreeMap::from([
            ("a".to_string(), path("/a")),
            ("b".to_string(), Expected::Failed("x".into())),
        ]);
        remember(&file, &partial);
        assert!(recall(&file, &names(&["a", "b"])).is_none());

        let whole = BTreeMap::from([("a".to_string(), path("/a")), ("b".to_string(), path("/b"))]);
        remember(&file, &whole);
        let recalled = recall(&file, &names(&["a", "b"])).expect("remembered");
        assert!(matches!(recalled.get("b"), Some(Expected::Path(p)) if p == "/b"));
        // A host it doesn't know (one added since): evaluate again.
        assert!(recall(&file, &names(&["a", "b", "c"])).is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }
}
