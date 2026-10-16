//! The forwarding itself: hyper on both sides, one connection per client
//! request, the response body streamed through as it arrives.

use std::convert::Infallible;
use std::sync::Arc;
use std::time::Duration;

use http_body_util::combinators::BoxBody;
use http_body_util::{BodyExt, Full, Limited};
use hyper::body::{Bytes, Incoming};
use hyper::header::{HeaderName, HeaderValue, AUTHORIZATION, CONTENT_LENGTH, CONTENT_TYPE, HOST};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode, Uri};
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::client::legacy::Client;
use hyper_util::rt::{TokioExecutor, TokioIo};
use serde_json::Value;
use tokio::net::TcpListener;

/// Requests are JSON a model can read in one go; a conversation with
/// images stays well under this.
const MAX_REQUEST: usize = 64 * 1024 * 1024;

type Body = BoxBody<Bytes, hyper::Error>;

pub struct Proxy {
    /// Scheme and authority of the upstream, e.g. `http://127.0.0.1:3301`.
    upstream: Uri,
    host: HeaderValue,
    model: Option<String>,
    authorization: Option<HeaderValue>,
    client: Client<HttpConnector, Full<Bytes>>,
}

impl Proxy {
    pub fn new(upstream: &str, model: Option<String>, key: String) -> Result<Self, String> {
        let upstream: Uri = upstream
            .trim_end_matches('/')
            .parse()
            .map_err(|e| format!("upstream {upstream}: {e}"))?;
        let authority = upstream
            .authority()
            .ok_or_else(|| format!("upstream {upstream} has no host"))?;
        if upstream.scheme_str() != Some("http") {
            return Err(format!(
                "upstream {upstream}: only http:// is spoken here (TLS ends at the attesting proxy)"
            ));
        }
        let host = HeaderValue::from_str(authority.as_str()).map_err(|e| e.to_string())?;
        let authorization = if key.is_empty() {
            None
        } else {
            Some(HeaderValue::from_str(&format!("Bearer {key}")).map_err(|e| format!("key: {e}"))?)
        };
        // Model answers stream for minutes; idle, not total, is what the
        // connector times out on.
        let mut connector = HttpConnector::new();
        connector.set_connect_timeout(Some(Duration::from_secs(10)));
        let client = Client::builder(TokioExecutor::new()).build(connector);
        Ok(Proxy {
            upstream,
            host,
            model,
            authorization,
            client,
        })
    }

    /// The upstream request for a client request: same method, path and
    /// headers but ours; the body with the model name swapped in.
    fn rewrite(&self, req: Request<Incoming>) -> (hyper::http::request::Builder, Incoming) {
        let (parts, body) = req.into_parts();
        let path = parts
            .uri
            .path_and_query()
            .map(|p| p.as_str())
            .unwrap_or("/");
        let uri = format!("{}{path}", self.upstream.to_string().trim_end_matches('/'));
        let mut builder = Request::builder().method(parts.method).uri(uri);
        for (name, value) in &parts.headers {
            if name == HOST
                || name == AUTHORIZATION
                || name == CONTENT_LENGTH
                || is_hop_by_hop(name)
            {
                continue;
            }
            builder = builder.header(name, value);
        }
        builder = builder.header(HOST, self.host.clone());
        if let Some(auth) = &self.authorization {
            builder = builder.header(AUTHORIZATION, auth.clone());
        }
        (builder, body)
    }

