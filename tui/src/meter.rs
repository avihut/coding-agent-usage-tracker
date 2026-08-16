//! The meter surface's span math: which slice of the published window is
//! on screen, what the zoom ladder can honestly offer, and where the
//! unreachable region falls.
//!
//! Pure, and deliberately the ONLY answer to "what is visible": the chart,
//! the stretch track, the readout and the ←→ scrub all read this one slice,
//! so a cursor can never land on a sample that isn't drawn.
//!
//! Parity note (`Panel/MeterHistoryView.swift`): the app's Sliding span
//! reads 56 days of samples and can cross resets. The digest publishes ONE
//! window per meter — so here Sliding is a trailing sub-range of that
//! window, and the zoom ladder is capped by it. That cap is why the ladder
//! grows downward (1h/2h) where the app's starts at 5h, and why the app's
//! calendar-anchored "this week" frame has no counterpart.

use crate::digest::{LiveMeter, SeriesPoint};
use time::{Duration, OffsetDateTime};

/// The app's popover span picker: a trailing frame ending now, or the limit
/// window itself, start to reset.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Span {
    #[default]
    Sliding,
    Window,
}

impl Span {
    pub fn toggled(self) -> Self {
        match self {
            Self::Sliding => Self::Window,
            Self::Window => Self::Sliding,
        }
    }
}

/// One rung of the zoom ladder.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Frame {
    pub label: &'static str,
    pub seconds: i64,
}

const HOUR: i64 = 3600;
const DAY: i64 = 86400;

/// Every rung the pane knows, shortest first. Which of them a meter can
/// actually offer depends on how much window it publishes.
pub const FRAMES: [Frame; 8] = [
    Frame { label: "last 1h", seconds: HOUR },
    Frame { label: "last 2h", seconds: 2 * HOUR },
    Frame { label: "last 5h", seconds: 5 * HOUR },
    Frame { label: "last 12h", seconds: 12 * HOUR },
    Frame { label: "last 24h", seconds: DAY },
    Frame { label: "last 2 days", seconds: 2 * DAY },
    Frame { label: "last 7 days", seconds: 7 * DAY },
    Frame { label: "last 30 days", seconds: 30 * DAY },
];

/// The domain the digest builder publishes for a meter without a stated
/// limit window — the pane's zoom can't reach past it either.
const UNSTATED_WINDOW: i64 = DAY;

fn window_seconds(meter: &LiveMeter) -> i64 {
    meter
        .limit_window
        .map(|seconds| seconds as i64)
        .filter(|seconds| *seconds > 0)
        .unwrap_or(UNSTATED_WINDOW)
}

/// The rungs this meter can honor: those inside its published window, plus
/// the window itself when nothing else fits (a 1h window would otherwise
/// offer no zoom at all).
pub fn ladder(meter: &LiveMeter) -> Vec<Frame> {
    let window = window_seconds(meter);
    let rungs: Vec<Frame> = FRAMES
        .into_iter()
        .filter(|frame| frame.seconds <= window)
        .collect();
    if rungs.is_empty() {
        vec![Frame { label: "the window", seconds: window }]
    } else {
        rungs
    }
}

/// The rung a meter opens on — the app's own rule (5h windows read at 5h,
/// daily at 24h, weekly at 7d), clamped into what this meter can offer.
pub fn default_rung(meter: &LiveMeter) -> usize {
    let window = window_seconds(meter);
    let wanted = if window <= 6 * HOUR {
        5 * HOUR
    } else if window <= DAY {
        DAY
    } else {
        7 * DAY
    };
    let rungs = ladder(meter);
    rungs
        .iter()
        .rposition(|frame| frame.seconds <= wanted)
        .unwrap_or(rungs.len() - 1)
}

/// A live future reset is what unlocks the Window span — without one the
/// app hides the picker and stays sliding, and so does the pane.
pub fn window_available(meter: &LiveMeter, now: OffsetDateTime) -> bool {
    meter.limit_window.is_some() && meter.resets_at.is_some_and(|reset| reset > now)
}

/// What the meter surface is currently showing.
pub struct View<'a> {
    pub start: OffsetDateTime,
    pub end: OffsetDateTime,
    /// The measured samples inside the domain — a contiguous slice of the
    /// published series, which is what scrub indexes into.
    pub points: &'a [SeriesPoint],
    /// The app's spanLabel: "this session" / "last 5h" / "this week".
    pub label: String,
}

