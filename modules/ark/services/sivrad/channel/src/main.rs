//! sivrad-channel: the front of the sivrad assistant, between the people who
//! use it and the agent that answers them (Codex, codex.rs).
//!
//! The phone voice assistant (sivrad-android, on the tailnet) talks to it
//! over HTTP (http.rs): `POST /ask` and `POST /tool_result` are held until
//! the agent answers, or asks the phone to run one of its tools. Callers
//! present a Kanidm access token (oidc.rs) for a person listed in the
//! identity table (identity.rs).
//!
//! The same people reach it over Signal (signal.rs): signal-cli's JSON-RPC
//! daemon delivers their messages, and the answers go back the same way.
//! Signal messages carry files both ways (files.rs): received ones land in
//! the workspace's inbox/, and answers may attach files from the workspace.
//!
//! Each message becomes a turn of the agent, Codex, over its app-server
//! socket (codex.rs). While it runs, the agent calls back over MCP (mcp.rs,
//! HTTP on loopback) for what only this channel can do: `phone_tool`,
//! `reply` with files, `signal_send`.
//!
//! Environment:
//!   SIVRAD_LISTEN          the phone's HTTP address (default 0.0.0.0:8788)
//!   SIVRAD_MCP_LISTEN      the MCP address for the agent (default 127.0.0.1:8789)
//!   SIVRAD_CODEX_SOCKET    the agent's app-server socket (default /run/sivrad/codex.sock)
//!   SIVRAD_THREADS_FILE    where chat -> thread ids are kept
//!                          (default /var/lib/sivrad-channel/threads.json)
//!   SIVRAD_TIMEOUT_MS      how long a phone request is held (default 120000)
//!   SIVRAD_OIDC_ISSUER     e.g. https://id.example.org/oauth2/openid/sivrad-app
//!   SIVRAD_OIDC_CLIENT     the phone's OAuth2 client id (sivrad-app)
//!   SIVRAD_PEOPLE_FILE     identity table (default /etc/sivrad/people.json)
//!   SIVRAD_SIGNAL_SOCKET   signal-cli's JSON-RPC socket (default /run/sivrad-channel/signal.sock)
//!   SIVRAD_WORKSPACE       the agent's workspace (default: the working directory)
//!   SIVRAD_SIGNAL_ATTACHMENTS
//!                          where signal-cli saves attachments
//!                          (default /var/lib/sivrad-channel/signal-cli/attachments)

mod files;
mod codex;
mod http;
mod identity;
mod mcp;
mod oidc;
mod signal;
mod state;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use codex::Codex;
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
            .unwrap_or_else(|| "/run/sivrad-channel/signal.sock".into())
            .into(),
        workspace: env("SIVRAD_WORKSPACE")
            .map(PathBuf::from)
            .or_else(|| std::env::current_dir().ok())
            .unwrap_or_else(|| ".".into()),
        signal_attachments: env("SIVRAD_SIGNAL_ATTACHMENTS")
            .unwrap_or_else(|| "/var/lib/sivrad-channel/signal-cli/attachments".into())
            .into(),
    };
    let issuer = env("SIVRAD_OIDC_ISSUER");
    let client_id = env("SIVRAD_OIDC_CLIENT");
    if issuer.is_none() {
        eprintln!("sivrad: SIVRAD_OIDC_ISSUER is not set; the phone cannot sign in");
    }
    let codex = Codex::new(
        env("SIVRAD_CODEX_SOCKET")
            .unwrap_or_else(|| "/run/sivrad/codex.sock".into())
            .into(),
        &config.workspace.to_string_lossy(),
        env("SIVRAD_THREADS_FILE")
            .unwrap_or_else(|| "/var/lib/sivrad-channel/threads.json".into())
            .into(),
    );
    let state = Arc::new(State::new(config, oidc::Oidc::new(issuer, client_id), codex));

    tokio::spawn(signal::Signal::run(state.clone()));

    let mcp_listen = env("SIVRAD_MCP_LISTEN").unwrap_or_else(|| "127.0.0.1:8789".into());
    let mcp_state = state.clone();
    tokio::spawn(async move {
        if let Err(e) = http::serve_mcp(mcp_state, &mcp_listen).await {
            eprintln!("sivrad: MCP server on {mcp_listen} failed: {e}");
        }
    });

    let listen = env("SIVRAD_LISTEN").unwrap_or_else(|| "0.0.0.0:8788".into());
    if let Err(e) = http::serve_phone(state, &listen).await {
        eprintln!("sivrad: HTTP server on {listen} failed: {e}");
        std::process::exit(1);
    }
}
