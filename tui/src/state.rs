//! The app's whole mutable world: the last decoded digest, its file
//! freshness, and the one-line reply channel for socket commands.

use crate::digest::LiveState;
use ratatui::layout::Rect;
use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::SystemTime;
use time::{Duration, OffsetDateTime, UtcOffset};

/// Environment-decided rendering posture, resolved once: NO_COLOR
/// (no-color.org — presence of a non-empty value kills every color) and
/// an ASCII fallback when the locale doesn't speak UTF-8.
pub struct Look {
    pub no_color: bool,
    pub ascii: bool,
}

pub fn look() -> &'static Look {
    static LOOK: OnceLock<Look> = OnceLock::new();
    LOOK.get_or_init(|| Look {
        no_color: std::env::var_os("NO_COLOR").is_some_and(|v| !v.is_empty()),
        ascii: std::env::var_os("USAGE_TUI_ASCII").is_some_and(|v| !v.is_empty()) || {
            let lang = std::env::var("LC_ALL")
                .or_else(|_| std::env::var("LC_CTYPE"))
                .or_else(|_| std::env::var("LANG"))
                .unwrap_or_default();
            !lang.to_uppercase().replace('-', "").contains("UTF8")
        },
    })
}

/// Which surface owns the pane (design §3): the dashboard, or a detail
/// surface that opened side-by-side (landscape) / replaced the dashboard
/// with back navigation (portrait).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Surface {
    Dashboard,
    /// A meter's chart, by index into `digest.meters`.
    Meter(usize),
    /// One day's drill, by its digest dayKey ("2026-08-16").
    Day(String),
}

/// One mouse-sensitive region from the LAST draw — the render pass writes
/// these, the event pass reads them. Terminal UIs hit-test against what
/// was actually painted, never a parallel geometry model.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Hit {
    Meter(usize),
    HeatDay(String),
    PageEarlier,
    PageLater,
    ModelRow(usize),
    Back,
}

#[derive(Debug, Default)]
pub struct HitMap {
    regions: Vec<(Rect, Hit)>,
}

impl HitMap {
    pub fn clear(&mut self) {
        self.regions.clear();
    }

    pub fn add(&mut self, rect: Rect, hit: Hit) {
        self.regions.push((rect, hit));
    }

    pub fn at(&self, x: u16, y: u16) -> Option<&Hit> {
        // Later additions win: surfaces paint over the dashboard.
        self.regions
            .iter()
            .rev()
            .find(|(rect, _)| {
                x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height
            })
            .map(|(_, hit)| hit)
    }
}

/// How the pane should speak about engine liveness (design §5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Freshness {
    /// Digest fresh, state live.
    Live,
    /// The engine runs but serves cached/errored state.
    Stale,
    /// A 429 backoff is in force until the carried instant.
    Backoff,
    /// Nobody rewrites the digest — no engine is running.
    EngineOffline,
}

pub struct App {
    pub digest_path: PathBuf,
    pub socket_path: PathBuf,
    pub digest: Option<LiveState>,
    pub decode_error: Option<String>,
    /// One-line echo of the last socket command's reply, cleared by the
    /// next digest change.
    pub notice: Option<String>,
    /// The local UTC offset, captured once at startup while the process is
    /// still single-threaded (the `time` crate's soundness gate); clocks
    /// fall back to UTC when unavailable.
    pub local_offset: UtcOffset,
    last_modified: Option<SystemTime>,
    pub quit: bool,
    pub show_help: bool,
    pub surface: Surface,
    /// Heatmap pages stepped into the past; 0 = the current window.
    pub heat_page: usize,
    /// Scrub cursor into the open meter's series (index from the END).
    pub scrub: Option<usize>,
    /// Last mouse cell, for hover halos and readouts.
    pub pointer: Option<(u16, u16)>,
    /// The pointer resolved against the PREVIOUS frame's hit map — a
    /// frame's own map doesn't exist until its widgets have registered.
    pub hover_hit: Option<Hit>,
    pub hits: HitMap,
}

