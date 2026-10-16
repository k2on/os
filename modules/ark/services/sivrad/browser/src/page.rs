//! The browser as one current tab, read as a distilled page.
//!
//! A read numbers the interactive elements of the page (links, buttons,
//! fields, options) in the page's own JavaScript (distill.js), keeps them
//! on the page under those numbers, and returns the numbers with a short
//! description of each, plus the visible text in slices. Acting by number
//! finds the element again on the page; a read after an action shows the
//! page as it is then.

use serde_json::{json, Value};

use crate::cdp::{self, Session, Target};

const DISTILL: &str = include_str!("distill.js");
/// How much visible text one read returns; `page_read` takes an offset
/// for the rest.
pub const TEXT_SLICE: usize = 6000;

pub struct Browser {
    endpoint: String,
    session: Option<(Target, Session)>,
}

/// A page as the agent sees it.
#[derive(Debug, Clone, PartialEq)]
pub struct Page {
    pub title: String,
    pub url: String,
    pub elements: Vec<String>,
    pub text: String,
    pub text_length: usize,
    pub text_offset: usize,
}

impl Page {
    /// The page as text for the agent.
    pub fn render(&self) -> String {
        let mut out = format!("{}\n{}\n", self.title, self.url);
        if self.elements.is_empty() {
            out.push_str("\n(no interactive elements found)\n");
        } else {
            out.push_str("\nInteractive elements (act on them by number):\n");
            for e in &self.elements {
                out.push_str(e);
                out.push('\n');
            }
        }
        out.push_str("\nVisible text");
        if self.text_length > self.text.chars().count() + self.text_offset || self.text_offset > 0 {
            out.push_str(&format!(
                " (characters {}-{} of {}; page_read with offset for more)",
                self.text_offset,
                self.text_offset + self.text.chars().count(),
                self.text_length
            ));
        }
        out.push_str(":\n");
        out.push_str(&self.text);
        out.push('\n');
        out
    }
}

impl Browser {
    pub fn new(endpoint: &str) -> Self {
        Browser {
            endpoint: endpoint.trim_end_matches('/').to_owned(),
            session: None,
        }
    }

    /// The current tab's session, connecting to the first real tab (or a
    /// new one) when there is none yet.
    async fn session(&mut self) -> Result<&mut Session, String> {
        if self.session.is_none() {
            let targets = cdp::targets(&self.endpoint)?;
            let target = match targets
                .iter()
                .find(|t| !t.url.starts_with("chrome://") && !t.url.starts_with("devtools://"))
                .or(targets.first())
            {
                Some(t) => t.clone(),
                None => cdp::new_target(&self.endpoint, "about:blank")?,
            };
            let session = Session::connect(&target.ws).await?;
            self.session = Some((target, session));
        }
        Ok(&mut self.session.as_mut().expect("just set").1)
    }

    /// Drops the current session; the next call reconnects.
    fn reset(&mut self) {
        self.session = None;
    }

    async fn with_retry<T>(
        &mut self,
        f: impl AsyncFn(&mut Session) -> Result<T, String>,
    ) -> Result<T, String> {
        let session = self.session().await?;
        match f(session).await {
            Ok(v) => Ok(v),
            Err(e) if e.contains("connection closed") || e.contains("DevTools:") => {
                self.reset();
                let session = self.session().await?;
                f(session).await
            }
            Err(e) => Err(e),
        }
    }

    pub async fn read(&mut self, offset: usize) -> Result<Page, String> {
        self.with_retry(async |s| distill(s, offset).await).await
    }

    pub async fn open(&mut self, url: &str) -> Result<Page, String> {
        let url = if url.contains("://") { url.to_owned() } else { format!("https://{url}") };
        self.with_retry(async |s| {
            s.send("Page.navigate", json!({ "url": url })).await?;
            s.settle().await;
            distill(s, 0).await
        })
        .await
    }

    pub async fn click(&mut self, number: u64) -> Result<Page, String> {
        self.with_retry(async |s| {
            check(s.eval(&format!("window.__sivrad.click({number})")).await?)?;
            s.settle().await;
            distill(s, 0).await
        })
        .await
    }

