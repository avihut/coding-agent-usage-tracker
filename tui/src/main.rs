//! usage-tui: a full-screen terminal face for the metering engine — reads
//! the live-state digest, computes nothing, fetches nothing, writes
//! nothing, holds no credential (docs/DAEMON.md). Sized for a tmux pane:
//! the layout re-plans itself from the pane's shape on every draw, and the
//! mouse is first-class (hover readouts, click-to-drill, wheel paging).

mod digest;
mod layout;
mod socket;
mod state;
mod status;
mod surfaces;
mod ui;

use ratatui::crossterm::event::{
    self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind, MouseButton,
    MouseEventKind,
};
use ratatui::crossterm::execute;
use state::{App, Hit, Surface};
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
            "--status" => {
                // One tmux-format line and out — no terminal takeover.
                println!("{}", status::render(&digest));
                std::process::exit(0);
            }
            "--help" | "-h" => {
                return Err(concat!(
                    "usage-tui — terminal dashboard for the usage engine\n\n",
                    "  --digest <path>   read this live-state.json (default: app support)\n",
                    "  --socket <path>   control socket for commands (default: app support)\n",
                    "\nkeys: q quit · r refresh · 1-3 meters · [ ] page · esc back · ? help"
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
        let _ = execute!(std::io::stdout(), DisableMouseCapture);
        ratatui::restore();
        default_hook(info);
    }));

    let terminal = ratatui::init();
    let _ = execute!(std::io::stdout(), EnableMouseCapture);
    let result = run(terminal, App::new(digest_path, socket_path, local_offset));
    let _ = execute!(std::io::stdout(), DisableMouseCapture);
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

        // The digest's mtime is the update signal (design §7).
        if last_stat.elapsed() >= Duration::from_millis(500) {
            last_stat = Instant::now();
            dirty |= app.poll_digest();
        }
        while let Ok(reply) = reply_rx.try_recv() {
            app.notice = Some(reply);
            dirty = true;
        }
        // A 1s tick redraws clocks and countdowns even when nothing moved.
        if dirty || last_draw.elapsed() >= Duration::from_secs(1) {
            terminal.draw(|frame| ui::render(frame, &mut app, OffsetDateTime::now_utc()))?;
            last_draw = Instant::now();
        }

        if !event::poll(Duration::from_millis(100))? {
            continue;
        }
        let mut redraw = true;
        match event::read()? {
            Event::Key(key) if key.kind == KeyEventKind::Press => {
                handle_key(&mut app, key.code, &reply_tx);
            }
            Event::Mouse(mouse) => match mouse.kind {
                MouseEventKind::Moved => {
                    app.pointer = Some((mouse.column, mouse.row));
                    // Repaint only when the hover target actually changed —
                    // waving the mouse over dead space costs nothing.
                    let target = app.hits.at(mouse.column, mouse.row).cloned();
                    redraw = target != app.hover_hit;
                }
                MouseEventKind::Down(MouseButton::Left) => {
                    let hit = app.hits.at(mouse.column, mouse.row).cloned();
                    if let Some(hit) = hit {
                        activate(&mut app, hit);
                    }
                }
                MouseEventKind::ScrollUp => scroll(&mut app, -1),
                MouseEventKind::ScrollDown => scroll(&mut app, 1),
                _ => redraw = false,
            },
            Event::Resize(..) => {}
            _ => redraw = false,
        }
        if redraw {
            terminal.draw(|frame| ui::render(frame, &mut app, OffsetDateTime::now_utc()))?;
            last_draw = Instant::now();
        }
    }
    Ok(())
}

fn handle_key(app: &mut App, code: KeyCode, reply_tx: &mpsc::Sender<String>) {
    match code {
        KeyCode::Char('q') => app.quit = true,
        KeyCode::Esc | KeyCode::Backspace => {
            if app.show_help {
                app.show_help = false;
            } else if app.scrub.is_some() {
                app.scrub = None;
            } else if app.surface != Surface::Dashboard {
                app.surface = Surface::Dashboard;
            } else {
                app.quit = true;
            }
        }
        KeyCode::Char('?') => app.show_help = !app.show_help,
        KeyCode::Char('r') => {
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
        KeyCode::Char(digit @ '1'..='4') => {
            if let Some(digest) = &app.digest {
                if let Some(index) = surfaces::meter_index_matching(&digest.meters, digit) {
                    app.surface = Surface::Meter(index);
                    app.scrub = None;
                }
            }
        }
        KeyCode::Tab => {
            if let (Surface::Meter(index), Some(digest)) = (&app.surface, &app.digest) {
                if !digest.meters.is_empty() {
                    app.surface = Surface::Meter((index + 1) % digest.meters.len());
                    app.scrub = None;
                }
            }
        }
        KeyCode::Char('[') => page_heatmap(app, 1),
        KeyCode::Char(']') => page_heatmap(app, -1),
        KeyCode::Left => step(app, 1),
        KeyCode::Right => step(app, -1),
        _ => {}
    }
}

/// ←/→ mean "one step into the past/future" for whichever surface is open:
/// scrub samples on a meter chart, calendar days on a day drill.
fn step(app: &mut App, direction: i64) {
    match &app.surface {
        Surface::Meter(index) => {
            let len = app
                .digest
                .as_ref()
                .and_then(|d| d.meters.get(*index))
                .map(|m| m.series.len())
                .unwrap_or(0);
            if len == 0 {
                return;
            }
            let current = app.scrub.unwrap_or(0) as i64;
            let moved = (current + direction).clamp(0, len as i64 - 1);
            app.scrub = Some(moved as usize);
        }
        Surface::Day(day_key) => {
            if let Some(moved) = surfaces::neighbor_day(day_key, -direction) {
                app.surface = Surface::Day(moved);
            }
        }
        Surface::Dashboard => {}
    }
}

fn page_heatmap(app: &mut App, direction: i64) {
    let moved = app.heat_page as i64 + direction;
    app.heat_page = moved.max(0) as usize;
}

fn scroll(app: &mut App, direction: i64) {
    match &app.surface {
        // Wheel over an open meter scrubs; over the dashboard it pages the
        // heatmap (design §7's wheel grammar).
        Surface::Meter(_) => step(app, direction),
        _ => page_heatmap(app, direction),
    }
}

fn activate(app: &mut App, hit: Hit) {
    match hit {
        Hit::Meter(index) => {
            app.surface = Surface::Meter(index);
            app.scrub = None;
        }
        Hit::HeatDay(day_key) => app.surface = Surface::Day(day_key),
        Hit::PageEarlier => page_heatmap(app, 1),
        Hit::PageLater => page_heatmap(app, -1),
        Hit::Back => {
            app.surface = Surface::Dashboard;
            app.scrub = None;
        }
        Hit::ModelRow(_) => {}
    }
}
