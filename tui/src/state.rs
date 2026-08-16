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

    /// Where a hit was painted last frame (later additions win, like `at`).
    pub fn rect_of(&self, hit: &Hit) -> Option<Rect> {
        self.regions
            .iter()
            .rev()
            .find(|(_, painted)| painted == hit)
            .map(|(rect, _)| *rect)
    }

    /// The keyboard cursor's move: from the origin rect, the best target
    /// in the (dx, dy) direction — nearest by progress along the arrow,
    /// with off-axis drift penalized so columns and rows stay "straight".
    /// No origin (first arrow press) summons the cursor to the topmost-
    /// leftmost target.
    pub fn spatial_next(&self, from: Option<Rect>, dx: i32, dy: i32) -> Option<Hit> {
        // Doubled coordinates keep centers integral.
        let center = |rect: &Rect| -> (i32, i32) {
            (
                2 * i32::from(rect.x) + i32::from(rect.width),
                2 * i32::from(rect.y) + i32::from(rect.height),
            )
        };
        let Some(origin) = from else {
            return self
                .regions
                .iter()
                .min_by_key(|(rect, _)| (rect.y, rect.x))
                .map(|(_, hit)| hit.clone());
        };
        let (ox, oy) = center(&origin);
        self.regions
            .iter()
            .filter_map(|(rect, hit)| {
                let (cx, cy) = center(rect);
                let along = (cx - ox) * dx + (cy - oy) * dy;
                if along <= 0 {
                    return None;
                }
                let across = ((cx - ox) * dy).abs() + ((cy - oy) * dx).abs();
                Some((along + across * 3, hit))
            })
            .min_by_key(|(score, _)| *score)
            .map(|(_, hit)| hit.clone())
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
    /// The EFFECTIVE hot element — mouse hover or keyboard focus,
    /// whichever device spoke last — resolved against the PREVIOUS
    /// frame's hit map (a frame's own map doesn't exist until its
    /// widgets have registered). Every hover treatment reads this, so
    /// the keyboard cursor gets halos and readouts for free.
    pub hover_hit: Option<Hit>,
    /// The keyboard cursor: arrows move it across the hit map, Enter
    /// activates it. It exists so hover interactions work in terminals
    /// that never report mouse motion (and without a mouse at all).
    pub focus_hit: Option<Hit>,
    /// True after a navigation key, false after mouse motion — decides
    /// which of focus/hover wins `hover_hit` when both exist.
    pub keyboard_mode: bool,
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
            focus_hit: None,
            keyboard_mode: false,
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
    fn spatial_navigation_walks_the_hit_map() {
        // A dashboard in miniature: three meter rows, two heat days
        // beneath, a pager beside the days.
        let mut hits = HitMap::default();
        hits.add(Rect::new(0, 2, 40, 1), Hit::Meter(0));
        hits.add(Rect::new(0, 3, 40, 1), Hit::Meter(1));
        hits.add(Rect::new(0, 4, 40, 1), Hit::Meter(2));
        hits.add(Rect::new(2, 8, 2, 1), Hit::HeatDay("2026-08-10".into()));
        hits.add(Rect::new(5, 8, 2, 1), Hit::HeatDay("2026-08-11".into()));
        hits.add(Rect::new(12, 8, 1, 1), Hit::PageEarlier);

        // No origin: the cursor is summoned to the topmost target.
        assert_eq!(hits.spatial_next(None, 0, 1), Some(Hit::Meter(0)));
        // Straight down the meter column.
        let from = hits.rect_of(&Hit::Meter(0));
        assert_eq!(hits.spatial_next(from, 0, 1), Some(Hit::Meter(1)));
        // Down from a full-width meter lands on whatever sits nearest its
        // CENTER on the next band — here the pager, not the leftmost day.
        let from = hits.rect_of(&Hit::Meter(2));
        assert_eq!(hits.spatial_next(from, 0, 1), Some(Hit::PageEarlier));
        // Right walks days before reaching the farther pager.
        let from = hits.rect_of(&Hit::HeatDay("2026-08-10".into()));
        assert_eq!(
            hits.spatial_next(from, 1, 0),
            Some(Hit::HeatDay("2026-08-11".into()))
        );
        // Up from a day returns to the meters.
        let from = hits.rect_of(&Hit::HeatDay("2026-08-10".into()));
        assert_eq!(hits.spatial_next(from, 0, -1), Some(Hit::Meter(2)));
        // Nothing above the first meter: the cursor stays put (None).
        let from = hits.rect_of(&Hit::Meter(0));
        assert_eq!(hits.spatial_next(from, 0, -1), None);
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