impl View<'_> {
    /// The domain's length in minutes — the chart's x extent.
    pub fn minutes(&self) -> f64 {
        ((self.end - self.start).whole_seconds() as f64 / 60.0).max(1.0)
    }

    /// Where an instant falls on that axis; outside the domain it clamps,
    /// so a caller drawing a marker never leaves the plot.
    pub fn at(&self, t: OffsetDateTime) -> f64 {
        (((t - self.start).whole_seconds() as f64) / 60.0).clamp(0.0, self.minutes())
    }

    pub fn holds(&self, t: OffsetDateTime) -> bool {
        t >= self.start && t <= self.end
    }
}

/// The visible slice. `rung` indexes the meter's own ladder and is clamped,
/// so a zoom level carried over from a wider meter can't fall off the end.
pub fn view<'a>(
    meter: &'a LiveMeter,
    span: Span,
    rung: usize,
    now: OffsetDateTime,
) -> View<'a> {
    let window = window_seconds(meter);
    let (start, end, label) = if span == Span::Window && window_available(meter, now) {
        let reset = meter.resets_at.expect("window_available checked the reset");
        let label = if meter.rank == 0 {
            "this session"
        } else if window >= 6 * DAY {
            "this week"
        } else {
            "this window"
        };
        (reset - Duration::seconds(window), reset, label.to_owned())
    } else {
        let rungs = ladder(meter);
        let frame = rungs[rung.min(rungs.len() - 1)];
        (
            now - Duration::seconds(frame.seconds),
            now,
            frame.label.to_owned(),
        )
    };
    // The series is published in time order, so the domain is one range —
    // slice it rather than filtering, and scrub keeps indexing a slice.
    let first = meter.series.partition_point(|point| point.t < start);
    let last = meter.series.partition_point(|point| point.t <= end);
    View { start, end, points: &meter.series[first..last], label }
}