    async fn forward(&self, req: Request<Incoming>) -> Response<Body> {
        let (builder, body) = self.rewrite(req);
        let bytes = match Limited::new(body, MAX_REQUEST).collect().await {
            Ok(collected) => collected.to_bytes(),
            Err(_) => return plain(StatusCode::PAYLOAD_TOO_LARGE, "request too large"),
        };
        let bytes = adapt(bytes, self.model.as_deref());
        let request = match builder.body(Full::new(bytes)) {
            Ok(r) => r,
            Err(e) => return plain(StatusCode::BAD_REQUEST, &format!("bad request: {e}")),
        };
        match self.client.request(request).await {
            Ok(response) if response.status().is_client_error() || response.status().is_server_error() => {
                // The upstream's complaint goes to the journal too: the agent
                // tends to swallow it, and it names the field it minds.
                let (mut parts, body) = response.into_parts();
                for name in [hyper::header::TRANSFER_ENCODING, hyper::header::CONNECTION] {
                    parts.headers.remove(name);
                }
                let bytes = read_whatever_arrives(body, 1024 * 1024).await;
                eprintln!(
                    "llm-proxy: upstream {}: {}",
                    parts.status,
                    String::from_utf8_lossy(&bytes).chars().take(2000).collect::<String>()
                );
                parts.headers.remove(CONTENT_LENGTH);
                let body = Full::new(bytes).map_err(|never| match never {}).boxed();
                Response::from_parts(parts, body)
            }
            Ok(response) => {
                let (mut parts, body) = response.into_parts();
                for name in [hyper::header::TRANSFER_ENCODING, hyper::header::CONNECTION] {
                    parts.headers.remove(name);
                }
                // The body may come out shorter (markers stripped): its
                // length is no longer the upstream's.
                parts.headers.remove(CONTENT_LENGTH);
                Response::from_parts(parts, Watched::new(body).boxed())
            }
            Err(e) => {
                eprintln!("llm-proxy: upstream: {e}");
                plain(StatusCode::BAD_GATEWAY, &format!("upstream: {e}"))
            }
        }
    }
}

/// Reads a body to its end, or to the first error or the size cap, and
/// keeps what arrived: an error body cut short by the upstream still says
/// what went wrong.
async fn read_whatever_arrives(mut body: Incoming, cap: usize) -> Bytes {
    let mut out = Vec::new();
    while let Some(frame) = body.frame().await {
        match frame {
            Ok(frame) => {
                if let Ok(data) = frame.into_data() {
                    out.extend_from_slice(&data);
                    if out.len() >= cap {
                        break;
                    }
                }
            }
            Err(e) => {
                eprintln!("llm-proxy: upstream error body cut short: {e}");
                break;
            }
        }
    }
    Bytes::from(out)
}

/// A response body passed through untouched, but watched for the usage
/// report at the end of a Responses API answer (`response.completed`, as
/// an event in the stream or the one JSON object), which goes to the
/// journal: how much of the prompt the upstream served from its cache is
/// the number that says whether a long thread costs full price each turn.
struct Watched {
    inner: Incoming,
    tail: Vec<u8>,
}

impl Watched {
    fn new(inner: Incoming) -> Self {
        Watched { inner, tail: Vec::new() }
    }

    fn look(&mut self, data: &[u8]) {
        // Keep the last stretch of the body: the usage block sits near the
        // end, and an event may straddle two frames.
        self.tail.extend_from_slice(data);
        if self.tail.len() > 64 * 1024 {
            let cut = self.tail.len() - 64 * 1024;
            self.tail.drain(..cut);
        }
    }

    fn report(&self) {
        if let Some(usage) = last_usage(&String::from_utf8_lossy(&self.tail)) {
            eprintln!(
                "llm-proxy: usage: input {} (cached {}), output {} (reasoning {})",
                usage["input_tokens"],
                usage["input_tokens_details"]["cached_tokens"],
                usage["output_tokens"],
                usage["output_tokens_details"]["reasoning_tokens"]
            );
        }
    }
}

/// The last `"usage": {...}` object in a stretch of body text.
fn last_usage(text: &str) -> Option<Value> {
    let at = text.rfind("\"usage\"")?;
    let start = at + text[at..].find('{')?;
    let mut depth = 0;
    let mut end = None;
    for (i, c) in text[start..].char_indices() {
        match c {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    end = Some(start + i + 1);
                    break;
                }
            }
            _ => {}
        }
    }
    let usage: Value = serde_json::from_str(&text[start..end?]).ok()?;
    (!usage["input_tokens"].is_null()).then_some(usage)
}

