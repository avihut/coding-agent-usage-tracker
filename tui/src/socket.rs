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

/// Why no reply came back. A caller that judges by the digest needs the
/// difference: an engine that never took the line can't act on it, while
/// one that took it and was slow to answer may still.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Silence {
    /// Nothing accepted the connection: no engine serves the socket.
    NotListening,
    /// The engine took the connection and didn't answer within 3s.
    NoAnswer,
}

pub fn send(socket_path: &Path, command: &serde_json::Value) -> Option<Reply> {
    ask(socket_path, command).ok()
}

/// `send`, saying why when no reply came back.
pub fn ask(socket_path: &Path, command: &serde_json::Value) -> Result<Reply, Silence> {
    let stream = UnixStream::connect(socket_path).map_err(|_| Silence::NotListening)?;
    let exchange = || -> Option<Reply> {
        stream.set_read_timeout(Some(Duration::from_secs(3))).ok()?;
        stream
            .set_write_timeout(Some(Duration::from_secs(3)))
            .ok()?;
        let mut writer = stream.try_clone().ok()?;
        let mut line = serde_json::to_vec(command).ok()?;
        line.push(b'\n');
        writer.write_all(&line).ok()?;
        let mut reader = BufReader::new(&stream);
        let mut reply = String::new();
        reader.read_line(&mut reply).ok()?;
        serde_json::from_str(&reply).ok()
    };
    exchange().ok_or(Silence::NoAnswer)
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

/// The person's × on a notice. The engine refuses an ongoing one (`ok:
/// false`, "not dismissable") — the reply, not the request, is the word.
pub fn dismiss_notice(socket_path: &Path, id: &str) -> Option<Reply> {
    send(
        socket_path,
        &serde_json::json!({ "dismissNotice": { "id": id } }),
    )
}

pub fn dismiss_all_notices(socket_path: &Path) -> Option<Reply> {
    send(socket_path, &serde_json::json!({ "dismissAllNotices": {} }))
}

/// The pane drew these while they were pending. Seen is not dismissed: the
/// dot stays, but an outage watched here ends with "Outage ended" rather
/// than a full recount.
pub fn mark_notices_seen(socket_path: &Path, ids: &[String]) -> Option<Reply> {
    send(
        socket_path,
        &serde_json::json!({ "markNoticesSeen": { "ids": ids } }),
    )
}

/// Pin the engine's focus on one account, by its key — or, with `None`,
/// hand it back to activity (the panel strip's Auto). The pin is the
/// engine's, shared with the menu bar. It answers `ok` for any enrolled
/// account, including one it stores and does not honour, so a pin is
/// judged by the next digest rather than by this reply — and a busy engine
/// that took the line but answered late may still apply it.
pub fn focus_profile(socket_path: &Path, key: Option<&str>) -> Result<Reply, Silence> {
    ask(socket_path, &focus_command(key))
}

fn focus_command(key: Option<&str>) -> serde_json::Value {
    match key {
        Some(key) => serde_json::json!({ "focusProfile": { "id": key } }),
        // Swift's synthesized Codable reads an absent optional as nil.
        None => serde_json::json!({ "focusProfile": {} }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn focus_speaks_the_engine_enum_encoding() {
        assert_eq!(
            focus_command(Some("codex")).to_string(),
            r#"{"focusProfile":{"id":"codex"}}"#
        );
        assert_eq!(focus_command(None).to_string(), r#"{"focusProfile":{}}"#);
    }

    #[test]
    fn silence_says_whether_anything_was_listening() {
        let path = std::env::temp_dir().join(format!("usage-tui-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&path);
        assert_eq!(
            ask(&path, &focus_command(None)).unwrap_err(),
            Silence::NotListening
        );
        // Something took the connection and hung up without a word.
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        let engine = std::thread::spawn(move || drop(listener.accept().unwrap()));
        assert_eq!(
            ask(&path, &focus_command(None)).unwrap_err(),
            Silence::NoAnswer
        );
        engine.join().unwrap();
        let _ = std::fs::remove_file(&path);
    }
}
