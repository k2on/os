//! Images for a model that cannot see: each image in a request is put to a
//! second model that can (LLM_PROXY_VISION_MODEL), and its description goes
//! upstream in the image's place.
//!
//! A thread keeps every image it was ever shown and resends the lot each
//! turn, so an image the main model refuses would fail every turn after it,
//! for good. Described instead, it costs the vision model once: the
//! description is kept by the image's SHA-256, in memory and on disk
//! (LLM_PROXY_CACHE), so the next turn sends the same words — the main
//! model's prompt cache still matches — and a restart does not ask again.
//! A description that fails is not kept, and the turn goes on with a note
//! saying so rather than failing too.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

use serde_json::{json, Value};

/// What the vision model is asked, without the conversation: the same
/// image is described the same way whatever it was looked at for, which
/// is what lets one description serve every later turn.
const ASK: &str = "Another model, which cannot see, will read your answer in place of this image. \
Describe the image so it can work from your words alone: what it shows and how it is laid out, \
and every piece of text in it transcribed exactly (labels, fields and their values, numbers, \
buttons, captions). Answer with the description only.";

pub struct Vision {
    pub model: String,
    cache: Option<PathBuf>,
    memo: Mutex<HashMap<String, String>>,
}

impl Vision {
    pub fn new(model: String, cache: Option<PathBuf>) -> Self {
        Vision {
            model,
            cache,
            memo: Mutex::new(HashMap::new()),
        }
    }

    /// The description kept for an image, if any.
    pub fn recall(&self, url: &str) -> Option<String> {
        let key = digest(url);
        if let Some(text) = self.memo.lock().unwrap().get(&key) {
            return Some(text.clone());
        }
        let text = std::fs::read_to_string(self.cache.as_ref()?.join(&key)).ok()?;
        self.memo.lock().unwrap().insert(key, text.clone());
        Some(text)
    }

    pub fn keep(&self, url: &str, text: &str) {
        let key = digest(url);
        if let Some(dir) = &self.cache {
            if let Err(e) = std::fs::write(dir.join(&key), text) {
                eprintln!("llm-proxy: keeping a description in {}: {e}", dir.display());
            }
        }
        self.memo.lock().unwrap().insert(key, text.to_owned());
    }

    /// The Responses API request that asks for one image's description.
    pub fn request(&self, url: &str) -> Value {
        json!({
            "model": self.model,
            "stream": false,
            "reasoning": { "effort": "low" },
            "input": [{
                "role": "user",
                "content": [
                    { "type": "input_text", "text": ASK },
                    { "type": "input_image", "image_url": url },
                ],
            }],
        })
    }
}

fn digest(url: &str) -> String {
    ring::digest::digest(&ring::digest::SHA256, url.as_bytes())
        .as_ref()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// The text of a Responses API answer: its messages' output text.
pub fn answer_text(response: &Value) -> Option<String> {
    let text: String = response["output"]
        .as_array()?
        .iter()
        .filter(|item| item["type"] == "message")
        .filter_map(|item| item["content"].as_array())
        .flatten()
        .filter(|part| part["type"] == "output_text")
        .filter_map(|part| part["text"].as_str())
        .collect();
    let text = crate::proxy::strip_markers(&text).unwrap_or(text);
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_owned())
}

/// Every image in a request's input, each once, in order: in a user's
/// message, or in what a tool gave back (Codex's `view_image`, a
/// screenshot from an MCP tool).
pub fn images(request: &Value) -> Vec<String> {
    fn walk(value: &Value, found: &mut Vec<String>) {
        match value {
            Value::Object(object) => {
                if let (Some("input_image"), Some(url)) = (
                    object.get("type").and_then(Value::as_str),
                    object.get("image_url").and_then(Value::as_str),
                ) {
                    if !found.iter().any(|f| f == url) {
                        found.push(url.to_owned());
                    }
                    return;
                }
                object.values().for_each(|v| walk(v, found));
            }
            Value::Array(items) => items.iter().for_each(|v| walk(v, found)),
            _ => {}
        }
    }
    let mut found = Vec::new();
    if let Some(input) = request.get("input") {
        walk(input, &mut found);
    }
    found
}