impl hyper::body::Body for Watched {
    type Data = Bytes;
    type Error = hyper::Error;
    fn poll_frame(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Result<hyper::body::Frame<Bytes>, hyper::Error>>> {
        let polled = std::pin::Pin::new(&mut self.inner).poll_frame(cx);
        match polled {
            std::task::Poll::Ready(Some(Ok(frame))) => match frame.into_data() {
                Ok(data) => {
                    self.look(&data);
                    // The model's channel markers out of what it says, so
                    // a client that shows the text as it streams (Codex's
                    // own terminal) never shows them. They arrive whole, as
                    // single tokens, within one event.
                    let data = match strip_markers_bytes(&data) {
                        Some(clean) => clean,
                        None => data,
                    };
                    std::task::Poll::Ready(Some(Ok(hyper::body::Frame::data(data))))
                }
                Err(frame) => std::task::Poll::Ready(Some(Ok(frame))),
            },
            std::task::Poll::Ready(None) => {
                self.report();
                std::task::Poll::Ready(None)
            }
            other => other,
        }
    }
}

/// Kimi K3's channel markers, which Tinfoil's Responses API lets through
/// in its text. Fed back as history they multiply (the model sees them as
/// the way to talk), so they come out of every assistant text on the way
/// up; the channel takes them out of answers on the way down.
const MARKERS: [&str; 4] = ["<|open|> response", "<|close|> response", "<|open|>", "<|close|>"];

/// The markers out of a stretch of response bytes, as they stand in JSON
/// strings (they hold no character JSON escapes); None when there are none.
fn strip_markers_bytes(data: &[u8]) -> Option<Bytes> {
    let text = std::str::from_utf8(data).ok()?;
    if !MARKERS.iter().any(|m| text.contains(m)) {
        return None;
    }
    let mut text = text.to_owned();
    for marker in MARKERS {
        text = text.replace(marker, "");
    }
    Some(Bytes::from(text))
}

fn strip_markers(text: &str) -> Option<String> {
    if !MARKERS.iter().any(|m| text.contains(m)) {
        return None;
    }
    let mut text = text.to_owned();
    for marker in MARKERS {
        text = text.replace(marker, "");
    }
    Some(text.trim().to_owned())
}

/// Takes the markers out of every string under `text` in an item's
/// content, or in the content itself; true when anything changed.
fn clean_item(item: &mut Value) -> bool {
    let mut changed = false;
    match item.get_mut("content") {
        Some(Value::String(s)) => {
            if let Some(clean) = strip_markers(s) {
                *s = clean;
                changed = true;
            }
        }
        Some(Value::Array(parts)) => {
            for part in parts {
                if let Some(Value::String(s)) = part.get_mut("text") {
                    if let Some(clean) = strip_markers(s) {
                        *s = clean;
                        changed = true;
                    }
                }
            }
        }
        _ => {}
    }
    changed
}

/// Context editing, as Claude Code does it: a thread keeps every tool
/// output forever (page snapshots, command output), and re-reading them
/// all is what makes an old thread slow. Only the last few tool outputs
/// stay whole; older ones are cut to their opening, with a note. The
/// agent keeps the conversation and its own messages, and loses only
/// stale dumps it would not act on again.
const RECENT_TOOL_OUTPUTS: usize = 6;
const KEEP_OF_OLD_OUTPUT: usize = 400;

fn is_tool_output(item: &Value) -> bool {
    matches!(
        item["type"].as_str(),
        Some("function_call_output" | "custom_tool_call_output" | "local_shell_call_output")
    )
}

/// Cuts the old tool outputs in `items`; true when anything changed.
fn elide_old_tool_outputs(items: &mut [Value]) -> bool {
    let total = items.iter().filter(|i| is_tool_output(i)).count();
    let mut seen = 0;
    let mut changed = false;
    for item in items.iter_mut() {
        if !is_tool_output(item) {
            continue;
        }
        seen += 1;
        if seen + RECENT_TOOL_OUTPUTS > total {
            break;
        }
        let Some(Value::String(output)) = item.get_mut("output") else {
            continue;
        };
        if output.chars().count() <= KEEP_OF_OLD_OUTPUT * 2 {
            continue;
        }
        let head: String = output.chars().take(KEEP_OF_OLD_OUTPUT).collect();
        *output = format!(
            "{head}\n[... older tool output, {} characters in all, cut to save context; run the tool again if you need it ...]",
            output.chars().count()
        );
        changed = true;
    }
    changed
}

/// What the upstream needs changed in a request: `model` set to the
/// upstream's name when one is configured, `developer` messages (what
/// Codex sends its instructions as) relabelled `system`, which open-model
/// servers know (the two roles mean the same), the model's own channel
/// markers taken out of its earlier messages, and old tool outputs cut.
/// Anything that is not a JSON object passes through untouched.
pub fn adapt(bytes: Bytes, model: Option<&str>) -> Bytes {
    let Ok(mut value) = serde_json::from_slice::<Value>(&bytes) else {
        return bytes;
    };
    let Some(object) = value.as_object_mut() else {
        return bytes;
    };
    let mut changed = false;
    if let Some(model) = model {
        if object.contains_key("model") {
            object.insert("model".into(), Value::from(model));
            changed = true;
        }
    }
    if let Some(items) = object.get_mut("input").and_then(Value::as_array_mut) {
        for item in items.iter_mut() {
            if item["role"] == "developer" {
                item["role"] = Value::from("system");
                changed = true;
            }
            if item["role"] == "assistant" && clean_item(item) {
                changed = true;
            }
        }
        if elide_old_tool_outputs(items) {
            changed = true;
        }
    }
    if changed {
        Bytes::from(value.to_string())
    } else {
        bytes
    }
}

fn is_hop_by_hop(name: &HeaderName) -> bool {
    matches!(
        name.as_str(),
        "connection"
            | "keep-alive"
            | "proxy-authenticate"
            | "proxy-authorization"
            | "te"
            | "trailer"
            | "transfer-encoding"
            | "upgrade"
    )
}

fn plain(status: StatusCode, text: &str) -> Response<Body> {
    let body = Full::new(Bytes::from(text.to_owned()))
        .map_err(|never| match never {})
        .boxed();
    let mut response = Response::new(body);
    *response.status_mut() = status;
    response
        .headers_mut()
        .insert(CONTENT_TYPE, HeaderValue::from_static("text/plain"));
    response
}

pub async fn serve(proxy: Arc<Proxy>, listen: &str) -> std::io::Result<()> {
    let listener = TcpListener::bind(listen).await?;
    eprintln!(
        "llm-proxy: {} -> {}{}",
        listener.local_addr()?,
        proxy.upstream,
        proxy
            .model
            .as_deref()
            .map(|m| format!(" as {m}"))
            .unwrap_or_default()
    );
    loop {
        let stream = match listener.accept().await {
            Ok((stream, _)) => stream,
            Err(e) => {
                eprintln!("llm-proxy: accept: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            }
        };
        let proxy = proxy.clone();
        tokio::spawn(async move {
            let service = service_fn(move |req| {
                let proxy = proxy.clone();
                async move { Ok::<_, Infallible>(proxy.forward(req).await) }
            });
            let _ = http1::Builder::new()
                .serve_connection(TokioIo::new(stream), service)
                .await;
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn markers_come_out_of_response_bytes() {
        let event = br#"data: {"type":"response.output_text.delta","delta":" <|open|> response Hi. <|close|> response"}"#;
        let clean = strip_markers_bytes(event).unwrap();
        assert_eq!(
            &clean[..],
            br#"data: {"type":"response.output_text.delta","delta":"  Hi. "}"#
        );
        assert!(strip_markers_bytes(b"data: {\"delta\":\"plain\"}").is_none());
    }

    #[test]
    fn usage_is_found_at_the_end_of_a_stream() {
        let body = "event: response.output_text.delta\ndata: {\"delta\":\"hi\"}\n\nevent: response.completed\ndata: {\"response\":{\"id\":\"r\",\"usage\":{\"input_tokens\":1200,\"input_tokens_details\":{\"cached_tokens\":1000},\"output_tokens\":40,\"output_tokens_details\":{\"reasoning_tokens\":30}}}}\n\n";
        let usage = last_usage(body).unwrap();
        assert_eq!(usage["input_tokens_details"]["cached_tokens"], 1000);
        assert!(last_usage("data: {\"no\":1}").is_none());
    }

    #[test]
    fn adapts_model_and_developer_role_only() {
        let out = adapt(
            Bytes::from(r#"{"model":"agent","input":[{"role":"developer","content":"x"},{"role":"user","content":"y"}]}"#),
            Some("glm-5-3"),
        );
        let v: Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["model"], "glm-5-3");
        assert_eq!(v["input"][0]["role"], "system");
        assert_eq!(v["input"][1]["role"], "user");
        // no model configured: only the role changes
        let out = adapt(Bytes::from(r#"{"model":"m","input":[{"role":"developer"}]}"#), None);
        let v: Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["model"], "m");
        assert_eq!(v["input"][0]["role"], "system");
        for untouched in [r#"{"messages":[]}"#, "[1,2]", "not json", r#"{"input":"plain"}"#] {
            assert_eq!(adapt(Bytes::from(untouched), Some("x")), Bytes::from(untouched));
        }
    }

    #[test]
    fn old_tool_outputs_are_cut_recent_ones_kept() {
        let big = "x".repeat(5000);
        let mut items: Vec<Value> = (0..10)
            .map(|i| json!({ "type": "function_call_output", "call_id": format!("c{i}"), "output": big }))
            .collect();
        items.push(json!({ "type": "message", "role": "user", "content": "next" }));
        let out = adapt(Bytes::from(json!({ "input": items }).to_string()), None);
        let v: Value = serde_json::from_slice(&out).unwrap();
        let outputs: Vec<&str> = v["input"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|i| i["output"].as_str())
            .collect();
        assert_eq!(outputs.len(), 10);
        for cut in &outputs[..4] {
            assert!(cut.len() < 600, "old output should be cut, got {} chars", cut.len());
            assert!(cut.contains("5000 characters in all"));
        }
        for kept in &outputs[4..] {
            assert_eq!(kept.len(), 5000);
        }
        // small old outputs stay as they are
        let small: Vec<Value> = (0..10)
            .map(|i| json!({ "type": "function_call_output", "call_id": format!("c{i}"), "output": "ok" }))
            .collect();
        let body = json!({ "input": small }).to_string();
        assert_eq!(adapt(Bytes::from(body.clone()), None), Bytes::from(body));
    }

    #[test]
    fn strips_the_models_markers_from_its_history() {
        let out = adapt(
            Bytes::from(
                r#"{"input":[
                    {"role":"assistant","content":[{"type":"output_text","text":" <|open|> response  <|open|> response Checking. <|close|> response <|close|> response"}]},
                    {"role":"assistant","content":" <|open|> response <|close|> response"},
                    {"role":"user","content":[{"type":"input_text","text":"keep <|open|> as typed"}]}
                ]}"#,
            ),
            None,
        );
        let v: Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["input"][0]["content"][0]["text"], "Checking.");
        assert_eq!(v["input"][1]["content"], "");
        assert_eq!(v["input"][2]["content"][0]["text"], "keep <|open|> as typed");
        assert_eq!(strip_markers("plain"), None);
    }

    #[test]
    fn upstream_must_be_plain_http_with_a_host() {
        assert!(Proxy::new("https://inference.tinfoil.sh", None, String::new()).is_err());
        assert!(Proxy::new("/v1", None, String::new()).is_err());
        assert!(Proxy::new("http://127.0.0.1:3301/", None, String::new()).is_ok());
    }

    /// A fake upstream checks what arrives and streams two chunks back.
    #[tokio::test]
    async fn forwards_with_key_and_model_and_streams() {

        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let upstream_addr = upstream.local_addr().unwrap();
        tokio::spawn(async move {
            let (stream, _) = upstream.accept().await.unwrap();
            let service = service_fn(|req: Request<Incoming>| async move {
                assert_eq!(req.uri().path(), "/v1/chat/completions");
                assert_eq!(req.headers()[AUTHORIZATION], "Bearer tf-key");
                assert_eq!(req.headers()[HOST], upstream_addr.to_string());
                assert!(req.headers().get("x-forwarded").is_some());
                let body: Value =
                    serde_json::from_slice(&req.into_body().collect().await.unwrap().to_bytes()).unwrap();
                assert_eq!(body["model"], "glm-5-3");
                assert_eq!(body["stream"], true);
                let body = Chunks::new(vec!["data: one\n\n", "data: [DONE]\n\n"]).boxed();
                Ok::<_, Infallible>(
                    Response::builder()
                        .header(CONTENT_TYPE, "text/event-stream")
                        .body(body)
                        .unwrap(),
                )
            });
            http1::Builder::new()
                .serve_connection(TokioIo::new(stream), service)
                .await
                .unwrap();
        });

        let proxy = Arc::new(
            Proxy::new(&format!("http://{upstream_addr}"), Some("glm-5-3".into()), "tf-key".into())
                .unwrap(),
        );
        let front = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let front_addr = front.local_addr().unwrap();
        drop(front);
        let listen = front_addr.to_string();
        tokio::spawn(async move { serve(proxy, &listen).await.unwrap() });
        tokio::time::sleep(Duration::from_millis(100)).await;

        let client: Client<HttpConnector, Full<Bytes>> =
            Client::builder(TokioExecutor::new()).build_http();
        let request = Request::builder()
            .method("POST")
            .uri(format!("http://{front_addr}/v1/chat/completions"))
            .header(AUTHORIZATION, "Bearer should-be-replaced")
            .header("x-forwarded", "kept")
            .header(CONTENT_TYPE, "application/json")
            .body(Full::new(Bytes::from(r#"{"model":"agent","stream":true}"#)))
            .unwrap();
        let response = client.request(request).await.unwrap();
        assert_eq!(response.status(), 200);
        assert_eq!(response.headers()[CONTENT_TYPE], "text/event-stream");
        let body = response.into_body().collect().await.unwrap().to_bytes();
        assert_eq!(&body[..], b"data: one\n\ndata: [DONE]\n\n");
    }

    /// A body that yields its chunks one frame at a time, as a streaming
    /// upstream would, without pulling in a streams crate.
    struct Chunks(std::collections::VecDeque<&'static str>);

    impl Chunks {
        fn new(chunks: Vec<&'static str>) -> Self {
            Chunks(chunks.into())
        }
    }

    impl hyper::body::Body for Chunks {
        type Data = Bytes;
        type Error = Infallible;
        fn poll_frame(
            mut self: std::pin::Pin<&mut Self>,
            _: &mut std::task::Context<'_>,
        ) -> std::task::Poll<Option<Result<hyper::body::Frame<Bytes>, Infallible>>> {
            std::task::Poll::Ready(
                self.0
                    .pop_front()
                    .map(|c| Ok(hyper::body::Frame::data(Bytes::from(c)))),
            )
        }
    }
}

#[cfg(test)]
mod error_tests {
    use super::*;

    /// An upstream 400 reaches the client with its body, and the log.
    #[tokio::test]
    async fn upstream_errors_pass_through() {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let upstream_addr = upstream.local_addr().unwrap();
        tokio::spawn(async move {
            let (stream, _) = upstream.accept().await.unwrap();
            let service = service_fn(|_req: Request<Incoming>| async move {
                Ok::<_, Infallible>(
                    Response::builder()
                        .status(400)
                        .header(CONTENT_TYPE, "application/json")
                        .body(Full::new(Bytes::from(r#"{"error":{"message":"bad effort"}}"#)))
                        .unwrap(),
                )
            });
            http1::Builder::new()
                .serve_connection(TokioIo::new(stream), service)
                .await
                .unwrap();
        });
        let proxy = Arc::new(Proxy::new(&format!("http://{upstream_addr}"), None, String::new()).unwrap());
        let front = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let front_addr = front.local_addr().unwrap();
        drop(front);
        let listen = front_addr.to_string();
        tokio::spawn(async move { serve(proxy, &listen).await.unwrap() });
        tokio::time::sleep(Duration::from_millis(100)).await;

        let client: Client<HttpConnector, Full<Bytes>> = Client::builder(TokioExecutor::new()).build_http();
        let request = Request::builder()
            .method("POST")
            .uri(format!("http://{front_addr}/v1/responses"))
            .body(Full::new(Bytes::from(r#"{"model":"x"}"#)))
            .unwrap();
        let response = client.request(request).await.unwrap();
        assert_eq!(response.status(), 400);
        let body = response.into_body().collect().await.unwrap().to_bytes();
        assert_eq!(&body[..], br#"{"error":{"message":"bad effort"}}"#);
    }
}
