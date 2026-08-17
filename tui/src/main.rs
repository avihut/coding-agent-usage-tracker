//! usage-tui: a full-screen terminal face for the metering engine — reads
//! the live-state digest, computes nothing, fetches nothing, writes
//! nothing itself, holds no credential (docs/DAEMON.md). The one thing it
//! may start: finding no engine at all, it spawns the app's own
//! `usaged ensure` so the engine registers itself — the installer applies
//! the user's sticky opt-out, so policy stays in one place. Sized for a
//! tmux pane:
//! the layout re-plans itself from the pane's shape on every draw, and the
//! mouse is first-class (hover readouts, click-to-drill, wheel paging).

mod activity;
mod digest;
mod layout;
mod meter;
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
use state::{App, Freshness, Hit, Surface};
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, Instant};
use time::{OffsetDateTime, UtcOffset};

fn support_root() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join("Library/Application Support/com.avihu.ClaudeUsage")
}

/// The usaged binary embedded in ClaudeUsage.app: the standard install
/// spots first, then Spotlight's LaunchServices view for unusual homes.
fn find_usaged() -> Option<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let candidates = [
        home.join("Applications/ClaudeUsage.app"),
        PathBuf::from("/Applications/ClaudeUsage.app"),
    ];
    for app in candidates {
        let binary = app.join("Contents/MacOS/usaged");
        if binary.exists() {
            return Some(binary);
        }
    }
    let found = std::process::Command::new("/usr/bin/mdfind")
        .arg("kMDItemCFBundleIdentifier == 'com.avihu.ClaudeUsage'")
        .output()
        .ok()?;
    String::from_utf8_lossy(&found.stdout)
        .lines()
        .map(|line| PathBuf::from(line).join("Contents/MacOS/usaged"))
        .find(|binary| binary.exists())
}