/// Puts each image's description where the image was, as the text part
/// the same places take.
pub fn replace(request: &mut Value, model: &str, said: &HashMap<String, Result<String, String>>) {
    fn walk(value: &mut Value, model: &str, said: &HashMap<String, Result<String, String>>) {
        match value {
            Value::Object(object) => {
                let url = match (object.get("type").and_then(Value::as_str), object.get("image_url")) {
                    (Some("input_image"), Some(Value::String(url))) => Some(url.clone()),
                    _ => None,
                };
                if let Some(url) = url {
                    let text = match said.get(&url) {
                        Some(Ok(text)) => format!("[An image, described by {model} since you cannot see images:]\n{text}"),
                        Some(Err(e)) => format!("[An image you cannot see, which {model} could not describe: {e}]"),
                        None => return,
                    };
                    *value = json!({ "type": "input_text", "text": text });
                    return;
                }
                object.values_mut().for_each(|v| walk(v, model, said));
            }
            Value::Array(items) => items.iter_mut().for_each(|v| walk(v, model, said)),
            _ => {}
        }
    }
    if let Some(input) = request.get_mut("input") {
        walk(input, model, said);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> Value {
        json!({ "model": "agent", "input": [
            { "role": "user", "content": [
                { "type": "input_text", "text": "what is this" },
                { "type": "input_image", "image_url": "data:image/png;base64,AAAA" },
            ]},
            { "type": "function_call_output", "call_id": "c1", "output": [
                { "type": "input_image", "image_url": "data:image/jpeg;base64,BBBB" },
            ]},
            { "type": "function_call_output", "call_id": "c2", "output": [
                { "type": "input_image", "image_url": "data:image/png;base64,AAAA" },
            ]},
            { "type": "function_call_output", "call_id": "c3", "output": "plain" },
        ]})
    }

    #[test]
    fn every_image_is_found_once_wherever_it_is() {
        assert_eq!(
            images(&request()),
            ["data:image/png;base64,AAAA", "data:image/jpeg;base64,BBBB"]
        );
        assert!(images(&json!({ "input": "hi" })).is_empty());
        assert!(images(&json!({ "instructions": { "type": "input_image", "image_url": "x" } })).is_empty());
    }

    #[test]
    fn images_become_their_descriptions() {
        let mut request = request();
        let said = HashMap::from([
            ("data:image/png;base64,AAAA".to_owned(), Ok("A cat.".to_owned())),
            ("data:image/jpeg;base64,BBBB".to_owned(), Err("timed out".to_owned())),
        ]);
        replace(&mut request, "kimi-k3", &said);
        assert!(images(&request).is_empty());
        let input = &request["input"];
        assert_eq!(input[0]["content"][0]["text"], "what is this");
        assert_eq!(input[0]["content"][1]["type"], "input_text");
        assert!(input[0]["content"][1]["text"].as_str().unwrap().ends_with("\nA cat."));
        assert!(input[1]["output"][0]["text"].as_str().unwrap().contains("could not describe: timed out"));
        assert_eq!(input[2]["output"][0], input[0]["content"][1]);
        assert_eq!(input[3]["output"], "plain");
    }

    #[test]
    fn descriptions_are_kept_across_restarts() {
        let dir = std::env::temp_dir().join(format!("llm-proxy-vision-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let first = Vision::new("v".into(), Some(dir.clone()));
        assert_eq!(first.recall("data:a"), None);
        first.keep("data:a", "A cat.");
        assert_eq!(first.recall("data:a").as_deref(), Some("A cat."));
        let second = Vision::new("v".into(), Some(dir.clone()));
        assert_eq!(second.recall("data:a").as_deref(), Some("A cat."));
        assert_eq!(second.recall("data:b"), None);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_answer_is_the_messages_text() {
        let response = json!({ "output": [
            { "type": "reasoning", "content": [{ "type": "reasoning_text", "text": "hmm" }] },
            { "type": "message", "content": [{ "type": "output_text", "text": " <|open|> response Text: HELLO 42 " }] },
        ]});
        assert_eq!(answer_text(&response).as_deref(), Some("Text: HELLO 42"));
        assert_eq!(answer_text(&json!({ "output": [] })), None);
    }
}
