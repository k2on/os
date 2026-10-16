//! llm-proxy: a loopback HTTP proxy in front of an OpenAI-compatible model
//! API, for clients that should not hold the key (Codex, here).
//!
//! A client speaks the OpenAI API to this address with no key. This
//! forwards each request to the upstream with the real key in the
//! Authorization header (and, when configured, the real model name in the
//! body), and streams the answer back. Where the model runs is therefore
//! one environment variable, and the client's configuration never knows.
//!
//! On the way it adapts the conversation for open models (proxy.rs):
//! `developer` messages become `system`, Kimi's channel markers come out
//! both ways, and old tool outputs in a long session are cut to their
//! opening. Each answer's token usage, cached share included, goes to the
//! journal.
//!
//! Environment:
//!   LLM_PROXY_LISTEN     address to serve on (default 127.0.0.1:4000)
//!   LLM_PROXY_UPSTREAM   origin to forward to, the path kept as is
//!                        (e.g. http://127.0.0.1:3301: /v1/responses goes to
//!                        http://127.0.0.1:3301/v1/responses)
//!   LLM_PROXY_MODEL      the upstream model name, put in every request's
//!                        `model` (unset: the request's own goes through)
//!   LLM_PROXY_KEY_FILE   file holding the upstream key (default: `key` in
//!                        $CREDENTIALS_DIRECTORY, systemd's LoadCredential);
//!                        empty or missing: no Authorization header is added

mod proxy;

use std::sync::Arc;

use proxy::Proxy;

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.trim().is_empty())
}

#[tokio::main]
async fn main() {
    let key_file = env("LLM_PROXY_KEY_FILE").or_else(|| {
        env("CREDENTIALS_DIRECTORY").map(|dir| format!("{dir}/key"))
    });
    let key = match &key_file {
        Some(file) => match std::fs::read_to_string(file) {
            Ok(key) => key.trim().to_owned(),
            Err(e) => {
                eprintln!("llm-proxy: {file}: {e}; forwarding without a key");
                String::new()
            }
        },
        None => String::new(),
    };
    let upstream = env("LLM_PROXY_UPSTREAM").unwrap_or_else(|| "http://127.0.0.1:3301".into());
    let proxy = match Proxy::new(&upstream, env("LLM_PROXY_MODEL"), key) {
        Ok(p) => Arc::new(p),
        Err(e) => {
            eprintln!("llm-proxy: {e}");
            std::process::exit(78);
        }
    };
    let listen = env("LLM_PROXY_LISTEN").unwrap_or_else(|| "127.0.0.1:4000".into());
    if let Err(e) = proxy::serve(proxy, &listen).await {
        eprintln!("llm-proxy: serving on {listen}: {e}");
        std::process::exit(1);
    }
}
