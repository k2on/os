//! Just enough of Postgres's wire protocol (version 3) for this: connect on
//! the local socket without a password (peer or trust), run simple queries
//! whose results are text, and wait for NOTIFY.
//! https://www.postgresql.org/docs/current/protocol-message-formats.html
use std::io::{ErrorKind, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use crate::Result;

pub struct Conn {
    stream: UnixStream,
    /// Notifications that came in while a query was running.
    pending: usize,
}

/// One row; a NULL column is None.
pub type Row = Vec<Option<String>>;

impl Conn {
    pub fn connect(socket_dir: &Path, user: &str, database: &str) -> Result<Conn> {
        let path = socket_dir.join(".s.PGSQL.5432");
        let stream = UnixStream::connect(&path).map_err(|e| format!("connecting to {}: {e}", path.display()))?;
        let mut conn = Conn { stream, pending: 0 };

        let mut body = 196608i32.to_be_bytes().to_vec(); // protocol 3.0
        for (k, v) in [("user", user), ("database", database), ("application_name", "photos-avatars")] {
            body.extend_from_slice(k.as_bytes());
            body.push(0);
            body.extend_from_slice(v.as_bytes());
            body.push(0);
        }
        body.push(0);
        let mut msg = ((body.len() + 4) as i32).to_be_bytes().to_vec();
        msg.extend(body);
        conn.stream.write_all(&msg)?;

        loop {
            let (tag, body) = conn.read()?;
            match tag {
                b'R' if code(&body) == 0 => {}
                b'R' => {
                    return Err(format!(
                        "Postgres asks for a password (authentication {}): connect by peer or trust",
                        code(&body)
                    )
                    .into())
                }
                b'Z' => return Ok(conn),
                b'E' => return Err(error(&body).into()),
                _ => {} // ParameterStatus, BackendKeyData, notices
            }
        }
    }

    /// Runs one or more statements; the rows of all of them, in order.
    pub fn query(&mut self, sql: &str) -> Result<Vec<Row>> {
        let mut msg = vec![b'Q'];
        msg.extend_from_slice(&((sql.len() + 5) as i32).to_be_bytes());
        msg.extend_from_slice(sql.as_bytes());
        msg.push(0);
        self.stream.write_all(&msg)?;

        let mut rows = Vec::new();
        let mut failed = None;
        loop {
            let (tag, body) = self.read()?;
            match tag {
                b'D' => rows.push(data_row(&body)?),
                b'E' => failed = Some(error(&body)),
                b'A' => self.pending += 1,
                b'Z' => break,
                _ => {} // RowDescription, CommandComplete, notices
            }
        }
        match failed {
            Some(e) => Err(e.into()),
            None => Ok(rows),
        }
    }

    /// Waits up to `timeout` for a notification on a channel LISTENed to:
    /// true when one came, false when the time ran out.
    pub fn wait(&mut self, timeout: Duration) -> Result<bool> {
        if self.pending > 0 {
            self.pending = 0;
            return Ok(true);
        }
        self.stream.set_read_timeout(Some(timeout))?;
        let mut tag = [0u8];
        let first = self.stream.read_exact(&mut tag);
        self.stream.set_read_timeout(None)?;
        match first {
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => return Ok(false),
            r => r?,
        }
        let body = self.read_body()?;
        match tag[0] {
            b'A' => Ok(true),
            b'E' => Err(error(&body).into()),
            _ => Ok(false), // a notice, or a parameter changing
        }
    }

    fn read(&mut self) -> Result<(u8, Vec<u8>)> {
        let mut tag = [0u8];
        self.stream.read_exact(&mut tag)?;
        Ok((tag[0], self.read_body()?))
    }

    fn read_body(&mut self) -> Result<Vec<u8>> {
        let mut len = [0u8; 4];
        self.stream.read_exact(&mut len)?;
        let len = i32::from_be_bytes(len);
        if len < 4 {
            return Err(format!("bad message length {len}").into());
        }
        let mut body = vec![0u8; len as usize - 4];
        self.stream.read_exact(&mut body)?;
        Ok(body)
    }
}

fn code(body: &[u8]) -> i32 {
    body.get(..4).map_or(-1, |b| i32::from_be_bytes([b[0], b[1], b[2], b[3]]))
}

fn data_row(body: &[u8]) -> Result<Row> {
    let mut at = 2;
    let count = u16::from_be_bytes([body[0], body[1]]);
    let mut row = Vec::with_capacity(count as usize);
    for _ in 0..count {
        let len = code(body.get(at..).ok_or("short data row")?);
        at += 4;
        if len < 0 {
            row.push(None);
            continue;
        }
        let value = body.get(at..at + len as usize).ok_or("short data row")?;
        row.push(Some(String::from_utf8_lossy(value).into_owned()));
        at += len as usize;
    }
    Ok(row)
}

/// An ErrorResponse's message, with its SQLSTATE.
fn error(body: &[u8]) -> String {
    let (mut message, mut state) = (String::new(), String::new());
    for field in body.split(|b| *b == 0) {
        match field.first() {
            Some(b'M') => message = String::from_utf8_lossy(&field[1..]).into_owned(),
            Some(b'C') => state = String::from_utf8_lossy(&field[1..]).into_owned(),
            _ => {}
        }
    }
    format!("postgres: {message} ({state})")
}
