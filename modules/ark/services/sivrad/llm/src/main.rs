//! sivrad-llm: the model behind sivrad, as a loopback HTTP proxy.
//!
//! The agent (Codex, ../_codex.nix) speaks the OpenAI chat API to this
//! address with no key and a placeholder model name. This forwards each
//! request to the upstream OpenAI-compatible endpoint with the real key in
//! the Authorization header and the real model name in the body, and
//! streams the answer back unchanged (the agent streams server-sent
//! events). Where the model runs is therefore one environment variable:
//! Tinfoil's attesting proxy today (../_llm.nix), a model on adam's GPU
//! tomorrow, and the agent's configuration never knows.
//!
//! Environment:
//!   SIVRAD_LLM_LISTEN     address to serve on (default 127.0.0.1:4000)
//!   SIVRAD_LLM_UPSTREAM   origin to forward to, the path kept as is
//!                         (e.g. http://127.0.0.1:3301: /v1/chat/completions
//!                         goes to http://127.0.0.1:3301/v1/chat/completions)
//!   SIVRAD_LLM_MODEL      the upstream model name, put in every request's
//!                         `model` (unset: pass the request's own through)
//!   SIVRAD_LLM_KEY_FILE   file holding the upstream key (default: `key` in
//!                         $CREDENTIALS_DIRECTORY, systemd's LoadCredential);
//!                         empty or missing: no Authorization header is added

mod proxy;

use std::sync::Arc;

use proxy::Proxy;

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.trim().is_empty())
}

#[tokio::main]
async fn main() {
    let key_file = env("SIVRAD_LLM_KEY_FILE").or_else(|| {
        env("CREDENTIALS_DIRECTORY").map(|dir| format!("{dir}/key"))
    });
    let key = match &key_file {
        Some(file) => match std::fs::read_to_string(file) {
            Ok(key) => key.trim().to_owned(),
            Err(e) => {
                eprintln!("sivrad-llm: {file}: {e}; forwarding without a key");
                String::new()
            }
        },
        None => String::new(),
    };
    let upstream = env("SIVRAD_LLM_UPSTREAM").unwrap_or_else(|| "http://127.0.0.1:3301".into());
    let proxy = match Proxy::new(&upstream, env("SIVRAD_LLM_MODEL"), key) {
        Ok(p) => Arc::new(p),
        Err(e) => {
            eprintln!("sivrad-llm: {e}");
            std::process::exit(78);
        }
    };
    let listen = env("SIVRAD_LLM_LISTEN").unwrap_or_else(|| "127.0.0.1:4000".into());
    if let Err(e) = proxy::serve(proxy, &listen).await {
        eprintln!("sivrad-llm: serving on {listen}: {e}");
        std::process::exit(1);
    }
}
