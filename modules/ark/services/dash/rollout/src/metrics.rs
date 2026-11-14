//! The rollout as Prometheus' text format, written whole (a temporary file
//! renamed over the last).
use std::fmt::Write as _;
use std::path::Path;

use crate::Result;

pub struct Rollout {
    pub commit: String,
    /// When it was first seen on main, Unix seconds.
    pub since: u64,
    /// Each host's expected system, or why it has none; in the order done.
    pub hosts: Vec<(String, std::result::Result<String, String>)>,
    /// Every host evaluated (or the host list failed).
    pub done: bool,
    /// Why there are no hosts at all.
    pub error: Option<String>,
}

fn q(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n"))
}

pub fn render(r: &Rollout) -> String {
    let c = q(&r.commit);
    let mut out = String::new();
    let mut help = |name: &str, text: &str| {
        let _ = writeln!(out, "# HELP {name} {text}\n# TYPE {name} gauge");
    };
    help("ark_rollout_commit_timestamp_seconds", "When the commit was first seen on main.");
    help("ark_rollout_evaluated", "Whether every host's system at the commit is known (1) or still being worked out (0).");
    help("ark_rollout_expected_system", "The system a host should run at the commit.");
    help("ark_rollout_eval_failed", "A host whose system doesn't evaluate at the commit.");
    let _ = writeln!(out, "ark_rollout_commit_timestamp_seconds{{commit={c}}} {}", r.since);
    let _ = writeln!(out, "ark_rollout_evaluated{{commit={c}}} {}", u8::from(r.done));
    for (host, result) in &r.hosts {
        match result {
            Ok(path) => {
                let _ = writeln!(out, "ark_rollout_expected_system{{commit={c},target_host={},path={}}} 1", q(host), q(path));
            }
            Err(e) => {
                let _ = writeln!(out, "ark_rollout_eval_failed{{commit={c},target_host={},error={}}} 1", q(host), q(e));
            }
        }
    }
    if let Some(e) = &r.error {
        let _ = writeln!(out, "ark_rollout_eval_failed{{commit={c},target_host=\"\",error={}}} 1", q(e));
    }
    out
}

pub fn write(path: &Path, text: &str) -> Result<()> {
    let tmp = path.with_extension("prom.tmp");
    std::fs::write(&tmp, text)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders() {
        let r = Rollout {
            commit: "abc".into(),
            since: 5,
            hosts: vec![("adam".into(), Ok("/nix/store/x-adam".into())), ("benj".into(), Err("error: \"x\"".into()))],
            done: false,
            error: None,
        };
        let text = render(&r);
        for want in [
            r#"ark_rollout_commit_timestamp_seconds{commit="abc"} 5"#,
            r#"ark_rollout_evaluated{commit="abc"} 0"#,
            r#"ark_rollout_expected_system{commit="abc",target_host="adam",path="/nix/store/x-adam"} 1"#,
            r#"ark_rollout_eval_failed{commit="abc",target_host="benj",error="error: \"x\""} 1"#,
        ] {
            assert!(text.contains(want), "missing {want} in\n{text}");
        }
    }
}
