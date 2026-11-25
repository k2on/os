//! ark-rollout: what every host should run at the newest commit on main
//! (../default.nix), for `ark push` and Grafana to compare with what each
//! host runs (`ark_system_info`, aspects/defaults/metrics.nix).
//!
//!   ark-rollout <remote> <output.prom> [interval seconds]
//!
//! It asks <remote> for main every `interval` (git ls-remote); for a commit
//! it hasn't seen, it evaluates each host's system at that commit, one at a
//! time (nix eval: nothing is built), writing what it knows to <output.prom>
//! as it goes, in node_exporter's textfile directory. Its log is the
//! journal's, so Loki has it. One day CI does this, publishing the same.
use std::time::{Duration, SystemTime, UNIX_EPOCH};

mod eval;
mod metrics;

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (remote, output) = match args.as_slice() {
        [r, o] | [r, o, _] => (r.clone(), std::path::PathBuf::from(o)),
        _ => {
            eprintln!("usage: ark-rollout <remote> <output.prom> [interval seconds]");
            std::process::exit(2);
        }
    };
    let interval = Duration::from_secs(args.get(2).and_then(|s| s.parse().ok()).unwrap_or(30));
    let mut seen: Option<String> = None;
    loop {
        match eval::main_commit(&remote) {
            Ok(commit) if seen.as_deref() != Some(commit.as_str()) => {
                eprintln!("ark-rollout: {} is new on main, evaluating its hosts", &commit[..7.min(commit.len())]);
                let since = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
                let mut rollout = metrics::Rollout { commit: commit.clone(), since, hosts: vec![], done: false, error: None };
                write(&output, &rollout);
                match eval::hosts(&remote, &commit) {
                    Ok(hosts) => {
                        for host in hosts {
                            let result = eval::system(&remote, &commit, &host);
                            match &result {
                                Ok(path) => eprintln!("ark-rollout: {host} runs {path} at it"),
                                Err(e) => eprintln!("ark-rollout: {host} doesn't evaluate: {e}"),
                            }
                            rollout.hosts.push((host, result.map_err(|e| e.to_string())));
                            write(&output, &rollout);
                        }
                    }
                    Err(e) => {
                        eprintln!("ark-rollout: no hosts at it: {e}");
                        rollout.error = Some(e.to_string());
                    }
                }
                rollout.done = true;
                write(&output, &rollout);
                seen = Some(commit);
            }
            Ok(_) => {}
            Err(e) => eprintln!("ark-rollout: asking for main: {e}"),
        }
        std::thread::sleep(interval);
    }
}

fn write(output: &std::path::Path, rollout: &metrics::Rollout) {
    if let Err(e) = metrics::write(output, &metrics::render(rollout)) {
        eprintln!("ark-rollout: writing {}: {e}", output.display());
    }
}
