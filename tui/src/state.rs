//! The app's whole mutable world: the last decoded digest, its file
//! freshness, and the one-line reply channel for socket commands.

use crate::digest::{LiveState, ProfileState};
use ratatui::layout::Rect;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::{Instant, SystemTime};
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

/// The activity span, the app's 7D/30D/All pills. Session-local by design
/// (the app persists its pick; the pane starts each run on the app's own
/// fresh-install default).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Period {
    Week,
    Month,
    All,
}

impl Period {
    pub fn next(self) -> Self {
        match self {
            Self::Week => Self::Month,
            Self::Month => Self::All,
            Self::All => Self::Week,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Week => "7D",
            Self::Month => "30D",
            Self::All => "All",
        }
    }
}

/// What the activity charts measure — token volume or estimated cost
/// (the app's Tokens/Cost picker).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dimension {
    Tokens,
    Cost,
}

impl Dimension {
    pub fn toggled(self) -> Self {
        match self {
            Self::Tokens => Self::Cost,
            Self::Cost => Self::Tokens,
        }
    }
}

/// The panel ⋯ menu's quick pace picks, in seconds. 3 minutes is the
/// engine's own polling floor (TriggerGate) — the pane can ask for a
/// faster pace than that no more than the app can.
pub const PACE_PRESETS: [u32; 3] = [180, 300, 900];

/// The next quick pick above the pace in force, wrapping at the top. A
/// slider-set value in between advances to the next preset ABOVE it rather
/// than snapping back to the floor, so `p` always changes something.
pub fn next_pace(current: f64) -> u32 {
    PACE_PRESETS
        .into_iter()
        .find(|preset| f64::from(*preset) > current + 0.5)
        .unwrap_or(PACE_PRESETS[0])
}

/// What `a`, `A` or a header mark asks of the engine's focus: one account,
/// by its key, or focus handed back to activity (the panel strip's Auto).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FocusAsk {
    Pin(String),
    Auto,
}

impl FocusAsk {
    /// The socket's argument: the key to pin, or none to unpin.
    pub fn key(&self) -> Option<&str> {
        match self {
            Self::Pin(key) => Some(key),
            Self::Auto => None,
        }
    }
}

/// The engine's answer to one focus request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FocusAnswer {
    Accepted,
    /// Refused, or nothing listening: nothing will land, and the line says
    /// why.
    Refused(String),
    /// The engine took the line and didn't answer within the socket's 3s. A
    /// busy engine may still apply it, so the digest gets FOCUS_GRACE to
    /// show it rather than the pane calling it lost.
    Unanswered,
}

/// How long the digest has, once the engine took a request, to show the
/// switch before the pane says it didn't happen.
pub const FOCUS_GRACE: std::time::Duration = std::time::Duration::from_secs(8);

/// A focus switch the pane asked for and hasn't seen land.
#[derive(Debug, Clone)]
pub struct FocusRequest {
    /// The latest ask; every press moves it.
    pub wanted: FocusAsk,
    /// The ask on the wire, if one is. ONE request is out at a time: a press
    /// while it is out only moves `wanted`, and the loop sends that when the
    /// reply lands. A double-tap steps twice, and a slow engine never faces
    /// a burst of connections it would answer into sockets the pane's 3s
    /// timeout has already closed.
    pub in_flight: Option<FocusAsk>,
    /// When the engine took `wanted`; the digest then has FOCUS_GRACE.
    pub accepted_at: Option<Instant>,
    /// The last request got no answer in time: the engine is slow, and the
    /// pane says so rather than guess.
    pub unanswered: bool,
}

/// The accounts a pin moves focus to, in the person's order — the engine's
/// own rule (`HarnessFocusRule`): turned on, not dormant, and its harness
/// shown. The engine stores a pin on any other account and then ignores it.
pub fn focus_candidates(digest: &LiveState) -> Vec<&ProfileState> {
    let Some(profiles) = digest.profiles.as_ref() else {
        return Vec::new();
    };
    // A writer before harnesses metered exactly one, and showed it.
    let shown = |provider: &str| {
        digest.harnesses.as_ref().is_none_or(|harnesses| {
            harnesses
                .iter()
                .any(|harness| harness.id == provider && harness.shown)
        })
    };
    profiles
        .iter()
        .filter(|profile| profile.enabled && !profile.dormant && shown(&profile.provider_id))
        .collect()
}

