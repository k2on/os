//! `ark service sivrad signal ...`: the VM's Signal account.
//!
//! Registering and linking go through the signal-cli daemon in the VM
//! (signal-cli.service, ../_guest.nix), over its JSON-RPC socket, rather
//! than through a second `signal-cli` process: the daemon runs in
//! multi-account mode, which offers `register`, `verify`, `startLink` and
//! `finishLink` (signal-cli-jsonrpc(5); the dispatcher in 0.14 hands them a
//! fresh registration manager), and adds the new account to itself and to
//! every live subscription the moment it is verified or linked. So there is
//! no lock on the data directory to fight over (a separate `signal-cli
//! register` would need the daemon gone, and a non-root user can only kill
//! it and race systemd's restart), and the channel gets the account without
//! a restart.
//!
//! The JSON-RPC calls run in the VM as `socat` on the socket, from a bash
//! coprocess so the connection stays open until the answer arrives (socat
//! would hang up shortly after its stdin ends, and `finishLink` waits for a
//! phone). The daemon receives in on-connection mode, so such a connection
//! is also handed incoming messages for as long as it lasts; they are
//! skipped, and the channel gets its own copy.
//!
//! Each success ends with a backup: signal-cli's data directory, tarred in
//! the VM and stored in the secrets repo (sivrad_signal_account, with the
//! number in sivrad_signal_number), from which a rebuilt VM restores the
//! account.
use std::collections::BTreeMap;
use std::io::Write;
use std::process::{Command, Stdio};

use anyhow::{bail, Context, Result};
use clap::{Arg, ArgMatches, Command as Clap};
use serde::Deserialize;
use serde_json::{json, Value};

use super::people::valid_e164;
use super::{Config, Vm};
use crate::secrets::Manifest;
use crate::service::Ctx;

pub const NUMBER: &str = "sivrad_signal_number";
pub const ACCOUNT: &str = "sivrad_signal_account";

const CAPTCHA_URL: &str = "https://signalcaptchas.org/registration/generate.html";
/// The linked device's name, as the phone lists it.
const DEVICE_NAME: &str = "sivrad";

pub fn command() -> Clap {
    let number = || {
        Arg::new("number")
            .allow_hyphen_values(true)
            .help("The number in E.164, e.g. +15551234567")
    };
    Clap::new("signal")
        .about("The VM's Signal account: register or link it, and back it up")
        .long_about(
            "The VM's Signal account: register a number or link to an existing account, through the \
             signal-cli daemon in the VM (over ssh), then back it up to the secrets repo so a rebuilt \
             VM comes back as the same account. Commit secrets/ and deploy adam afterwards.",
        )
        .subcommand_required(true)
        .arg_required_else_help(true)
        .subcommand(
            Clap::new("register")
                .about("Register a dedicated number (asks for the code Signal texts it)")
                .arg(number().required(true))
                .arg(Arg::new("captcha").long("captcha").value_name("TOKEN").help(format!(
                    "The signalcaptcha://... link, when Signal asks for a captcha: solve it at \
                     {CAPTCHA_URL}, then copy the 'Open Signal' link"
                ))),
        )
        .subcommand(
            Clap::new("verify")
                .about("Finish a registration with the code Signal texted (again)")
                .arg(Arg::new("code").required(true).help("The verification code"))
                .arg(number().long("number").help(
                    "The number being registered; defaults to the one `signal register` saved",
                ))
                .arg(
                    Arg::new("pin")
                        .long("pin")
                        .help("The registration lock PIN, if the number has one"),
                ),
        )
        .subcommand(Clap::new("link").about(
            "Link to an existing Signal account as a device named sivrad (shows a QR code to scan)",
        ))
        .subcommand(Clap::new("backup").about(
            "Save the VM's Signal account to the secrets repo (done after register/verify/link)",
        ))
}

