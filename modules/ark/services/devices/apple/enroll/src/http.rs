//! Just enough HTTP/1.1 for one route behind nginx: POST with a
//! Content-Length body, answered and closed. One thread per request, a few
//! at a time; Setup Assistant asks once per device.
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use crate::{machine_info, Config, Result};

/// A MachineInfo is a few KB.
const MAX_BODY: usize = 64 * 1024;
const MAX_REQUESTS: usize = 16;
const TIMEOUT: Duration = Duration::from_secs(10);

pub fn serve(listen: &str, config: Config) -> Result<()> {
    let listener = TcpListener::bind(listen).map_err(|e| format!("listening on {listen}: {e}"))?;
    eprintln!("apple-enroll: listening on {listen}");
    let config = Arc::new(config);
    let busy = Arc::new(AtomicUsize::new(0));
    for stream in listener.incoming() {
        let Ok(mut stream) = stream else { continue };
        if busy.fetch_add(1, Ordering::SeqCst) >= MAX_REQUESTS {
            busy.fetch_sub(1, Ordering::SeqCst);
            let _ = respond(&mut stream, "503 Service Unavailable", "text/plain", b"busy\n");
            continue;
        }
        let (config, busy) = (config.clone(), busy.clone());
        std::thread::spawn(move || {
            if let Err(e) = handle(&mut stream, &config) {
                eprintln!("apple-enroll: {e}");
            }
            busy.fetch_sub(1, Ordering::SeqCst);
        });
    }
    Ok(())
}

fn handle(stream: &mut TcpStream, config: &Config) -> Result<()> {
    stream.set_read_timeout(Some(TIMEOUT))?;
    let (method, body) = match read_request(stream)? {
        Ok(r) => r,
        Err(status) => return respond(stream, status, "text/plain", b"bad request\n"),
    };
    if method != "POST" {
        return respond(stream, "405 Method Not Allowed", "text/plain", b"POST a MachineInfo\n");
    }
    let serial = match machine_info::unwrap(&body).map(|p| machine_info::string(&p, "SERIAL")) {
        Ok(Some(s)) => s.to_ascii_uppercase(),
        Ok(None) => return respond(stream, "400 Bad Request", "text/plain", b"no SERIAL\n"),
        Err(e) => {
            eprintln!("apple-enroll: {e}");
            return respond(stream, "400 Bad Request", "text/plain", b"not a MachineInfo\n");
        }
    };
    if !config.allowed()?.contains(&serial) {
        eprintln!("apple-enroll: refused {serial}: not declared");
        return respond(stream, "403 Forbidden", "text/plain", b"this device is not enrolled here\n");
    }
    let profile = std::fs::read(&config.profile)
        .map_err(|e| format!("reading {}: {e}", config.profile.display()))?;
    eprintln!("apple-enroll: profile to {serial}");
    respond(stream, "200 OK", "application/x-apple-aspen-config", &profile)
}

/// The method and body, or the status to refuse it with.
fn read_request(stream: &mut TcpStream) -> Result<std::result::Result<(String, Vec<u8>), &'static str>> {
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let Some(method) = line.split_whitespace().next().map(str::to_string) else {
        return Ok(Err("400 Bad Request"));
    };
    let mut length = 0usize;
    loop {
        line.clear();
        if reader.read_line(&mut line)? == 0 {
            return Ok(Err("400 Bad Request"));
        }
        let header = line.trim_end();
        if header.is_empty() {
            break;
        }
        if let Some((name, value)) = header.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") {
                let Ok(n) = value.trim().parse() else { return Ok(Err("400 Bad Request")) };
                length = n;
            }
        }
    }
    if length > MAX_BODY {
        return Ok(Err("413 Content Too Large"));
    }
    let mut body = vec![0; length];
    reader.read_exact(&mut body)?;
    Ok(Ok((method, body)))
}

fn respond(stream: &mut TcpStream, status: &str, content_type: &str, body: &[u8]) -> Result<()> {
    write!(
        stream,
        "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )?;
    stream.write_all(body)?;
    Ok(())
}