/// The account `a` steps to: the candidate after `from`, wrapping. None
/// when there is nowhere else to go.
pub fn next_account(digest: &LiveState, from: Option<&str>) -> Option<String> {
    let candidates = focus_candidates(digest);
    if candidates.len() < 2 {
        return None;
    }
    let next = from
        .and_then(|key| candidates.iter().position(|profile| profile.id == key))
        .map_or(0, |index| (index + 1) % candidates.len());
    Some(candidates[next].id.clone())
}

/// What the pane calls an account: its agent's name, with the account's own
/// label when that agent has several to choose between. Every word comes
/// from the digest; the pane names no vendor of its own.
pub fn account_name(digest: &LiveState, key: &str) -> String {
    let Some(profile) = digest
        .profiles
        .as_ref()
        .and_then(|profiles| profiles.iter().find(|profile| profile.id == key))
    else {
        return key.to_owned();
    };
    let agent = digest.harnesses.as_ref().and_then(|harnesses| {
        harnesses
            .iter()
            .find(|harness| harness.id == profile.provider_id)
            .map(|harness| harness.agent_name.as_str())
    });
    let siblings = focus_candidates(digest)
        .iter()
        .filter(|other| other.provider_id == profile.provider_id)
        .count();
    match agent {
        Some(agent) if siblings > 1 => format!("{agent} ({})", profile.label),
        Some(agent) => agent.to_owned(),
        None => profile.label.clone(),
    }
}