/// The diagonal fill over the unreachable region: past the projected
/// crossing the limit is already spent, so everything to the right of it is
/// dead time. Points are in the chart's own data space (x minutes from the
/// domain start, y percent), laid out on the braille sub-cell grid the
/// dataset will be rendered with, so the stripes come out at roughly 45°.
///
/// Decoration only — the region's MEANING is stated in words by the
/// header's forecast caption ("runs out Sat 14:00" / "spent at 15:04"), so
/// nothing depends on reading the texture, in color or without it.
pub fn hatch(
    from_x: f64,
    to_x: f64,
    ceiling: f64,
    x_span: f64,
    cols: u16,
    rows: u16,
    spacing: u16,
) -> Vec<(f64, f64)> {
    if to_x <= from_x || cols == 0 || rows == 0 || spacing == 0 || x_span <= 0.0 {
        return Vec::new();
    }
    // Data units per character cell — the conversion that keeps the stripes
    // at one screen angle whatever the domain happens to span. `cols` is
    // the whole chart's width, a cell or four wider than the plot inside
    // its axis gutter: close enough for a texture, and never wrong in a way
    // that changes what the region means.
    let x_per_col = x_span / f64::from(cols);
    let y_per_row = ceiling / f64::from(rows);
    // One point per braille sub-row keeps a stripe a hairline instead of a
    // smear — the whole reason the lattice form read as a solid block.
    let samples = usize::from(rows) * 4;
    let rise = f64::from(rows) * x_per_col;
    let mut points = Vec::new();
    // Start far enough left that the stripes crossing into the region from
    // below are drawn too, not just those born inside it.
    let mut origin = from_x - rise;
    while origin < to_x {
        for step in 0..=samples {
            let y = ceiling * step as f64 / samples as f64;
            let x = origin + (y / y_per_row) * x_per_col;
            if (from_x..=to_x).contains(&x) {
                points.push((x, y));
            }
        }
        origin += f64::from(spacing) * x_per_col;
    }
    points
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::digest::Rgb;
    use time::macros::datetime;

    fn meter(window: Option<f64>, reset: Option<OffsetDateTime>) -> LiveMeter {
        LiveMeter {
            id: "session".into(),
            label: "Session (5h)".into(),
            tag: "S".into(),
            percent: Some(50),
            level: "normal".into(),
            rank: 0,
            risk: Some(Rgb { red: 1.0, green: 0.0, blue: 0.0 }),
            resets_at: reset,
            limit_window: window,
            scoped_model_name: None,
            reset_caption: None,
            forecast: None,
            series: (0..10)
                .map(|step| SeriesPoint {
                    t: datetime!(2026-08-16 06:00 UTC) + Duration::hours(step),
                    percent: 10.0 * step as f64,
                })
                .collect(),
            stretches: vec![],
        }
    }

    #[test]
    fn the_ladder_stops_at_the_published_window() {
        // A 5h window can be zoomed into, never out of.
        let session = meter(Some(5.0 * 3600.0), None);
        let rungs: Vec<&str> = ladder(&session).iter().map(|f| f.label).collect();
        assert_eq!(rungs, ["last 1h", "last 2h", "last 5h"]);
        assert_eq!(ladder(&session)[default_rung(&session)].label, "last 5h");

        let weekly = meter(Some(7.0 * 86400.0), None);
        assert_eq!(ladder(&weekly).len(), 7);
        assert_eq!(ladder(&weekly)[default_rung(&weekly)].label, "last 7 days");

        // No stated window: the digest publishes a 24h domain, so does the
        // ladder — and the default lands on it.
        let bare = meter(None, None);
        assert_eq!(ladder(&bare).last().unwrap().label, "last 24h");
        assert_eq!(ladder(&bare)[default_rung(&bare)].label, "last 24h");

        // A window shorter than every rung still offers itself.
        let tiny = meter(Some(600.0), None);
        assert_eq!(ladder(&tiny).len(), 1);
        assert_eq!(ladder(&tiny)[0].seconds, 600);
    }

    #[test]
    fn the_window_span_needs_a_live_reset() {
        let now = datetime!(2026-08-16 12:00 UTC);
        let past = meter(Some(5.0 * 3600.0), Some(datetime!(2026-08-16 11:00 UTC)));
        assert!(!window_available(&past, now));
        // Asked for Window anyway, it stays sliding — as the app does when
        // it hides the picker.
        let stale = view(&past, Span::Window, 2, now);
        assert_eq!(stale.label, "last 5h");
        assert_eq!(stale.end, now);

        let live = meter(Some(5.0 * 3600.0), Some(datetime!(2026-08-16 14:00 UTC)));
        assert!(window_available(&live, now));
        let framed = view(&live, Span::Window, 2, now);
        assert_eq!(framed.start, datetime!(2026-08-16 09:00 UTC));
        assert_eq!(framed.end, datetime!(2026-08-16 14:00 UTC));
        assert_eq!(framed.label, "this session");
    }

    #[test]
    fn the_visible_slice_is_what_scrub_indexes() {
        let now = datetime!(2026-08-16 12:00 UTC);
        let session = meter(Some(5.0 * 3600.0), Some(datetime!(2026-08-16 14:00 UTC)));
        // Hourly samples 06:00–15:00. A 2h sliding frame holds 10:00–12:00.
        let zoomed = view(&session, Span::Sliding, 1, now);
        assert_eq!(zoomed.points.len(), 3);
        assert_eq!(zoomed.points.first().unwrap().t, datetime!(2026-08-16 10:00 UTC));
        assert_eq!(zoomed.points.last().unwrap().t, now);
        // The window span reaches back further AND forward to the reset.
        let whole = view(&session, Span::Window, 1, now);
        // 09:00 through 14:00 inclusive, hourly.
        assert_eq!(whole.points.len(), 6);
        assert_eq!(whole.minutes(), 300.0);
        // An out-of-domain instant clamps onto the axis instead of escaping.
        assert_eq!(whole.at(datetime!(2026-08-16 05:00 UTC)), 0.0);
        assert_eq!(whole.at(datetime!(2026-08-16 20:00 UTC)), 300.0);
        assert!(!whole.holds(datetime!(2026-08-16 20:00 UTC)));
        // A rung index carried over from a wider meter is clamped, never
        // panicking on the shorter ladder.
        assert_eq!(view(&session, Span::Sliding, 99, now).label, "last 5h");
    }

    #[test]
    fn the_hatch_covers_the_dead_region_and_nothing_before_it() {
        // A 300-minute domain on a 40×10 chart, dead from minute 120.
        let points = hatch(120.0, 300.0, 100.0, 300.0, 40, 10, 5);
        assert!(!points.is_empty());
        assert!(points
            .iter()
            .all(|(x, y)| (120.0..=300.0).contains(x) && (0.0..=100.0).contains(y)));
        // It reaches both edges of the region, so the fill reads as ground
        // rather than a stray diagonal.
        assert!(points.iter().any(|(x, _)| *x < 130.0));
        assert!(points.iter().any(|(x, _)| *x > 290.0));
        // Texture, not a wall: well under one point per braille sub-cell of
        // the region (~24 cols × 10 rows × 8 = 1920).
        assert!(points.len() < 600, "hatch too dense: {}", points.len());
        // A crossing at or past the domain end leaves nothing to hatch.
        assert!(hatch(300.0, 300.0, 100.0, 300.0, 40, 10, 5).is_empty());
        assert!(hatch(120.0, 300.0, 100.0, 300.0, 0, 10, 5).is_empty());
        assert!(hatch(120.0, 300.0, 100.0, 0.0, 40, 10, 5).is_empty());
    }
}