/// No engine anywhere? Ask usaged to register itself with launchd (spec
/// §10 re-amendment: the UI entry points auto-install). The verb honors
/// the user's sticky opt-out, so this is an idempotent nudge, not a
/// policy decision — and the TUI itself still writes nothing: the
/// engine's own installer does. Once per TUI run, off-thread.
fn ensure_engine(reply_tx: &mpsc::Sender<String>) {
    let tx = reply_tx.clone();
    std::thread::spawn(move || {
        let reply = match find_usaged() {
            None => {
                "no engine and no ClaudeUsage.app on this Mac — install the app once".to_owned()
            }
            Some(binary) => match std::process::Command::new(&binary).arg("ensure").output() {
                Ok(output) => String::from_utf8_lossy(&output.stderr)
                    .lines()
                    .rev()
                    .find(|line| !line.trim().is_empty())
                    .unwrap_or("usaged ensure ran")
                    .trim_start_matches("[usaged] ")
                    .to_owned(),
                Err(error) => format!("usaged ensure failed: {error}"),
            },
        };
        let _ = tx.send(reply);
    });
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
                    "\nkeys: q quit · r refresh · arrows move the cursor, enter opens · 1-3 meters · [ ] page\n",
                    "      v span · c cost · p pace · s/z span+zoom on a meter · esc back · ? help"
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

    if app.freshness(OffsetDateTime::now_utc()) == Freshness::EngineOffline {
        app.notice = Some("no engine running — asking usaged to set itself up…".into());
        ensure_engine(&reply_tx);
    }

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
                    let was_keyboard = app.keyboard_mode;
                    app.keyboard_mode = false;
                    // Repaint only when the hover target actually changed —
                    // waving the mouse over dead space costs nothing.
                    let target = app.hits.at(mouse.column, mouse.row).cloned();
                    redraw = was_keyboard || target != app.hover_hit;
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
            } else if app.keyboard_mode && app.focus_hit.is_some() {
                // Dismiss the visible keyboard cursor before anything else.
                app.focus_hit = None;
            } else if app.scrub.is_some() {
                app.scrub = None;
            } else if app.surface != Surface::Dashboard {
                app.surface = Surface::Dashboard;
            } else {
                app.quit = true;
            }
        }
        KeyCode::Enter | KeyCode::Char(' ') => {
            if let Some(hit) = app.hover_hit.clone() {
                activate(app, hit);
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
        // The panel's quick pace picks, as one cycling key. The engine
        // persists the choice exactly as the ⋯ menu's does — a pane and a
        // menu asking for the same thing must mean the same thing.
        KeyCode::Char('p') => {
            let Some(seconds) = app
                .digest
                .as_ref()
                .map(|digest| state::next_pace(digest.engine.active_interval_seconds))
            else {
                return;
            };
            let socket_path = app.socket_path.clone();
            let tx = reply_tx.clone();
            app.notice = Some(format!("pace → {}m…", seconds / 60));
            std::thread::spawn(move || {
                let reply = match socket::set_interval(&socket_path, seconds) {
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
        // The app's activity pills and Tokens/Cost picker, as keys. Pages
        // don't translate between window sizes, so a period switch lands
        // on the current window — the app resets its pager the same way.
        KeyCode::Char('v') => {
            app.period = app.period.next();
            app.heat_page = 0;
        }
        KeyCode::Char('c') => app.dimension = app.dimension.toggled(),
        // The meter popover's span picker and its frame dropdown, as two
        // keys. Both are meter-surface grammar: on the dashboard they say
        // so rather than silently doing nothing.
        KeyCode::Char('s') => meter_span(app, false),
        KeyCode::Char('z') => meter_span(app, true),
        // Horizontal arrows keep each detail surface's own grammar
        // (scrub samples, step days); everywhere else all four arrows
        // drive the keyboard cursor across the hit map.
        KeyCode::Left => match app.surface {
            Surface::Dashboard => focus_move(app, -1, 0),
            _ => step(app, 1),
        },
        KeyCode::Right => match app.surface {
            Surface::Dashboard => focus_move(app, 1, 0),
            _ => step(app, -1),
        },
        KeyCode::Up => focus_move(app, 0, -1),
        KeyCode::Down => focus_move(app, 0, 1),
        _ => {}
    }
}

/// Move the keyboard cursor spatially over LAST frame's hit map — the
/// same geometry mouse hover resolves against. At an edge the cursor
/// stays put rather than wrapping.
fn focus_move(app: &mut App, dx: i32, dy: i32) {
    app.keyboard_mode = true;
    let origin = app
        .focus_hit
        .as_ref()
        .and_then(|hit| app.hits.rect_of(hit));
    if let Some(next) = app.hits.spatial_next(origin, dx, dy) {
        app.focus_hit = Some(next);
    }
}

/// `s` swaps the open meter's span (history ↔ its limit window); `z` zooms
/// the history frame in. Zooming out of the Current span means leaving it,
/// so `z` there drops to history first — every press changes the view.
fn meter_span(app: &mut App, zoom: bool) {
    let Surface::Meter(index) = app.surface else {
        app.notice = Some("open a meter first (1-3 or click one)".into());
        return;
    };
    let Some(meter) = app.digest.as_ref().and_then(|d| d.meters.get(index)) else {
        return;
    };
    let (span, rung) = app.meter_view(meter);
    let now = OffsetDateTime::now_utc();
    let rungs = meter::ladder(meter);
    let next = if zoom {
        match span {
            meter::Span::Current => (meter::Span::History, rung.min(rungs.len() - 1)),
            // Zoom IN: each press tightens the frame, wrapping back out at
            // the end. Stepping the other way would make the first press on
            // every meter jump to the tightest rung — the least useful one,
            // and on a coarsely-sampled weekly meter a near-empty plot.
            meter::Span::History => (
                span,
                rung.min(rungs.len() - 1)
                    .checked_sub(1)
                    .unwrap_or(rungs.len() - 1),
            ),
        }
    } else if span == meter::Span::History && !meter::window_available(meter, now) {
        // No live reset means no window to show — the app hides the
        // picker in exactly this case, so say why instead of no-op'ing.
        app.notice = Some("no live reset — this meter has only a history span".into());
        return;
    } else {
        (span.toggled(), rung)
    };
    app.meter_span.insert(meter.id.clone(), next);
    app.notice = Some(format!("span {}", meter::view(meter, next.0, next.1, now).label));
    app.scrub = None;
}

/// ←/→ mean "one step into the past/future" for whichever surface is open:
/// scrub samples on a meter chart, calendar days on a day drill.
fn step(app: &mut App, direction: i64) {
    match &app.surface {
        Surface::Meter(index) => {
            // Bound by the VISIBLE points, not the whole published series:
            // the cursor must never sit on a sample the span isn't drawing.
            let len = app
                .digest
                .as_ref()
                .and_then(|d| d.meters.get(*index))
                .map(|m| {
                    let (span, rung) = app.meter_view(m);
                    meter::view(m, span, rung, OffsetDateTime::now_utc())
                        .points
                        .len()
                })
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