/// The footer's line while a switch is under way.
fn focus_progress(digest: Option<&LiveState>, ask: &FocusAsk, slow: bool) -> String {
    let target = match (ask, digest) {
        (FocusAsk::Pin(key), Some(digest)) => account_name(digest, key),
        (FocusAsk::Pin(key), None) => key.clone(),
        (FocusAsk::Auto, _) => "follows activity".into(),
    };
    if slow {
        format!("focus → {target}… (the engine is slow to answer)")
    } else {
        format!("focus → {target}…")
    }
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
    /// A notification row, by notice id — focusable, so `x` has a target.
    Notice(String),
    /// The row's × cell; click or enter dismisses.
    NoticeDismiss(String),
    /// Another harness's mark in the header, by the account key its cell
    /// belongs to; click or enter pins focus there, as a click on that mark
    /// in the menu bar does.
    Account(String),
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
    /// The first registered hit matching `pred`, in paint order — `n`
    /// uses it to land the cursor on the first notification row.
    pub fn find(&self, pred: impl Fn(&Hit) -> bool) -> Option<Hit> {
        self.regions
            .iter()
            .map(|(_, hit)| hit)
            .find(|hit| pred(hit))
            .cloned()
    }

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
    /// The activity span (7D bars / 30D calendar / all-time grid) and what
    /// the charts measure. The app persists both; a pane is a transient
    /// view, so each run starts on the app's fresh-install defaults.
    pub period: Period,
    pub dimension: Dimension,
    /// Scrub cursor into the open meter's VISIBLE points (index from the
    /// END of `meter::view(...).points`, never the whole series — the
    /// cursor must not reach a sample the span isn't drawing).
    pub scrub: Option<usize>,
    /// Each meter's span and zoom rung, by meter id. The app persists these
    /// per meter; the pane holds no store of its own, so they live for the
    /// run and start where the app's fresh defaults do.
    pub meter_span: HashMap<String, (crate::meter::Span, usize)>,
    /// Last mouse cell, for hover halos and readouts.
    pub pointer: Option<(u16, u16)>,
    /// A × activated by click/enter, waiting for the loop's reply channel.
    pub pending_dismiss: Option<String>,
    /// A header mark activated by click/enter, waiting for the same.
    pub pending_focus: Option<FocusAsk>,
    /// The focus switch under way, until the digest shows it or the pane
    /// gives up on it.
    pub focus_request: Option<FocusRequest>,
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
            pending_dismiss: None,
            pending_focus: None,
            focus_request: None,
            local_offset,
            last_modified: None,
            quit: false,
            show_help: false,
            surface: Surface::Dashboard,
            heat_page: 0,
            period: Period::Week,
            dimension: Dimension::Tokens,
            scrub: None,
            meter_span: HashMap::new(),
            pointer: None,
            hover_hit: None,
            focus_hit: None,
            keyboard_mode: false,
            hits: HitMap::default(),
        };
        app.reload();
        app
    }

    /// The span and zoom rung in force for a meter — the app's own opening
    /// state (history, at the meter's native scale) until `s`/`z` say
    /// otherwise.
    pub fn meter_view(&self, meter: &crate::digest::LiveMeter) -> (crate::meter::Span, usize) {
        self.meter_span.get(&meter.id).copied().unwrap_or_else(|| {
            (
                crate::meter::Span::default(),
                crate::meter::default_rung(meter),
            )
        })
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
                Ok(state) => self.adopt(state),
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

    /// A freshly decoded digest takes over. When it focuses a different
    /// account than the last one did (a key here, a click in the menu bar,
    /// or activity), every open surface, cursor and page still indexes the
    /// old account's data, so the pane goes back to the dashboard rather
    /// than show the new account's meter at the old one's position.
    fn adopt(&mut self, state: LiveState) {
        let before = self
            .digest
            .as_ref()
            .and_then(|digest| digest.focused_profile.clone());
        let switched = before.is_some() && before != state.focused_profile;
        self.digest = Some(state);
        self.decode_error = None;
        self.notice = None;
        if switched {
            self.surface = Surface::Dashboard;
            self.scrub = None;
            self.focus_hit = None;
            self.heat_page = 0;
        }
        // A switch still under way keeps its line across unrelated
        // publishes, and confirms itself the moment the digest shows it.
        if let Some(request) = &self.focus_request {
            self.notice = Some(focus_progress(
                self.digest.as_ref(),
                &request.wanted,
                request.unanswered,
            ));
        }
        self.settle_focus();
    }

    /// The account `a` moves to: the one after the account already asked
    /// for while a switch is under way, else after the focused one.
    pub fn next_focus(&self) -> Option<String> {
        let digest = self.digest.as_ref()?;
        let from = match self.focus_request.as_ref().map(|request| &request.wanted) {
            Some(FocusAsk::Pin(key)) => Some(key.as_str()),
            _ => digest.focused_profile.as_deref(),
        };
        next_account(digest, from)
    }

    /// A press asking for `ask`. Returns what to send now: nothing while a
    /// request is already out, whose reply sends the latest ask instead.
    pub fn ask_focus(&mut self, ask: FocusAsk) -> Option<FocusAsk> {
        let slow = self
            .focus_request
            .as_ref()
            .is_some_and(|request| request.unanswered);
        self.notice = Some(focus_progress(self.digest.as_ref(), &ask, slow));
        match &mut self.focus_request {
            Some(request) => {
                request.wanted = ask.clone();
                request.accepted_at = None;
                if request.in_flight.is_some() {
                    return None;
                }
                request.in_flight = Some(ask.clone());
            }
            None => {
                self.focus_request = Some(FocusRequest {
                    wanted: ask.clone(),
                    in_flight: Some(ask.clone()),
                    accepted_at: None,
                    unanswered: false,
                });
            }
        }
        Some(ask)
    }

    /// The request on the wire came back. A refusal ends the switch; an
    /// acceptance or a late engine leaves it to the digest. Returns the next
    /// ask to send when the person moved on meanwhile.
    pub fn focus_answered(&mut self, answer: FocusAnswer, now: Instant) -> Option<FocusAsk> {
        let request = self.focus_request.as_mut()?;
        let sent = request.in_flight.take()?;
        match answer {
            FocusAnswer::Refused(why) => {
                self.focus_request = None;
                self.notice = Some(why);
                return None;
            }
            FocusAnswer::Unanswered => request.unanswered = true,
            FocusAnswer::Accepted => request.unanswered = false,
        }
        if request.wanted != sent {
            request.in_flight = Some(request.wanted.clone());
            return Some(request.wanted.clone());
        }
        request.accepted_at = Some(now);
        self.notice = Some(focus_progress(
            self.digest.as_ref(),
            &request.wanted,
            request.unanswered,
        ));
        self.settle_focus();
        None
    }

    /// Confirms a switch the engine took, once it shows. Handing focus back
    /// to activity can't be refused, so the engine's acceptance is enough —
    /// or, when it never answered, the digest's own pin. A pin counts once
    /// the digest focuses the account asked for.
    fn settle_focus(&mut self) {
        let (Some(request), Some(digest)) = (&self.focus_request, &self.digest) else {
            return;
        };
        if request.in_flight.is_some() || request.accepted_at.is_none() {
            return;
        }
        let notice = match &request.wanted {
            FocusAsk::Auto if !request.unanswered || digest.pinned_profile.is_none() => {
                "focus follows activity".to_owned()
            }
            FocusAsk::Auto => return,
            FocusAsk::Pin(key) if digest.focused_profile.as_deref() == Some(key.as_str()) => {
                format!("focus pinned: {} (A for auto)", account_name(digest, key))
            }
            FocusAsk::Pin(_) => return,
        };
        self.notice = Some(notice);
        self.focus_request = None;
    }

    /// Gives up on a switch the digest never showed. Returns true when the
    /// footer's line changed.
    pub fn focus_tick(&mut self, now: Instant) -> bool {
        let Some(request) = &self.focus_request else {
            return false;
        };
        let Some(accepted) = request.accepted_at else {
            return false;
        };
        if now.duration_since(accepted) < FOCUS_GRACE {
            return false;
        }
        let (wanted, unanswered) = (request.wanted.clone(), request.unanswered);
        self.focus_request = None;
        let Some(digest) = &self.digest else {
            return false;
        };
        self.notice = Some(match (&wanted, digest.focused_profile.as_deref()) {
            (FocusAsk::Pin(key), current) => {
                let why = if unanswered {
                    "the engine didn't answer".to_owned()
                } else {
                    format!("{} didn't take it", account_name(digest, key))
                };
                match current {
                    Some(current) => {
                        format!("focus stayed on {} — {why}", account_name(digest, current))
                    }
                    None => format!("focus didn't move — {why}"),
                }
            }
            (FocusAsk::Auto, _) => "the engine didn't answer — focus may still be pinned".into(),
        });
        true
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
        if let Some(backoff) = digest.engine.backoff_until
            && backoff > now
        {
            return Freshness::Backoff;
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

    /// Focus on Codex; the bundled harness's second account dormant, and
    /// Gemini's harness hidden.
    fn harness_digest() -> LiveState {
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../Tests/UsageCoreTests/Fixtures/digest/live-state-v1-harnesses.json");
        LiveState::parse(&std::fs::read(path).unwrap()).unwrap()
    }

    fn candidate_keys(digest: &LiveState) -> Vec<&str> {
        focus_candidates(digest)
            .iter()
            .map(|profile| profile.id.as_str())
            .collect()
    }

    fn profile_mut<'a>(digest: &'a mut LiveState, key: &str) -> &'a mut ProfileState {
        digest
            .profiles
            .as_mut()
            .unwrap()
            .iter_mut()
            .find(|profile| profile.id == key)
            .unwrap()
    }

    #[test]
    fn focus_steps_only_through_accounts_the_engine_will_focus() {
        let digest = harness_digest();
        assert_eq!(candidate_keys(&digest), ["default", "codex"]);
        assert_eq!(
            next_account(&digest, Some("codex")).as_deref(),
            Some("default")
        );
        assert_eq!(
            next_account(&digest, Some("default")).as_deref(),
            Some("codex")
        );
        // A focus outside the candidates starts from the first.
        assert_eq!(
            next_account(&digest, Some("gemini")).as_deref(),
            Some("default")
        );

        // Woken, the second account joins in the person's order; shown, so
        // does Gemini.
        let mut wider = digest.clone();
        profile_mut(&mut wider, "c982130e").dormant = false;
        for harness in wider.harnesses.as_mut().unwrap() {
            harness.shown = true;
        }
        assert_eq!(
            candidate_keys(&wider),
            ["default", "c982130e", "codex", "gemini"]
        );
        assert_eq!(
            next_account(&wider, Some("default")).as_deref(),
            Some("c982130e")
        );
        assert_eq!(
            next_account(&wider, Some("gemini")).as_deref(),
            Some("default")
        );

        // An account turned off leaves one, and one has nowhere to go.
        let mut off = digest.clone();
        profile_mut(&mut off, "codex").enabled = false;
        assert_eq!(candidate_keys(&off), ["default"]);
        assert_eq!(next_account(&off, Some("default")), None);

        // A writer before profiles metered one account.
        let mut legacy = digest.clone();
        legacy.profiles = None;
        assert!(candidate_keys(&legacy).is_empty());
        assert_eq!(next_account(&legacy, None), None);
    }

    #[test]
    fn accounts_are_named_by_their_agent_and_label_from_the_digest() {
        let digest = harness_digest();
        assert_eq!(account_name(&digest, "codex"), "Codex");
        // One focusable account per agent: the agent says enough.
        assert_eq!(account_name(&digest, "default"), "Claude Code");
        let mut woken = digest.clone();
        profile_mut(&mut woken, "c982130e").dormant = false;
        assert_eq!(
            account_name(&woken, "default"),
            "Claude Code (work@example.com)"
        );
        assert_eq!(account_name(&woken, "c982130e"), "Claude Code (Personal)");
        assert_eq!(account_name(&digest, "nope"), "nope");
    }

    #[test]
    fn a_pin_is_confirmed_by_the_digest_not_by_the_reply() {
        let mut app = app_with(harness_digest());
        let t0 = Instant::now();
        let ask = FocusAsk::Pin(app.next_focus().unwrap());
        assert_eq!(
            app.ask_focus(ask.clone()),
            Some(FocusAsk::Pin("default".into()))
        );
        assert_eq!(app.notice.as_deref(), Some("focus → Claude Code…"));
        // Accepted, but the digest still focuses Codex: keep saying so, even
        // across a publish that changes nothing about focus.
        assert_eq!(app.focus_answered(FocusAnswer::Accepted, t0), None);
        assert_eq!(app.notice.as_deref(), Some("focus → Claude Code…"));
        app.adopt(harness_digest());
        assert_eq!(app.notice.as_deref(), Some("focus → Claude Code…"));
        // The digest shows it: confirmed, and the request is spent.
        let mut moved = harness_digest();
        moved.focused_profile = Some("default".into());
        app.adopt(moved);
        assert_eq!(
            app.notice.as_deref(),
            Some("focus pinned: Claude Code (A for auto)")
        );
        assert!(app.focus_request.is_none());
        assert!(!app.focus_tick(t0 + FOCUS_GRACE * 2));
    }

    #[test]
    fn a_double_tap_steps_twice_on_one_connection_at_a_time() {
        let mut app = app_with(harness_digest());
        let t0 = Instant::now();
        let first = FocusAsk::Pin(app.next_focus().unwrap());
        assert!(app.ask_focus(first).is_some());
        // The second press steps on from the TARGET, not the stale digest,
        // and waits for the first reply instead of opening a second socket.
        let second = FocusAsk::Pin(app.next_focus().unwrap());
        assert_eq!(second, FocusAsk::Pin("codex".into()));
        assert_eq!(app.ask_focus(second.clone()), None);
        // The reply to the first sends the latest.
        assert_eq!(app.focus_answered(FocusAnswer::Accepted, t0), Some(second));
        // Codex is focused already, so its acceptance settles it.
        assert_eq!(app.focus_answered(FocusAnswer::Accepted, t0), None);
        assert_eq!(
            app.notice.as_deref(),
            Some("focus pinned: Codex (A for auto)")
        );
        assert!(app.focus_request.is_none());
    }

    #[test]
    fn a_pin_the_digest_never_shows_is_reported_not_assumed() {
        let mut app = app_with(harness_digest());
        let t0 = Instant::now();
        app.ask_focus(FocusAsk::Pin("default".into()));
        assert_eq!(app.focus_answered(FocusAnswer::Accepted, t0), None);
        assert!(!app.focus_tick(t0 + FOCUS_GRACE / 2));
        assert!(app.focus_tick(t0 + FOCUS_GRACE));
        assert_eq!(
            app.notice.as_deref(),
            Some("focus stayed on Codex — Claude Code didn't take it")
        );
        assert!(app.focus_request.is_none());
    }

    #[test]
    fn a_refusal_or_a_silent_socket_ends_the_switch_and_says_why() {
        let mut app = app_with(harness_digest());
        let t0 = Instant::now();
        app.ask_focus(FocusAsk::Pin("default".into()));
        // The person moved on meanwhile — a refusal ends that too.
        app.ask_focus(FocusAsk::Auto);
        assert_eq!(
            app.focus_answered(
                FocusAnswer::Refused("engine socket not listening".into()),
                t0
            ),
            None
        );
        assert_eq!(app.notice.as_deref(), Some("engine socket not listening"));
        assert!(app.focus_request.is_none());
        // A stray reply with nothing out changes nothing.
        assert_eq!(app.focus_answered(FocusAnswer::Accepted, t0), None);
    }

    #[test]
    fn handing_focus_back_to_activity_settles_on_acceptance() {
        let mut app = app_with(harness_digest());
        assert_eq!(app.ask_focus(FocusAsk::Auto), Some(FocusAsk::Auto));
        assert_eq!(app.notice.as_deref(), Some("focus → follows activity…"));
        assert_eq!(
            app.focus_answered(FocusAnswer::Accepted, Instant::now()),
            None
        );
        assert_eq!(app.notice.as_deref(), Some("focus follows activity"));
        assert!(app.focus_request.is_none());
    }

    #[test]
    fn a_slow_engine_is_waited_for_not_reported_as_gone() {
        // The socket timed out, but the engine had taken the line: a busy
        // engine may still apply it, so the digest decides.
        let mut app = app_with(harness_digest());
        let t0 = Instant::now();
        app.ask_focus(FocusAsk::Pin("default".into()));
        assert_eq!(app.focus_answered(FocusAnswer::Unanswered, t0), None);
        assert_eq!(
            app.notice.as_deref(),
            Some("focus → Claude Code… (the engine is slow to answer)")
        );
        // The line survives an unrelated publish, slowness included.
        app.adopt(harness_digest());
        assert_eq!(
            app.notice.as_deref(),
            Some("focus → Claude Code… (the engine is slow to answer)")
        );
        let mut moved = harness_digest();
        moved.focused_profile = Some("default".into());
        app.adopt(moved);
        assert_eq!(
            app.notice.as_deref(),
            Some("focus pinned: Claude Code (A for auto)")
        );

        // When it never shows, the line says the engine went quiet — not
        // that the account refused.
        let mut app = app_with(harness_digest());
        app.ask_focus(FocusAsk::Pin("default".into()));
        app.focus_answered(FocusAnswer::Unanswered, t0);
        assert!(app.focus_tick(t0 + FOCUS_GRACE));
        assert_eq!(
            app.notice.as_deref(),
            Some("focus stayed on Codex — the engine didn't answer")
        );
    }

    #[test]
    fn an_unanswered_auto_waits_for_the_digest_to_drop_the_pin() {
        let mut pinned = harness_digest();
        pinned.pinned_profile = Some("codex".into());
        let mut app = app_with(pinned.clone());
        let t0 = Instant::now();
        app.ask_focus(FocusAsk::Auto);
        app.focus_answered(FocusAnswer::Unanswered, t0);
        // Still pinned in the digest: not confirmed.
        app.adopt(pinned.clone());
        assert!(app.focus_request.is_some());
        // The pin is gone: activity has focus again.
        app.adopt(harness_digest());
        assert_eq!(app.notice.as_deref(), Some("focus follows activity"));
        assert!(app.focus_request.is_none());

        // And when the pin never drops, the pane doesn't claim it did.
        let mut app = app_with(pinned);
        app.ask_focus(FocusAsk::Auto);
        app.focus_answered(FocusAnswer::Unanswered, t0);
        assert!(app.focus_tick(t0 + FOCUS_GRACE));
        assert_eq!(
            app.notice.as_deref(),
            Some("the engine didn't answer — focus may still be pinned")
        );
    }

    #[test]
    fn another_account_focused_returns_the_pane_to_the_dashboard() {
        let mut app = app_with(harness_digest());
        app.surface = Surface::Meter(1);
        app.scrub = Some(4);
        app.heat_page = 2;
        // The same account republished: nothing moves.
        app.adopt(harness_digest());
        assert_eq!(app.surface, Surface::Meter(1));
        assert_eq!(app.scrub, Some(4));
        // Another account focused, from anywhere: the open chart indexed the
        // old account's meters, so the pane starts over.
        let mut moved = harness_digest();
        moved.focused_profile = Some("default".into());
        app.adopt(moved);
        assert_eq!(app.surface, Surface::Dashboard);
        assert_eq!(app.scrub, None);
        assert_eq!(app.heat_page, 0);
    }

    #[test]
    fn pace_cycles_upward_from_wherever_the_slider_left_it() {
        // The three quick picks cycle.
        assert_eq!(next_pace(180.0), 300);
        assert_eq!(next_pace(300.0), 900);
        assert_eq!(next_pace(900.0), 180);
        // An in-between slider value advances to the next pick above it,
        // never snapping backwards to the floor.
        assert_eq!(next_pace(420.0), 900);
        // Slower than every pick (the slider reaches 2h): wrap to the top.
        assert_eq!(next_pace(3600.0), 180);
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