pub fn run(ctx: &Ctx, m: &ArgMatches) -> Result<()> {
    let cfg = Config::load(ctx)?;
    let vm = cfg.vm()?;
    let get = |m: &ArgMatches, name: &str| m.get_one::<String>(name).cloned();
    match m.subcommand() {
        Some(("register", m)) => register(
            ctx,
            &cfg,
            &vm,
            &get(m, "number").expect("required"),
            get(m, "captcha").as_deref(),
        ),
        Some(("verify", m)) => {
            let manifest = Manifest::load(ctx)?;
            let number = match get(m, "number") {
                Some(n) => n,
                None => saved_number(ctx, &manifest)?,
            };
            verify(
                ctx,
                &cfg,
                &vm,
                &manifest,
                &number,
                &get(m, "code").expect("required"),
                get(m, "pin").as_deref(),
            )
        }
        Some(("link", _)) => link(ctx, &cfg, &vm),
        Some(("backup", _)) => backup(ctx, &cfg, &vm, &Manifest::load(ctx)?),
        _ => unreachable!("subcommand_required"),
    }
}

/// An account the daemon has loaded, as `listAccounts` reports it. Numberless
/// accounts have only an ACI (newer signal-cli reports it).
#[derive(Deserialize, Debug, PartialEq)]
pub struct Account {
    pub number: Option<String>,
    #[serde(default)]
    pub aci: Option<String>,
}

impl Account {
    pub fn id(&self) -> &str {
        self.number
            .as_deref()
            .or(self.aci.as_deref())
            .unwrap_or("(unnamed account)")
    }
}

pub fn parse_accounts(result: Value) -> Result<Vec<Account>> {
    serde_json::from_value(result).context("reading signal-cli's account list")
}

/// A JSON-RPC error from signal-cli: its code (-1 is a user error, -5 a rate
/// limit...) and message.
#[derive(Debug)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
}

impl std::fmt::Display for RpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} (signal-cli error {})", self.message, self.code)
    }
}

impl std::error::Error for RpcError {}

/// One JSON-RPC response line: its result, or its error.
pub fn parse_response(line: &str) -> Result<Value> {
    let response: Value = serde_json::from_str(line.trim())
        .with_context(|| format!("signal-cli answered something that is not JSON: {line}"))?;
    if let Some(error) = response.get("error") {
        return Err(RpcError {
            code: error.get("code").and_then(Value::as_i64).unwrap_or(0),
            message: error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("(no message)")
                .to_string(),
        }
        .into());
    }
    Ok(response.get("result").cloned().unwrap_or(Value::Null))
}

pub fn is_captcha_error(e: &anyhow::Error) -> bool {
    e.downcast_ref::<RpcError>()
        .is_some_and(|e| e.message.to_lowercase().contains("captcha"))
}

/// Single-quoted for the remote shell.
pub fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// The bash script that sends one request to the daemon's socket and prints
/// the response carrying `id`, skipping notifications. Exit 3 with a message
/// when the daemon is not there or hangs up.
pub fn rpc_script(socket: &str, id: &str, request: &str) -> String {
    let marker = format!(r#""id":"{id}""#);
    format!(
        r#"set -u
sock={sock}
if [ ! -S "$sock" ]; then
  echo "signal-cli is not running in the VM (no socket at $sock); see journalctl -u signal-cli there" >&2
  exit 3
fi
# socat's stderr is dropped: it complains when killed below.
coproc RPC {{ exec socat - "UNIX-CONNECT:$sock" 2>/dev/null; }}
exec 3<&"${{RPC[0]}}" 4>&"${{RPC[1]}}"
printf '%s\n' {request} >&4
while IFS= read -r line <&3; do
  case $line in
    *{marker}*) printf '%s\n' "$line"; kill "$RPC_PID" 2>/dev/null; exit 0 ;;
  esac
done
echo "signal-cli hung up without answering (or refused the connection to $sock)" >&2
exit 3
"#,
        sock = sh_quote(socket),
        request = sh_quote(request),
        marker = sh_quote(&marker),
    )
}

