//! The control-socket client: one NDJSON request, one reply line, done.
//! Wire shape is Swift Codable's enum encoding — `{"refresh":{}}`,
//! `{"setInterval":{"seconds":300}}` — and nobody-listening is an
//! expected state (engine offline), never an error dialog.

use serde::Deserialize;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

#[derive(Debug, Clone, Deserialize)]
pub struct Reply {
    pub ok: bool,
    pub message: Option<String>,
}

pub fn send(socket_path: &Path, command: &serde_json::Value) -> Option<Reply> {
    let stream = UnixStream::connect(socket_path).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(3))).ok()?;
    stream.set_write_timeout(Some(Duration::from_secs(3))).ok()?;
    let mut writer = stream.try_clone().ok()?;
    let mut line = serde_json::to_vec(command).ok()?;
    line.push(b'\n');
    writer.write_all(&line).ok()?;
    let mut reader = BufReader::new(stream);
    let mut reply = String::new();
    reader.read_line(&mut reply).ok()?;
    serde_json::from_str(&reply).ok()
}

pub fn refresh(socket_path: &Path) -> Option<Reply> {
    send(socket_path, &serde_json::json!({ "refresh": {} }))
}

/// The engine's active pace. It clamps to its own floor and ceiling and
/// echoes what it settled on, so the reply — not the request — is what the
/// pane reports.
pub fn set_interval(socket_path: &Path, seconds: u32) -> Option<Reply> {
    send(
        socket_path,
        &serde_json::json!({ "setInterval": { "seconds": seconds } }),
    )
}