    pub async fn type_text(&mut self, number: u64, text: &str, enter: bool) -> Result<Page, String> {
        let text = text.to_owned();
        self.with_retry(async |s| {
            check(s.eval(&format!("window.__sivrad.focus({number})")).await?)?;
            s.send("Input.insertText", json!({ "text": text })).await?;
            if enter {
                for kind in ["keyDown", "keyUp"] {
                    s.send(
                        "Input.dispatchKeyEvent",
                        json!({ "type": kind, "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13, "text": if kind == "keyDown" { "\r" } else { "" } }),
                    )
                    .await?;
                }
            }
            s.settle().await;
            distill(s, 0).await
        })
        .await
    }

    pub async fn select(&mut self, number: u64, value: &str) -> Result<Page, String> {
        let value = serde_json::to_string(value).unwrap_or_default();
        self.with_retry(async |s| {
            check(s.eval(&format!("window.__sivrad.select({number}, {value})")).await?)?;
            s.settle().await;
            distill(s, 0).await
        })
        .await
    }

    pub async fn scroll(&mut self, down: bool) -> Result<Page, String> {
        let sign = if down { "" } else { "-" };
        self.with_retry(async |s| {
            s.eval(&format!("window.scrollBy(0, {sign}window.innerHeight * 0.8)")).await?;
            tokio::time::sleep(std::time::Duration::from_millis(400)).await;
            distill(s, 0).await
        })
        .await
    }

    pub async fn back(&mut self) -> Result<Page, String> {
        self.with_retry(async |s| {
            s.eval("history.back()").await?;
            s.settle().await;
            distill(s, 0).await
        })
        .await
    }

    /// A JPEG of the viewport, base64.
    pub async fn screenshot(&mut self) -> Result<String, String> {
        self.with_retry(async |s| {
            let shot = s
                .send("Page.captureScreenshot", json!({ "format": "jpeg", "quality": 60 }))
                .await?;
            shot["data"]
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| "no image in the screenshot".to_owned())
        })
        .await
    }

    pub fn tabs(&self) -> Result<Vec<Target>, String> {
        cdp::targets(&self.endpoint)
    }

    /// Makes tab `index` (as `tabs` lists them) the current one.
    pub async fn switch(&mut self, index: usize) -> Result<Page, String> {
        let targets = self.tabs()?;
        let target = targets.get(index).ok_or("no such tab")?.clone();
        let mut session = Session::connect(&target.ws).await?;
        let _ = session.send("Page.bringToFront", json!({})).await;
        self.session = Some((target, session));
        self.read(0).await
    }
}

/// Reads the page through distill.js.
async fn distill(s: &mut Session, offset: usize) -> Result<Page, String> {
    let script = format!("{DISTILL}\nwindow.__sivrad.read({offset}, {TEXT_SLICE})");
    let v = s.eval(&script).await?;
    Ok(Page {
        title: v["title"].as_str().unwrap_or("").to_owned(),
        url: v["url"].as_str().unwrap_or("").to_owned(),
        elements: v["elements"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|e| e.as_str().map(str::to_owned))
            .collect(),
        text: v["text"].as_str().unwrap_or("").to_owned(),
        text_length: v["textLength"].as_u64().unwrap_or(0) as usize,
        text_offset: offset,
    })
}

/// The page-side helpers answer with `"ok"` or an error message.
fn check(v: Value) -> Result<(), String> {
    match v.as_str() {
        Some("ok") => Ok(()),
        Some(e) => Err(e.to_owned()),
        None => Err("the page did not answer".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_a_page() {
        let page = Page {
            title: "Trips".into(),
            url: "https://example.com/trips".into(),
            elements: vec!["[1] link \"Home\"".into(), "[2] button \"Cancel\"".into()],
            text: "Your trips".into(),
            text_length: 10,
            text_offset: 0,
        };
        let text = page.render();
        assert!(text.starts_with("Trips\nhttps://example.com/trips\n\nInteractive elements"));
        assert!(text.contains("[2] button \"Cancel\"\n"));
        assert!(text.ends_with("Visible text:\nYour trips\n"));
        let long = Page { text_length: 20000, text: "x".repeat(6000), ..page };
        assert!(long.render().contains("(characters 0-6000 of 20000; page_read with offset for more)"));
    }
}
