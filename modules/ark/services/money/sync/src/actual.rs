//! Talking to actual-import: one JSON request on its stdin, one JSON answer
//! on its stdout (actual-import/src/index.ts). The import uses it, and so does
//! `money-sync actual <op> [json]`, the passthrough the laptop's
//! `ark service money ...` commands run over ssh.
use std::io::Write;
use std::process::{Command, Stdio};

use serde_json::{json, Value};

use crate::config::Config;
use crate::{bail, Result};

pub fn call(cfg: &Config, request: Value) -> Result<Value> {
    let mut child = Command::new(&cfg.actual_import)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|e| format!("{}: {e}", cfg.actual_import.display()))?;
    child.stdin.take().expect("piped stdin").write_all(serde_json::to_string(&request)?.as_bytes())?;
    let out = child.wait_with_output()?;
    if !out.status.success() {
        bail!("actual-import failed ({})", out.status);
    }
    Ok(serde_json::from_slice(&out.stdout).map_err(|e| format!("actual-import: unreadable answer: {e}"))?)
}

/// `money-sync actual <op> [json]`: prints the op's result as JSON.
pub fn run(op: &str, args: &str) -> Result<()> {
    let cfg = Config::load()?;
    let args: Value = serde_json::from_str(args).map_err(|e| format!("the arguments are not JSON: {e}"))?;
    let answer = call(&cfg, json!({ "actual": cfg.actual, "op": op, "args": args }))?;
    println!("{}", serde_json::to_string(&answer["result"])?);
    Ok(())
}
