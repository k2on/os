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
                    "sivrad-llm: upstream {}: {}",
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
                Response::from_parts(parts, body.boxed())
            }
            Err(e) => {
                eprintln!("sivrad-llm: upstream: {e}");
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
                eprintln!("sivrad-llm: upstream error body cut short: {e}");
                break;
            }
        }
    }
    Bytes::from(out)
}

/// Kimi K3's channel markers, which Tinfoil's Responses API lets through
/// in its text. Fed back as history they multiply (the model sees them as
/// the way to talk), so they come out of every assistant text on the way
/// up; the channel takes them out of answers on the way down.
const MARKERS: [&str; 4] = ["<|open|> response", "<|close|> response", "<|open|>", "<|close|>"];

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

/// What the upstream needs changed in a request: `model` set to the
/// upstream's name when one is configured, `developer` messages (what
/// Codex sends its instructions as) relabelled `system`, which open-model
/// servers know (the two roles mean the same), and the model's own channel
/// markers taken out of its earlier messages. Anything that is not a JSON
/// object passes through untouched.
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
        for item in items {
            if item["role"] == "developer" {
                item["role"] = Value::from("system");
                changed = true;
            }
            if item["role"] == "assistant" && clean_item(item) {
                changed = true;
            }
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
        "sivrad-llm: {} -> {}{}",
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
                eprintln!("sivrad-llm: accept: {e}");
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

    #[test]
    fn adapts_model_and_developer_role_only() {
        let out = adapt(
            Bytes::from(r#"{"model":"sivrad","input":[{"role":"developer","content":"x"},{"role":"user","content":"y"}]}"#),
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
            .body(Full::new(Bytes::from(r#"{"model":"sivrad","stream":true}"#)))
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
