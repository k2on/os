//! Two HTTP/1.1 servers, JSON both ways.
//!
//! The phone's (serve_phone, on the tailnet):
//!
//!   GET  /health -> { ok: true, oidc: { issuer, client_id } }   (no auth)
//!   POST /ask { conversation, text, tools?, locked? }
//!   POST /tool_result { conversation, id, ok, result }
//!
//! Both POSTs need `Authorization: Bearer <Kanidm access token>` of a person
//! in the identity table (401 / 403), take at most 64 KiB (413), and are held
//! until the agent answers: 200 { type: "reply", text } or
//! 200 { type: "tool_call", id, name, arguments } (the phone runs the tool and
//! posts its result to /tool_result), 504 after SIVRAD_TIMEOUT_MS, or 409
//! when a newer request for the same conversation replaces it.
//!
//! The agent's (serve_mcp, on loopback): `POST /mcp` with one JSON-RPC
//! message, answered with its JSON-RPC response, or 202 for a notification
//! (mcp.rs). No server-to-client stream: `GET /mcp` is 405.

use std::convert::Infallible;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use http_body_util::{BodyExt, Full, LengthLimitError, Limited};
use hyper::body::{Bytes, Incoming};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{header, Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use serde_json::{json, Value};
use tokio::net::TcpListener;

use crate::codex::{self, Event, Source};
use crate::mcp;
use crate::oidc::{bearer, AuthError};
use crate::state::{Answer, Outcome, State};

const MAX_BODY: usize = 64 * 1024;
const MAX_TEXT: usize = 8000;

/// Serves `handler` on `listen`, one task per connection, for good.
async fn serve<H, F>(listen: &str, what: &str, handler: H) -> std::io::Result<()>
where
    H: Fn(Request<Incoming>) -> F + Clone + Send + Sync + 'static,
    F: Future<Output = Answer> + Send,
{
    let listener = TcpListener::bind(listen).await?;
    eprintln!("sivrad: {what} on {}", listener.local_addr()?);
    loop {
        let stream = match listener.accept().await {
            Ok((stream, _)) => stream,
            Err(e) => {
                eprintln!("sivrad: accept: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            }
        };
        let handler = handler.clone();
        tokio::spawn(async move {
            let service = service_fn(move |req| {
                let handler = handler.clone();
                async move { Ok::<_, Infallible>(respond(handler(req).await)) }
            });
            // Errors here are the client hanging up; nothing to do about them.
            let _ = http1::Builder::new()
                .serve_connection(TokioIo::new(stream), service)
                .await;
        });
    }
}

pub async fn serve_phone(state: Arc<State>, listen: &str) -> std::io::Result<()> {
    serve(listen, "listening for the phone", move |req| {
        let state = state.clone();
        async move { route(&state, req).await }
    })
    .await
}

pub async fn serve_mcp(state: Arc<State>, listen: &str) -> std::io::Result<()> {
    serve(listen, "serving MCP to the agent", move |req| {
        let state = state.clone();
        async move { route_mcp(&state, req).await }
    })
    .await
}

fn respond(answer: Answer) -> Response<Full<Bytes>> {
    let body = if answer.body.is_null() {
        Bytes::new()
    } else {
        Bytes::from(answer.body.to_string())
    };
    let mut response = Response::new(Full::new(body));
    *response.status_mut() =
        StatusCode::from_u16(answer.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        header::HeaderValue::from_static("application/json"),
    );
    response
}

async fn route(state: &Arc<State>, req: Request<Incoming>) -> Answer {
    let path = req.uri().path().to_owned();
    match (req.method(), path.as_str()) {
        (&Method::GET, "/health") => {
            return Answer::ok(json!({
                "ok": true,
                "oidc": { "issuer": state.oidc.issuer, "client_id": state.oidc.client_id },
            }))
        }
        (&Method::POST, "/ask" | "/tool_result") => {}
        _ => return Answer::error(404, "not found"),
    }

    let header = req.headers().get(header::AUTHORIZATION);
    let Some(token) = bearer(header.and_then(|v| v.to_str().ok())) else {
        return Answer::error(401, "unauthorized");
    };
    let user = match state.oidc.username(token).await {
        Ok(user) => user,
        Err(AuthError::Unauthorized) => return Answer::error(401, "unauthorized"),
        Err(AuthError::NotConfigured) => return Answer::error(503, "sign-in is not configured"),
        Err(AuthError::Unavailable(e)) => {
            eprintln!("sivrad: userinfo: {e}");
            return Answer::error(502, "the identity provider is unavailable");
        }
    };
    if !state.people().contains(&user) {
        eprintln!("sivrad: {user} signed in but is not in the identity table");
        return Answer::error(403, "not allowed");
    }

    let body = match read_json(req.into_body()).await {
        Ok(body) => body,
        Err(answer) => return answer,
    };
    if path == "/ask" {
        ask(state, &user, &body).await
    } else {
        tool_result(state, &body).await
    }
}

/// One JSON-RPC message per POST; a notification gets 202 and no body.
async fn route_mcp(state: &Arc<State>, req: Request<Incoming>) -> Answer {
    match (req.method(), req.uri().path()) {
        (&Method::POST, "/mcp") => {}
        (&Method::GET, "/mcp") => return Answer::error(405, "no server stream"),
        (&Method::DELETE, "/mcp") => return Answer { status: 200, body: Value::Null },
        _ => return Answer::error(404, "not found"),
    }
    let message = match read_json(req.into_body()).await {
        Ok(message) => message,
        Err(answer) => return answer,
    };
    match mcp::handle(state, message).await {
        Some(response) => Answer::ok(response),
        None => Answer {
            status: 202,
            body: Value::Null,
        },
    }
}

async fn read_json(body: Incoming) -> Result<Value, Answer> {
    let bytes = match Limited::new(body, MAX_BODY).collect().await {
        Ok(collected) => collected.to_bytes(),
        Err(e) if e.is::<LengthLimitError>() => return Err(Answer::error(413, "body too large")),
        Err(_) => return Err(Answer::error(400, "unreadable body")),
    };
    match serde_json::from_slice::<Value>(&bytes) {
        Ok(v) if v.is_object() => Ok(v),
        _ => Err(Answer::error(400, "body must be a JSON object")),
    }
}

#[derive(Debug, PartialEq)]
pub struct Ask {
    pub conversation: String,
    pub text: String,
    pub tools: Vec<Value>,
    pub locked: bool,
}

#[derive(Debug, PartialEq)]
pub struct ToolResult {
    pub conversation: String,
    pub id: String,
    pub ok: bool,
    pub result: String,
}

fn conversation(body: &Value) -> Result<String, String> {
    match body["conversation"].as_str() {
        Some(c)
            if (1..=64).contains(&c.len())
                && c.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-') =>
        {
            Ok(c.to_owned())
        }
        _ => Err("conversation must match [A-Za-z0-9_-]{1,64}".into()),
    }
}

pub fn parse_ask(body: &Value) -> Result<Ask, String> {
    let conversation = conversation(body)?;
    let text = match body["text"].as_str() {
        Some(t) if !t.trim().is_empty() && t.chars().count() <= MAX_TEXT => t.to_owned(),
        _ => {
            return Err(format!(
                "text must be a non-empty string of at most {MAX_TEXT} characters"
            ))
        }
    };
    let tools = match &body["tools"] {
        Value::Null => vec![],
        Value::Array(tools) if tools.iter().all(Value::is_object) => tools.clone(),
        _ => return Err("tools must be an array of function definitions".into()),
    };
    let locked = match &body["locked"] {
        Value::Null => false,
        Value::Bool(b) => *b,
        _ => return Err("locked must be a boolean".into()),
    };
    Ok(Ask {
        conversation,
        text,
        tools,
        locked,
    })
}

pub fn parse_tool_result(body: &Value) -> Result<ToolResult, String> {
    let conversation = conversation(body)?;
    match (
        body["id"].as_str(),
        body["ok"].as_bool(),
        body["result"].as_str(),
    ) {
        (Some(id), Some(ok), Some(result)) => Ok(ToolResult {
            conversation,
            id: id.to_owned(),
            ok,
            result: result.chars().take(MAX_TEXT).collect(),
        }),
        _ => Err("id and result must be strings and ok a boolean".into()),
    }
}

async fn ask(state: &Arc<State>, user: &str, body: &Value) -> Answer {
    let ask = match parse_ask(body) {
        Ok(ask) => ask,
        Err(e) => return Answer::error(400, &e),
    };
    state.abandon_tool_calls(&ask.conversation);
    let held = state.hold(&ask.conversation);
    eprintln!(
        "sivrad: ask from {user} on {} ({} chars, {} tools)",
        ask.conversation,
        ask.text.chars().count(),
        ask.tools.len()
    );
    codex::run(
        state.clone(),
        Event {
            chat_id: ask.conversation,
            sender: user.to_owned(),
            source: Source::Voice {
                tools: ask.tools,
                locked: ask.locked,
            },
            content: ask.text,
        },
    );
    held.wait().await
}

async fn tool_result(state: &Arc<State>, body: &Value) -> Answer {
    let r = match parse_tool_result(body) {
        Ok(r) => r,
        Err(e) => return Answer::error(400, &e),
    };
    if !state.has_tool_call(&r.conversation, &r.id) {
        return Answer::error(404, "unknown tool call");
    }
    // Hold before handing the agent the result, so a quick answer finds us.
    let held = state.hold(&r.conversation);
    let outcome = if r.ok {
        Outcome::ok(r.result)
    } else {
        Outcome::error(r.result)
    };
    if !state.finish_tool_call(&r.conversation, &r.id, outcome) {
        return Answer::error(404, "unknown tool call");
    }
    held.wait().await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ask_validation() {
        let ok =
            parse_ask(&json!({ "conversation": "c-1_A", "text": "hi", "locked": true })).unwrap();
        assert_eq!(
            ok,
            Ask {
                conversation: "c-1_A".into(),
                text: "hi".into(),
                tools: vec![],
                locked: true
            }
        );
        for bad in [
            json!({ "conversation": "bad id!", "text": "hi" }),
            json!({ "conversation": "x".repeat(65), "text": "hi" }),
            json!({ "conversation": "signal:+1555", "text": "hi" }),
            json!({ "text": "hi" }),
            json!({ "conversation": "c", "text": "  " }),
            json!({ "conversation": "c", "text": "x".repeat(MAX_TEXT + 1) }),
            json!({ "conversation": "c", "text": "hi", "tools": {} }),
            json!({ "conversation": "c", "text": "hi", "tools": ["x"] }),
            json!({ "conversation": "c", "text": "hi", "locked": "yes" }),
        ] {
            assert!(parse_ask(&bad).is_err(), "{bad}");
        }
        assert!(parse_ask(&json!({ "conversation": "c", "text": "é".repeat(MAX_TEXT) })).is_ok());
    }

    #[test]
    fn tool_result_validation_truncates() {
        let r = parse_tool_result(
            &json!({ "conversation": "c", "id": "x", "ok": false, "result": "y".repeat(9000) }),
        )
        .unwrap();
        assert_eq!(r.result.len(), MAX_TEXT);
        assert!(!r.ok);
        assert!(parse_tool_result(
            &json!({ "conversation": "c", "id": "x", "ok": "true", "result": "" })
        )
        .is_err());
    }
}
