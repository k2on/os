//! The long poll devices keep their copy of someone's picture with (the
//! `avatar` aspect, modules/aspects/avatar.nix), behind nginx:
//!
//!   GET /avatar/<name>/wait?have=<tag>[&shape=circle]
//!
//! answers as soon as their picture's tag is not `have`: 200 with the
//! picture and its tag as the ETag, or 204 with ETag "none" when they have
//! none; with shape=circle, the picture cropped to a circle (image.rs).
//! Until then it holds the request, up to `WAIT`, and answers 304. So
//! a device waits on one idle connection and hears of a change at once.
//! Nothing but GET of a configured person; one thread per request, a few
//! at most at a time.
use std::collections::HashSet;
use std::io::{ErrorKind, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::state::{Pictures, Shape, NONE};
use crate::Result;

/// Under nginx's proxy_read_timeout (../../default.nix).
const WAIT: Duration = Duration::from_secs(50 * 60);
/// How often a held request looks for its client having gone (a laptop
/// asleep), so the thread does not wait out WAIT for nobody.
const CHECK: Duration = Duration::from_secs(30);
const MAX_REQUESTS: usize = 64;

pub fn serve(listen: &str, pictures: Arc<Pictures>, persons: HashSet<String>) -> Result<()> {
    let listener = TcpListener::bind(listen).map_err(|e| format!("listening on {listen}: {e}"))?;
    let persons = Arc::new(persons);
    let busy = Arc::new(AtomicUsize::new(0));
    for stream in listener.incoming() {
        let Ok(mut stream) = stream else { continue };
        if busy.fetch_add(1, Ordering::SeqCst) >= MAX_REQUESTS {
            busy.fetch_sub(1, Ordering::SeqCst);
            let _ = respond(&mut stream, "503 Service Unavailable", &[], &[]);
            continue;
        }
        let (pictures, persons, busy) = (pictures.clone(), persons.clone(), busy.clone());
        std::thread::spawn(move || {
            if let Err(e) = handle(&mut stream, &pictures, &persons) {
                eprintln!("photos-avatars: http: {e}");
            }
            busy.fetch_sub(1, Ordering::SeqCst);
        });
    }
    Ok(())
}

fn handle(stream: &mut TcpStream, pictures: &Pictures, persons: &HashSet<String>) -> Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    let head = read_head(stream)?;
    let line = head.lines().next().unwrap_or("");
    let mut parts = line.split(' ');
    let (method, target) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""));
    if method != "GET" {
        return respond(stream, "405 Method Not Allowed", &[], &[]);
    }
    let Some((name, have, shape)) = parse(target) else {
        return respond(stream, "404 Not Found", &[], &[]);
    };
    if !persons.contains(name) {
        return respond(stream, "404 Not Found", &[], &[]);
    }

    let deadline = Instant::now() + WAIT;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return respond(stream, "304 Not Modified", &[("ETag", &quoted(have))], &[]);
        }
        match pictures.differing(name, have, shape, left.min(CHECK)) {
            Some(Some((tag, bytes))) => {
                return respond(
                    stream,
                    "200 OK",
                    &[("Content-Type", "image/png"), ("ETag", &quoted(&tag))],
                    &bytes,
                )
            }
            Some(None) => return respond(stream, "204 No Content", &[("ETag", &quoted(NONE))], &[]),
            None if gone(stream) => return Ok(()),
            None => {}
        }
    }
}

/// `/avatar/<name>/wait?have=<tag>&shape=circle`: the name, the tag (""
/// if none) and the shape.
fn parse(target: &str) -> Option<(&str, &str, Shape)> {
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let name = path.strip_prefix("/avatar/")?.strip_suffix("/wait")?;
    let param = |key: &str| query.split('&').find_map(|kv| kv.strip_prefix(key)?.strip_prefix('='));
    let shape = if param("shape") == Some("circle") { Shape::Circle } else { Shape::AsIs };
    Some((name, param("have").unwrap_or(""), shape))
}

fn quoted(tag: &str) -> String {
    format!("\"{tag}\"")
}

/// The request line and headers; the body (there should be none) is not read.
fn read_head(stream: &mut TcpStream) -> Result<String> {
    let mut head = Vec::new();
    let mut byte = [0u8];
    while !head.ends_with(b"\r\n\r\n") {
        if head.len() > 8192 {
            return Err("request head too long".into());
        }
        stream.read_exact(&mut byte)?;
        head.push(byte[0]);
    }
    Ok(String::from_utf8_lossy(&head).into_owned())
}

/// Whether the client has closed its end.
fn gone(stream: &TcpStream) -> bool {
    if stream.set_nonblocking(true).is_err() {
        return true;
    }
    let mut byte = [0u8];
    let closed = match stream.peek(&mut byte) {
        Ok(0) => true,
        Ok(_) => false,
        Err(e) => e.kind() != ErrorKind::WouldBlock,
    };
    closed || stream.set_nonblocking(false).is_err()
}

fn respond(stream: &mut TcpStream, status: &str, headers: &[(&str, &str)], body: &[u8]) -> Result<()> {
    let mut out = format!("HTTP/1.1 {status}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n", body.len());
    for (k, v) in headers {
        out.push_str(&format!("{k}: {v}\r\n"));
    }
    out.push_str("\r\n");
    stream.write_all(out.as_bytes())?;
    stream.write_all(body)?;
    Ok(())
}