/// Calls a method of the daemon in the VM and returns its result.
fn rpc(cfg: &Config, vm: &Vm, method: &str, params: Value) -> Result<Value> {
    let id = format!("ark-{}", std::process::id());
    let request = json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params });
    let script = rpc_script(&cfg.signal.socket, &id, &request.to_string());
    let line = vm
        .output(&format!("bash -c {}", sh_quote(&script)))
        .with_context(|| format!("calling {method} on signal-cli in the VM"))?;
    parse_response(&line)
}

pub fn accounts(cfg: &Config, vm: &Vm) -> Result<Vec<Account>> {
    parse_accounts(rpc(cfg, vm, "listAccounts", json!({}))?)
}

/// The channel serves exactly one account, so a second one is refused.
fn refuse_other_account(cfg: &Config, vm: &Vm, number: Option<&str>) -> Result<()> {
    let existing = accounts(cfg, vm)?;
    match (existing.first(), number) {
        (None, _) => Ok(()),
        (Some(a), Some(n)) if existing.len() == 1 && a.number.as_deref() == Some(n) => bail!(
            "{n} is already registered in the VM; `ark service sivrad signal backup` saves it to the \
             secrets repo"
        ),
        (Some(_), _) => bail!(
            "signal-cli in the VM already has {}; sivrad uses exactly one account. To replace it, \
             delete {}/data in the VM, end the daemon so systemd restarts it empty (pkill -f \
             'signal-cli.*daemon') and empty the sivrad_signal_account secret, or the next restart \
             restores the old account",
            existing
                .iter()
                .map(Account::id)
                .collect::<Vec<_>>()
                .join(", "),
            cfg.signal.config_dir
        ),
    }
}

fn register(ctx: &Ctx, cfg: &Config, vm: &Vm, number: &str, captcha: Option<&str>) -> Result<()> {
    if !valid_e164(number) {
        bail!("'{number}' is not an E.164 number: a + and the country code, digits only");
    }
    refuse_other_account(cfg, vm, Some(number))?;

    println!("asking Signal to text a verification code to {number}...");
    let mut params = json!({ "account": number });
    if let Some(captcha) = captcha {
        params["captcha"] = json!(captcha.trim());
    }
    if let Err(e) = rpc(cfg, vm, "register", params) {
        if is_captcha_error(&e) && captcha.is_none() {
            bail!(
                "Signal wants a captcha first. Solve it at\n\n  {CAPTCHA_URL}\n\nthen right-click the \
                 'Open Signal' link, copy it, and run again:\n\n  ark service sivrad signal register \
                 {number} --captcha 'signalcaptcha://...'\n\n({e})"
            );
        }
        return Err(e).context("registering");
    }

    // Saved now so a later `signal verify` knows the number; this is also the
    // run's one decryption of the file the backup below writes to.
    let manifest = Manifest::load(ctx)?;
    store(ctx, &manifest, &[(NUMBER, number.to_string())])?;

    let code = ctx.prompt(&format!("The code Signal texted to {number}"))?;
    let code = code.trim().replace(['-', ' '], "");
    if code.is_empty() {
        bail!("no code entered; finish later with `ark service sivrad signal verify <code>`");
    }
    verify(ctx, cfg, vm, &manifest, number, &code, None)
}

fn saved_number(ctx: &Ctx, manifest: &Manifest) -> Result<String> {
    let number = if manifest.present(ctx, NUMBER) {
        eprintln!("decrypting {NUMBER} (touch the yubikey when it blinks)");
        manifest.read(ctx, NUMBER)?
    } else {
        String::new()
    };
    if number.is_empty() {
        bail!(
            "no registration in progress; run `ark service sivrad signal register <+number>`, or pass --number"
        );
    }
    Ok(number)
}

