//! usage-tui: a full-screen terminal face for the metering engine — reads
//! the live-state digest, computes nothing, fetches nothing, writes
//! nothing, holds no credential (docs/DAEMON.md). Sized for a tmux pane:
//! the layout re-plans itself from the pane's shape on every draw.

mod digest;
mod layout;
mod socket;
mod state;
mod ui;

use ratatui::crossterm::event::{self, Event, KeyCode, KeyEventKind};
use state::App;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, Instant};
use time::{OffsetDateTime, UtcOffset};

fn support_root() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join("Library/Application Support/com.avihu.ClaudeUsage")
}

fn parse_args() -> Result<(PathBuf, PathBuf), String> {
    let mut digest = support_root().join("live-state.json");
    let mut socket = support_root().join("control.sock");
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--digest" => {
                digest = args
                    .next()
                    .map(PathBuf::from)
                    .ok_or("--digest needs a path")?;
            }
            "--socket" => {
                socket = args
                    .next()
                    .map(PathBuf::from)
                    .ok_or("--socket needs a path")?;
            }
            "--help" | "-h" => {
                return Err(concat!(
                    "usage-tui — terminal dashboard for the usage engine\n\n",
                    "  --digest <path>   read this live-state.json (default: app support)\n",
                    "  --socket <path>   control socket for commands (default: app support)\n",
                    "\nkeys: q quit · r refresh · ? help"
                )
                .to_owned());
            }
            other => return Err(format!("unknown argument '{other}' (try --help)")),
        }
    }
    Ok((digest, socket))
}

fn main() {
    let (digest_path, socket_path) = match parse_args() {
        Ok(paths) => paths,
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(if message.starts_with("usage-tui") { 0 } else { 2 });
        }
    };
    // Capture the local offset while still single-threaded (the `time`
    // crate refuses afterwards, soundly); clocks fall back to UTC.
    let local_offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);

    // Restore the terminal on panic BEFORE the default hook prints, so the
    // message lands on a working screen (works under panic=abort too).
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        ratatui::restore();
        default_hook(info);
    }));

    let terminal = ratatui::init();
    let result = run(terminal, App::new(digest_path, socket_path, local_offset));
    ratatui::restore();
    if let Err(error) = result {
        eprintln!("usage-tui: {error}");
        std::process::exit(1);
    }
}

fn run(mut terminal: ratatui::DefaultTerminal, mut app: App) -> std::io::Result<()> {
    let (reply_tx, reply_rx) = mpsc::channel::<String>();
    let mut last_draw = Instant::now() - Duration::from_secs(1);
    let mut last_stat = Instant::now() - Duration::from_secs(1);

    while !app.quit {
        let mut dirty = false;

        // The digest's mtime is the update signal (design §7: a change
        // reloads and diffs into place).
        if last_stat.elapsed() >= Duration::from_millis(500) {
            last_stat = Instant::now();
            dirty |= app.poll_digest();
        }
        while let Ok(reply) = reply_rx.try_recv() {
            app.notice = Some(reply);
            dirty = true;
        }
        // A 1s tick redraws clocks and countdowns even when nothing else
        // moved.
        if dirty || last_draw.elapsed() >= Duration::from_secs(1) {
            terminal.draw(|frame| ui::render(frame, &app, OffsetDateTime::now_utc()))?;
            last_draw = Instant::now();
        }

        if !event::poll(Duration::from_millis(250))? {
            continue;
        }
        match event::read()? {
            Event::Key(key) if key.kind == KeyEventKind::Press => match key.code {
                KeyCode::Char('q') => app.quit = true,
                KeyCode::Esc => {
                    if app.show_help {
                        app.show_help = false;
                    } else {
                        app.quit = true;
                    }
                }
                KeyCode::Char('?') => app.show_help = !app.show_help,
                KeyCode::Char('r') => {
                    // The socket blocks up to 3s — keep the loop fluid.
                    let socket_path = app.socket_path.clone();
                    let tx = reply_tx.clone();
                    app.notice = Some("refreshing…".into());
                    std::thread::spawn(move || {
                        let reply = match socket::refresh(&socket_path) {
                            Some(reply) => reply
                                .message
                                .unwrap_or_else(|| if reply.ok { "ok".into() } else { "refused".into() }),
                            None => "engine socket not listening".into(),
                        };
                        let _ = tx.send(reply);
                    });
                }
                _ => {}
            },
            Event::Resize(..) => {
                terminal.draw(|frame| ui::render(frame, &app, OffsetDateTime::now_utc()))?;
                last_draw = Instant::now();
            }
            _ => {}
        }
    }
    Ok(())
}
