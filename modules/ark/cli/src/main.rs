//! ark: the CLI for this repository.
//!
//! Repo-wide commands live here (infra, secrets). Each service can add its
//! own under `ark service <name> ...` by shipping services/<name>/cli/mod.rs;
//! build.rs finds those, there is no list to maintain. Everything shells out
//! to the tools already in the dev shell: nix, sops, git.
mod hosts;
mod infra;
mod secrets;
mod service;
mod usb;
mod util;
mod services {
    include!(concat!(env!("OUT_DIR"), "/services.rs"));
}

use anyhow::Result;
use clap::{Arg, ArgAction, Command};
use clap_complete::CompleteEnv;

use service::Ctx;

fn main() {
    // Shell completion. `COMPLETE=zsh ark` prints a shim for the shell to
    // source (the package installs it under share/zsh/site-functions); the
    // shim then runs `ark` with COMPLETE set to ask for the candidates, so
    // completions always match the binary, down to the linked banks' names.
    CompleteEnv::with_factory(cli).complete();
    if let Err(e) = run() {
        eprintln!("ark: {e:#}");
        std::process::exit(1);
    }
}

fn cli() -> Command {
    let services = services::all();
    let service = Command::new("service")
        .about("A service's own commands, run here against the repo")
        .long_about(
            "A service's own commands, run here against the repo (linking accounts, entering secrets), \
             so it can be set up before its host is deployed. Each service ships them in \
             modules/ark/services/<name>/cli/mod.rs.",
        )
        .subcommand_required(true)
        .arg_required_else_help(true)
        .subcommands(services.iter().map(|s| (s.command)().name(s.name).about(s.about)));

    Command::new("ark")
        .about("CLI for the Koon Family Operating System")
        .version(env!("CARGO_PKG_VERSION"))
        .subcommand_required(true)
        .arg_required_else_help(true)
        .subcommand(Command::new("plan").about("Plan out internet infra"))
        .subcommand(Command::new("push").about("Generate internet infra"))
        .subcommand(Command::new("destroy").about("Destroy internet infra"))
        .subcommand(Command::new("hosts").about("List the hosts, how to reach them, and the services each runs"))
        .subcommand(
            Command::new("secrets")
                .about("Create missing secrets, rekey the ones whose recipients changed")
                .long_about(
                    "List every secret declared in nix (modules/ark/lib/secrets.nix); create the missing \
                     ones (generated or prompted for), rekey the ones whose recipients changed. Creating \
                     never decrypts; rekeying decrypts that file once.",
                )
                .arg(
                    Arg::new("dry-run")
                        .short('n')
                        .long("dry-run")
                        .action(ArgAction::SetTrue)
                        .help("Only list what is missing or stale, change nothing"),
                ),
        )
        .subcommand(
            Command::new("sops")
                .about("Run sops in secrets/vars with the yubikey's identity")
                .long_about(
                    "Run sops in secrets/vars with the yubikey's identity, for looking at or editing a \
                     secret by hand: `ark sops money_plaid_chase.yaml`, `ark sops -d infra.yaml`. Asks for \
                     the yubikey if it is not plugged in.",
                )
                .arg(
                    Arg::new("args")
                        .num_args(1..)
                        .trailing_var_arg(true)
                        .allow_hyphen_values(true)
                        .value_name("SOPS ARGS")
                        .help("Passed to sops as they are"),
                ),
        )
        .subcommand(service)
}

fn run() -> Result<()> {
    let matches = cli().get_matches();
    let ctx = Ctx::discover()?;
    match matches.subcommand() {
        Some(("plan", _)) => infra::run(&ctx, "plan"),
        Some(("push", _)) => infra::run(&ctx, "apply"),
        Some(("destroy", _)) => infra::run(&ctx, "destroy"),
        Some(("hosts", _)) => hosts::list(&ctx),
        Some(("secrets", m)) => secrets::run(&ctx, m.get_flag("dry-run")),
        Some(("sops", m)) => {
            let args: Vec<&String> = m.get_many::<String>("args").expect("num_args(1..)").collect();
            util::status(ctx.sops_decrypting()?.args(args).current_dir(secrets::vars_dir(&ctx)), "sops")
        }
        Some(("service", m)) => {
            let (name, m) = m.subcommand().expect("subcommand_required");
            let svc = services::all().into_iter().find(|s| s.name == name).expect("clap only accepts known services");
            (svc.run)(&ctx, m)
        }
        _ => unreachable!("subcommand_required"),
    }
}