fn verify(
    ctx: &Ctx,
    cfg: &Config,
    vm: &Vm,
    manifest: &Manifest,
    number: &str,
    code: &str,
    pin: Option<&str>,
) -> Result<()> {
    if !valid_e164(number) {
        bail!("'{number}' is not an E.164 number");
    }
    let mut params = json!({ "account": number, "verificationCode": code });
    if let Some(pin) = pin {
        params["pin"] = json!(pin);
    }
    rpc(cfg, vm, "verify", params).with_context(|| {
        format!(
            "verifying {number}; try the code again with `ark service sivrad signal verify <code> \
             --number {number}` (add --pin if the number has a registration lock)"
        )
    })?;
    println!("{number} is registered; signal-cli in the VM has loaded it.");
    backup(ctx, cfg, vm, manifest)
}

fn link(ctx: &Ctx, cfg: &Config, vm: &Vm) -> Result<()> {
    refuse_other_account(cfg, vm, None)?;
    let started = rpc(cfg, vm, "startLink", json!({}))?;
    let uri = started
        .get("deviceLinkUri")
        .and_then(Value::as_str)
        .context("signal-cli's startLink gave no deviceLinkUri")?
        .to_string();

    println!(
        "On the phone with the account: Signal -> Settings -> Linked devices -> Link a new device, \
         and scan this:\n"
    );
    if !show_qr(&uri) {
        println!("(install qrencode to see a QR code here; or make one from the link)\n");
    }
    println!("  {uri}\n\nWaiting for the phone...");

    let linked = rpc(
        cfg,
        vm,
        "finishLink",
        json!({ "deviceLinkUri": uri, "deviceName": DEVICE_NAME }),
    )?;
    let who = linked
        .get("number")
        .and_then(Value::as_str)
        .unwrap_or("the account");
    println!("linked to {who} as '{DEVICE_NAME}'; signal-cli in the VM has loaded it.");
    backup(ctx, cfg, vm, &Manifest::load(ctx)?)
}

/// Renders the link as a QR code on the terminal with qrencode, when it is
/// on PATH (the ark package carries it).
fn show_qr(uri: &str) -> bool {
    let Ok(mut child) = Command::new("qrencode")
        .args(["-t", "ANSIUTF8"])
        .stdin(Stdio::piped())
        .spawn()
    else {
        return false;
    };
    let wrote = child
        .stdin
        .take()
        .is_some_and(|mut stdin| stdin.write_all(uri.as_bytes()).is_ok());
    child.wait().is_ok_and(|s| s.success()) && wrote
}

/// The script that prints the data directory as a base64 tar.gz. Downloaded
/// attachments, avatars and stickers are caches (and the daemon fetches
/// none); everything else, the account and its keys under data/, is kept.
/// The daemon is frozen meanwhile (SIGSTOP to its cgroup, which `sivrad`
/// may signal as it owns the processes), so its SQLite files are copied in
/// a crash-consistent state, then thawed even if tar fails.
pub fn backup_script(config_dir: &str) -> String {
    format!(
        r#"set -euo pipefail
dir={dir}
if [ ! -d "$dir/data" ]; then
  echo "no Signal account in $dir yet" >&2
  exit 3
fi
cg=$(systemctl show -p ControlGroup --value signal-cli.service 2>/dev/null || true)
pids=
if [ -n "$cg" ] && [ -r "/sys/fs/cgroup$cg/cgroup.procs" ]; then
  pids=$(cat "/sys/fs/cgroup$cg/cgroup.procs")
fi
if [ -n "$pids" ]; then
  trap 'kill -CONT $pids' EXIT
  kill -STOP $pids
fi
tar -C "$dir" --exclude=./attachments --exclude=./avatars --exclude=./stickers -czf - . | base64 -w0
"#,
        dir = sh_quote(config_dir)
    )
}

