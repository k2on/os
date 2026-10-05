//! sivrad-channel: a Claude Code channel for sivrad, reached from the phone
//! voice assistant (sivrad-android, on the tailnet) and from Signal.
//!
//! Claude Code runs it as a stdio MCP server (newline-delimited JSON-RPC 2.0;
//! stdout carries the protocol, logs go to stderr). It declares the
//! experimental `claude/channel` capability, pushes each phone request to
//! Claude as a `notifications/claude/channel` event and offers the tools
//! `reply`, `phone_tool` and `signal_send` (mcp.rs).
//!
//! The phone talks to it over HTTP (http.rs): `POST /ask` and
//! `POST /tool_result` are held until Claude answers with `reply` or asks the
//! phone to run one of its tools with `phone_tool`. Callers present a Kanidm
//! access token (oidc.rs) for a person listed in the identity table
//! (identity.rs).
//!
//! The same people reach it over Signal (signal.rs): signal-cli's JSON-RPC
//! daemon delivers their messages, and `reply` / `signal_send` answer.
//!
//! Environment:
//!   SIVRAD_LISTEN        HTTP address (default 0.0.0.0:8788)
//!   SIVRAD_TIMEOUT_MS    how long a request is held (default 120000)
//!   SIVRAD_OIDC_ISSUER   e.g. https://id.example.org/oauth2/openid/sivrad
//!   SIVRAD_OIDC_CLIENT   the phone's OAuth2 client id (sivrad)
//!   SIVRAD_PEOPLE_FILE   identity table (default /etc/sivrad/people.json)
//!   SIVRAD_SIGNAL_SOCKET signal-cli's JSON-RPC socket (default /run/sivrad/signal.sock)

mod http;
mod identity;
mod mcp;
mod oidc;
mod signal;
mod state;

use std::sync::Arc;
use std::time::Duration;

use state::{Config, State};

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.trim().is_empty())
}

#[tokio::main]
async fn main() {
    let config = Config {
        timeout: Duration::from_millis(
            env("SIVRAD_TIMEOUT_MS")
                .and_then(|v| v.parse().ok())
                .unwrap_or(120_000),
        ),
        tool_wait: Duration::from_secs(180),
        people_file: env("SIVRAD_PEOPLE_FILE")
            .unwrap_or_else(|| "/etc/sivrad/people.json".into())
            .into(),
        signal_socket: env("SIVRAD_SIGNAL_SOCKET")
            .unwrap_or_else(|| "/run/sivrad/signal.sock".into())
            .into(),
    };
    let issuer = env("SIVRAD_OIDC_ISSUER");
    let client_id = env("SIVRAD_OIDC_CLIENT");
    if issuer.is_none() {
        eprintln!("sivrad: SIVRAD_OIDC_ISSUER is not set; the phone cannot sign in");
    }
    let (state, outgoing) = State::new(config, oidc::Oidc::new(issuer, client_id));
    let state = Arc::new(state);

    tokio::spawn(mcp::write_stdout(outgoing));
    tokio::spawn(signal::Signal::run(state.clone()));

    let listen = env("SIVRAD_LISTEN").unwrap_or_else(|| "0.0.0.0:8788".into());
    let server = state.clone();
    tokio::spawn(async move {
        // Without the HTTP side the session still works; say why and carry on.
        if let Err(e) = http::serve(server, &listen).await {
            eprintln!("sivrad: HTTP server on {listen} failed: {e}");
        }
    });

    mcp::read_stdin(state).await;
}
