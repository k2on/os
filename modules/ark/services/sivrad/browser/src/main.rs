//! sivrad-browser: the headed browser as a few compact tools, for the agent.
//!
//! Playwright's MCP server hands the model a page as its whole accessibility
//! tree, which on a busy site runs to tens of thousands of tokens a look.
//! This serves the same browser (ungoogled-chromium, through its DevTools
//! port, ../_chrome.nix) as a distilled page instead: title, address, the
//! interactive elements numbered, and the visible text in slices. The
//! model reads a page in a few hundred tokens, acts by number, and a long
//! task no longer fills its context with page dumps.
//!
//! An MCP server on stdio (newline-delimited JSON-RPC 2.0, the subset Codex
//! needs: initialize, ping, tools/list, tools/call), one per agent process,
//! talking to one tab at a time (cdp.rs). The tools (tools.rs):
//!   page_open, page_read, page_click, page_type, page_select, page_scroll,
//!   page_back, page_screenshot, page_tabs, page_switch.
//!
//! Environment:
//!   SIVRAD_CDP   the DevTools endpoint (default http://127.0.0.1:9222)

mod cdp;
mod mcp;
mod page;
mod tools;

#[tokio::main]
async fn main() {
    let endpoint = std::env::var("SIVRAD_CDP")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| "http://127.0.0.1:9222".into());
    let browser = page::Browser::new(&endpoint);
    mcp::serve(browser).await;
}