/// Saves the account in the VM to the secrets repo.
pub fn backup(ctx: &Ctx, cfg: &Config, vm: &Vm, manifest: &Manifest) -> Result<()> {
    let existing = accounts(cfg, vm)?;
    let account = match &existing[..] {
        [one] => one,
        [] => bail!("signal-cli in the VM has no account to back up; register or link one first"),
        _ => bail!(
            "signal-cli in the VM has {} accounts; sivrad uses exactly one",
            existing.len()
        ),
    };
    println!("backing up {} from the VM...", account.id());
    let archive = vm
        .output(&format!(
            "bash -c {}",
            sh_quote(&backup_script(&cfg.signal.config_dir))
        ))
        .context("archiving signal-cli's data directory in the VM")?;
    let archive = archive.trim();
    if archive.is_empty() {
        bail!("the archive of signal-cli's data directory came back empty");
    }
    store(
        ctx,
        manifest,
        &[
            (NUMBER, account.id().to_string()),
            (ACCOUNT, archive.to_string()),
        ],
    )?;
    println!(
        "Saved as {ACCOUNT} ({} KiB) and {NUMBER}. Commit secrets/ and deploy adam: a rebuilt VM \
         then restores this account.",
        archive.len().div_ceil(1024)
    );
    Ok(())
}

/// Stores secrets, one `store` per file they live in.
pub fn store(ctx: &Ctx, manifest: &Manifest, values: &[(&str, String)]) -> Result<()> {
    let mut by_file: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    for (key, value) in values {
        by_file
            .entry(manifest.spec(key)?.file.clone())
            .or_default()
            .insert(key.to_string(), value.clone());
    }
    for (file, values) in by_file {
        manifest
            .store(ctx, &file, &values)
            .with_context(|| format!("storing secrets/vars/{file}.yaml"))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn account_lists() {
        // 0.14: numbers only.
        let listed = parse_response(
            r#"{"jsonrpc":"2.0","result":[{"number":"+15551234567"}],"id":"ark-1"}"#,
        )
        .unwrap();
        let accounts = parse_accounts(listed).unwrap();
        assert_eq!(
            accounts,
            vec![Account {
                number: Some("+15551234567".into()),
                aci: None
            }]
        );
        assert_eq!(accounts[0].id(), "+15551234567");

        // Newer: numberless accounts by ACI.
        let accounts = parse_accounts(json!([{ "number": null, "aci": "1111-aaaa" }])).unwrap();
        assert_eq!(accounts[0].id(), "1111-aaaa");

        assert!(parse_accounts(json!([])).unwrap().is_empty());
        assert!(parse_accounts(json!({ "number": "+1" })).is_err());
    }

    #[test]
    fn responses() {
        assert_eq!(
            parse_response(r#"{"jsonrpc":"2.0","result":{"deviceLinkUri":"sgnl://x"},"id":"a"}"#)
                .unwrap()["deviceLinkUri"],
            "sgnl://x"
        );
        // verify answers with no result at all.
        assert_eq!(
            parse_response(r#"{"jsonrpc":"2.0","id":"a"}"#).unwrap(),
            Value::Null
        );

        let err = parse_response(
            r#"{"jsonrpc":"2.0","error":{"code":-1,"message":"Captcha required for verification, use --captcha CAPTCHA\nTo get the token, go to https://signalcaptchas.org/registration/generate.html","data":null},"id":"a"}"#,
        )
        .unwrap_err();
        assert!(is_captcha_error(&err));
        assert_eq!(err.downcast_ref::<RpcError>().unwrap().code, -1);

        let err = parse_response(
            r#"{"jsonrpc":"2.0","error":{"code":-5,"message":"Rate limit reached"},"id":"a"}"#,
        )
        .unwrap_err();
        assert!(!is_captcha_error(&err));
        assert!(err
            .to_string()
            .contains("Rate limit reached (signal-cli error -5)"));

        assert!(parse_response("socat: E connect(...): No such file").is_err());
    }

    #[test]
    fn quoting() {
        assert_eq!(sh_quote("plain"), "'plain'");
        assert_eq!(sh_quote("it's"), r"'it'\''s'");
        let script = rpc_script("/run/sivrad/signal.sock", "ark-7", r#"{"a":"it's"}"#);
        assert!(script.contains(r#"printf '%s\n' '{"a":"it'\''s"}' >&4"#));
        assert!(script.contains(r#"*'"id":"ark-7"'*)"#));
        assert!(backup_script("/var/lib/sivrad/signal-cli")
            .contains("dir='/var/lib/sivrad/signal-cli'"));
    }
}