impl App {
    pub fn new(digest_path: PathBuf, socket_path: PathBuf, local_offset: UtcOffset) -> Self {
        let mut app = Self {
            digest_path,
            socket_path,
            digest: None,
            decode_error: None,
            notice: None,
            local_offset,
            last_modified: None,
            quit: false,
            show_help: false,
            surface: Surface::Dashboard,
            heat_page: 0,
            scrub: None,
            pointer: None,
            hover_hit: None,
            hits: HitMap::default(),
        };
        app.reload();
        app
    }

    /// Stat + reload when the publisher rewrote the file. Returns true when
    /// the digest changed (a redraw is owed).
    pub fn poll_digest(&mut self) -> bool {
        let modified = std::fs::metadata(&self.digest_path)
            .and_then(|m| m.modified())
            .ok();
        if modified == self.last_modified {
            return false;
        }
        self.last_modified = modified;
        self.reload();
        true
    }

    fn reload(&mut self) {
        match std::fs::read(&self.digest_path) {
            Ok(bytes) => match LiveState::parse(&bytes) {
                Ok(state) => {
                    self.digest = Some(state);
                    self.decode_error = None;
                    self.notice = None;
                }
                Err(error) => self.decode_error = Some(error.to_string()),
            },
            Err(_) => {
                // Missing file = engine has never run; keep any last digest
                // (renders greyed) rather than blanking the pane.
                if self.digest.is_none() {
                    self.decode_error = None;
                }
            }
        }
    }

    pub fn freshness(&self, now: OffsetDateTime) -> Freshness {
        let Some(digest) = &self.digest else {
            return Freshness::EngineOffline;
        };
        // The heartbeat rule is the host broker's: stale beyond twice the
        // digest's own poll horizon (floored at 3 min) means nobody is
        // rewriting it.
        let age = now - digest.engine.generated_at;
        let horizon = digest
            .engine
            .next_poll_at
            .map(|next| (next - digest.engine.generated_at).max(Duration::ZERO))
            .unwrap_or(Duration::ZERO);
        let cutoff = horizon.saturating_mul(2).max(Duration::minutes(3));
        if age > cutoff {
            return Freshness::EngineOffline;
        }
        if let Some(backoff) = digest.engine.backoff_until {
            if backoff > now {
                return Freshness::Backoff;
            }
        }
        if digest.engine.stale {
            return Freshness::Stale;
        }
        Freshness::Live
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use time::macros::datetime;

    fn app_with(digest: LiveState) -> App {
        let mut app = App::new(
            PathBuf::from("/nonexistent/live-state.json"),
            PathBuf::from("/nonexistent/control.sock"),
            UtcOffset::UTC,
        );
        app.digest = Some(digest);
        app
    }

    fn golden_digest() -> LiveState {
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../Tests/UsageCoreTests/Fixtures/digest/live-state-v1.json");
        LiveState::parse(&std::fs::read(path).unwrap()).unwrap()
    }

    #[test]
    fn missing_digest_is_engine_offline() {
        let app = App::new(
            PathBuf::from("/nonexistent/live-state.json"),
            PathBuf::from("/nonexistent/control.sock"),
            UtcOffset::UTC,
        );
        assert_eq!(
            app.freshness(datetime!(2026-08-16 12:00 UTC)),
            Freshness::EngineOffline
        );
    }

    #[test]
    fn freshness_follows_the_heartbeat_horizon() {
        // Golden: generatedAt 12:00, nextPollAt 12:03 → offline past 12:06.
        let app = app_with(golden_digest());
        assert_eq!(
            app.freshness(datetime!(2026-08-16 12:04 UTC)),
            Freshness::Live
        );
        assert_eq!(
            app.freshness(datetime!(2026-08-16 12:07 UTC)),
            Freshness::EngineOffline
        );
    }
}
