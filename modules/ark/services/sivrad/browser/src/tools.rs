//! The tools as the agent sees them, and what each does with the browser.

use serde_json::{json, Value};

use crate::page::Browser;

pub const INSTRUCTIONS: &str = "\
The real browser (Chromium on its own screen, which people can watch) as compact tools. page_open or page_read gives the page distilled: title, address, the interactive elements numbered, and the visible text in slices. Act by number: page_click, page_type (clears the field, types, optionally presses Enter), page_select. Numbers change with every read, so act on the latest read. page_screenshot only when the text is not enough (a visual-only widget, a CAPTCHA). Prefer these over the Playwright tools; they cost a fraction of the context.";

pub fn list() -> Value {
    let page = "the page afterwards: title, address, numbered interactive elements, visible text";
    json!([
        { "name": "page_open", "description": format!("Open a URL in the browser's current tab and return {page}."),
          "inputSchema": { "type": "object", "properties": { "url": { "type": "string" } }, "required": ["url"] } },
        { "name": "page_read", "description": format!("Read the current page: {page}. Visible text comes in slices of {} characters; pass offset for the next slice.", crate::page::TEXT_SLICE),
          "inputSchema": { "type": "object", "properties": { "offset": { "type": "integer", "description": "Character offset into the visible text (default 0)" } } } },
        { "name": "page_click", "description": format!("Click element [number] from the latest read and return {page}."),
          "inputSchema": { "type": "object", "properties": { "number": { "type": "integer" } }, "required": ["number"] } },
        { "name": "page_type", "description": format!("Clear field [number], type text into it, optionally press Enter, and return {page}."),
          "inputSchema": { "type": "object", "properties": { "number": { "type": "integer" }, "text": { "type": "string" }, "enter": { "type": "boolean", "description": "Press Enter after typing (default false)" } }, "required": ["number", "text"] } },
        { "name": "page_select", "description": format!("Choose an option (by its text or value) in select [number] and return {page}."),
          "inputSchema": { "type": "object", "properties": { "number": { "type": "integer" }, "value": { "type": "string" } }, "required": ["number", "value"] } },
        { "name": "page_scroll", "description": format!("Scroll the page by most of a screen and return {page}."),
          "inputSchema": { "type": "object", "properties": { "direction": { "type": "string", "enum": ["down", "up"] } } } },
        { "name": "page_back", "description": format!("Go back one page in history and return {page}."),
          "inputSchema": { "type": "object", "properties": {} } },
        { "name": "page_screenshot", "description": "A picture of the current viewport, for when the text is not enough.",
          "inputSchema": { "type": "object", "properties": {} } },
        { "name": "page_tabs", "description": "List the browser's tabs, numbered from 0, with the current one's address.",
          "inputSchema": { "type": "object", "properties": {} } },
        { "name": "page_switch", "description": format!("Make tab [index] (as page_tabs lists them) the current one and return {page}."),
          "inputSchema": { "type": "object", "properties": { "index": { "type": "integer" } }, "required": ["index"] } }
    ])
}

fn number(args: &Value, key: &str) -> Result<u64, String> {
    args[key]
        .as_u64()
        .or_else(|| args[key].as_str().and_then(|s| s.trim().parse().ok()))
        .ok_or_else(|| format!("{key} must be a number from the latest read"))
}

fn string(args: &Value, key: &str) -> Result<String, String> {
    args[key]
        .as_str()
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("{key} must be a non-empty string"))
}

fn text(s: String) -> Vec<Value> {
    vec![json!({ "type": "text", "text": s })]
}

pub async fn call(browser: &mut Browser, name: &str, args: &Value) -> Result<Vec<Value>, String> {
    let page = match name {
        "page_open" => browser.open(&string(args, "url")?).await?,
        "page_read" => browser.read(args["offset"].as_u64().unwrap_or(0) as usize).await?,
        "page_click" => browser.click(number(args, "number")?).await?,
        "page_type" => {
            let typed = args["text"].as_str().unwrap_or("").to_owned();
            browser
                .type_text(number(args, "number")?, &typed, args["enter"].as_bool().unwrap_or(false))
                .await?
        }
        "page_select" => browser.select(number(args, "number")?, &string(args, "value")?).await?,
        "page_scroll" => browser.scroll(args["direction"].as_str().map(str::trim) != Some("up")).await?,
        "page_back" => browser.back().await?,
        "page_screenshot" => {
            let data = browser.screenshot().await?;
            return Ok(vec![json!({ "type": "image", "data": data, "mimeType": "image/jpeg" })]);
        }
        "page_tabs" => {
            let tabs = browser.tabs()?;
            let lines: Vec<String> = tabs
                .iter()
                .enumerate()
                .map(|(i, t)| format!("[{i}] {}  {}", t.title, t.url))
                .collect();
            return Ok(text(if lines.is_empty() { "no tabs".into() } else { lines.join("\n") }));
        }
        "page_switch" => browser.switch(number(args, "index")? as usize).await?,
        _ => return Err(format!("unknown tool: {name}")),
    };
    Ok(text(page.render()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tools_are_listed_with_schemas() {
        let tools = list();
        let names: Vec<&str> = tools.as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(names[0], "page_open");
        assert_eq!(names.len(), 10);
        for t in tools.as_array().unwrap() {
            assert_eq!(t["inputSchema"]["type"], "object");
        }
    }

    #[test]
    fn arguments_are_checked() {
        assert_eq!(number(&json!({ "number": " 3 " }), "number"), Ok(3));
        assert!(number(&json!({ "number": "x" }), "number").is_err());
        assert_eq!(string(&json!({ "url": " a " }), "url"), Ok("a".into()));
        assert!(string(&json!({ "url": "  " }), "url").is_err());
    }
}
