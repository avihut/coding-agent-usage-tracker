//! The dynamic layout engine: not breakpoints but a decision from the
//! pane's actual shape (design §3). Orientation falls out of cell-aspect
//! math — a terminal cell is roughly twice as tall as it is wide, so a
//! pane reads landscape once cols ≳ 2.1× rows. Below a floor there is no
//! dashboard at all, only the strip. Sections then claim rows in priority
//! order — header, meters, today, models, heatmap, footer — and whatever
//! doesn't fit is dropped whole, never squeezed.

use ratatui::layout::Rect;

pub const STRIP_MIN_ROWS: u16 = 10;
pub const STRIP_MIN_COLS: u16 = 40;
const LANDSCAPE_ASPECT: f64 = 2.1;
/// Portrait panes at least this wide split into two columns (meters/today/
/// models left, the heatmap full-height right) — a tall pane otherwise
/// blackens its right half.
pub const WIDE_PORTRAIT_MIN_COLS: u16 = 84;
/// A landscape heatmap paints title + 7 weekday rows + readout, never more.
const LANDSCAPE_HEAT_ROWS: u16 = 9;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Shape {
    Strip,
    Portrait,
    Landscape,
}

pub fn shape(area: Rect) -> Shape {
    if area.height < STRIP_MIN_ROWS || area.width < STRIP_MIN_COLS {
        Shape::Strip
    } else if f64::from(area.width) >= LANDSCAPE_ASPECT * f64::from(area.height) {
        Shape::Landscape
    } else {
        Shape::Portrait
    }
}

/// Where each dashboard section landed; `None` = dropped for space.
#[derive(Debug, Default, Clone, Copy)]
pub struct Plan {
    pub header: Option<Rect>,
    pub meters: Option<Rect>,
    pub today: Option<Rect>,
    pub models: Option<Rect>,
    pub heatmap: Option<Rect>,
    pub footer: Option<Rect>,
}

/// Rows each section wants (header/footer are fixed; the rest scale with
/// content, capped so no section hogs a small pane).
struct Wants {
    meters: u16,
    today: u16,
    models: u16,
}

fn wants(meter_count: usize, model_count: usize) -> Wants {
    Wants {
        // meter_count includes the credits line when the digest carries
        // spend; min(5) still fits 4 meters + credits.
        meters: (meter_count.max(1) as u16).min(5) + 1, // +1 section title
        today: 3,                                       // title + spark + hour axis
        models: (model_count as u16).min(4) + 1,
    }
}

/// `heat_weeks` is the data's real Monday-aligned week span — the heatmap
/// section is capped at what it can actually paint (title + weekday labels
/// + that many week rows + readout), so a tall pane stops manufacturing
/// empty dot-weeks. Reclaimed rows stay blank.
pub fn plan(area: Rect, meter_count: usize, model_count: usize, heat_weeks: u16) -> Plan {
    let want = wants(meter_count, model_count);
    let heat_cap = heat_weeks.max(1).saturating_add(3);
    match shape(area) {
        Shape::Strip => Plan::default(),
        // A blank row between sections is a luxury, bought only when it
        // costs nothing: whichever plan lands more sections wins, and
        // the breathing room breaks the tie.
        Shape::Portrait if area.width >= WIDE_PORTRAIT_MIN_COLS => pick(
            wide_portrait(area, &want, 1, heat_cap),
            wide_portrait(area, &want, 0, heat_cap),
        ),
        Shape::Portrait => pick(
            portrait(area, &want, 1, heat_cap),
            portrait(area, &want, 0, heat_cap),
        ),
        Shape::Landscape => pick(landscape(area, &want, 1), landscape(area, &want, 0)),
    }
}

fn landed(plan: &Plan) -> usize {
    [plan.meters, plan.today, plan.models, plan.heatmap]
        .iter()
        .filter(|section| section.is_some())
        .count()
}

fn pick(gapped: Plan, tight: Plan) -> Plan {
    if landed(&tight) > landed(&gapped) { tight } else { gapped }
}

/// One column, priority flow top-down; heatmap absorbs the remainder when
/// at least 6 rows of it survive, up to its data cap.
fn portrait(area: Rect, want: &Wants, gap: u16, heat_cap: u16) -> Plan {
    let mut plan = Plan::default();
    let mut y = area.y;
    let bottom = area.y + area.height;
    let take = |rows: u16, y: &mut u16| -> Option<Rect> {
        // The footer's row is reserved off the bottom throughout.
        if *y + rows > bottom - 1 {
            return None;
        }
        let rect = Rect::new(area.x, *y, area.width, rows);
        *y += rows + gap;
        Some(rect)
    };

    plan.header = take(2, &mut y);
    plan.meters = take(want.meters, &mut y);
    plan.today = take(want.today, &mut y);
    plan.models = take(want.models, &mut y);
    let remaining = (bottom - 1).saturating_sub(y);
    if remaining >= 6 {
        plan.heatmap = Some(Rect::new(area.x, y, area.width, remaining.min(heat_cap)));
    }
    plan.footer = Some(Rect::new(area.x, bottom - 1, area.width, 1));
    plan
}

/// The wide-portrait tier: the priority column keeps the left, the heatmap
/// stands full-height (data-capped) on the right — same two-column idea as
/// landscape, but the pane's tall shape favors the calendar form.
fn wide_portrait(area: Rect, want: &Wants, gap: u16, heat_cap: u16) -> Plan {
    let mut plan = Plan::default();
    let body_height = area.height - 1;
    let right_width = (area.width / 2).clamp(24, 40);
    let left = Rect::new(area.x, area.y, area.width - right_width - 1, body_height);
    let right = Rect::new(left.x + left.width + 1, area.y, right_width, body_height);

    let mut y = left.y;
    let left_bottom = left.y + left.height;
    let take = |rows: u16, y: &mut u16| -> Option<Rect> {
        if *y + rows > left_bottom {
            return None;
        }
        let rect = Rect::new(left.x, *y, left.width, rows);
        *y += rows + gap;
        Some(rect)
    };
    plan.header = take(2, &mut y);
    plan.meters = take(want.meters, &mut y);
    plan.today = take(want.today, &mut y);
    plan.models = take(want.models, &mut y);

    let height = body_height.min(heat_cap);
    if height >= 6 {
        plan.heatmap = Some(Rect::new(right.x, right.y, right.width, height));
    }
    plan.footer = Some(Rect::new(area.x, area.y + area.height - 1, area.width, 1));
    plan
}

/// Two columns: identity + meters + today on the left, models + the
/// heatmap strip on the right; the footer spans the bottom.
fn landscape(area: Rect, want: &Wants, gap: u16) -> Plan {
    let mut plan = Plan::default();
    let body_height = area.height - 1;
    let left_width = (area.width / 2).clamp(30, 46);
    let left = Rect::new(area.x, area.y, left_width, body_height);
    let right = Rect::new(
        area.x + left_width + 1,
        area.y,
        area.width - left_width - 1,
        body_height,
    );

    let mut y = left.y;
    let left_bottom = left.y + left.height;
    let take = |rows: u16, y: &mut u16| -> Option<Rect> {
        if *y + rows > left_bottom {
            return None;
        }
        let rect = Rect::new(left.x, *y, left.width, rows);
        *y += rows + gap;
        Some(rect)
    };
    plan.header = take(2, &mut y);
    plan.meters = take(want.meters, &mut y);
    plan.today = take(want.today, &mut y);

    let mut ry = right.y;
    let right_bottom = right.y + right.height;
    if ry + want.models <= right_bottom {
        plan.models = Some(Rect::new(right.x, ry, right.width, want.models));
        ry += want.models + gap;
    }
    let remaining = right_bottom.saturating_sub(ry);
    if remaining >= 5 {
        plan.heatmap = Some(Rect::new(
            right.x,
            ry,
            right.width,
            remaining.min(LANDSCAPE_HEAT_ROWS),
        ));
    }
    plan.footer = Some(Rect::new(
        area.x,
        area.y + area.height - 1,
        area.width,
        1,
    ));
    plan
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rect(w: u16, h: u16) -> Rect {
        Rect::new(0, 0, w, h)
    }

    #[test]
    fn tiny_panes_are_strips() {
        assert_eq!(shape(rect(46, 8)), Shape::Strip);
        assert_eq!(shape(rect(39, 30)), Shape::Strip);
        assert!(plan(rect(46, 8), 3, 4, 53).header.is_none());
    }

    #[test]
    fn aspect_decides_orientation() {
        assert_eq!(shape(rect(46, 24)), Shape::Portrait);
        assert_eq!(shape(rect(72, 16)), Shape::Landscape);
        assert_eq!(shape(rect(100, 27)), Shape::Landscape);
        // 2.1 boundary: 42 cols at 20 rows = 2.1 exactly → landscape.
        assert_eq!(shape(rect(42, 20)), Shape::Landscape);
        assert_eq!(shape(rect(41, 20)), Shape::Portrait);
    }

    #[test]
    fn portrait_keeps_the_priority_order_and_drops_from_the_bottom() {
        let full = plan(rect(46, 30), 3, 4, 53);
        assert!(full.header.is_some());
        assert!(full.meters.is_some());
        assert!(full.today.is_some());
        assert!(full.models.is_some());
        assert!(full.heatmap.is_some());
        assert!(full.footer.is_some());

        // 40×20 (still portrait — 40 < 2.1×20): header(2)+meters(4)+
        // today(3)+models(5) = 14, leaving 5 rows — under the heatmap's
        // 6-row minimum even ungapped, so it drops whole; the footer keeps
        // the last row. (Any pane short enough to also drop models is
        // below the strip floor or landscape by aspect — the ladder's
        // bottom rung in portrait is the heatmap.)
        let short = plan(rect(40, 20), 3, 4, 53);
        assert!(short.header.is_some());
        assert!(short.meters.is_some());
        assert!(short.today.is_some());
        assert!(short.models.is_some());
        assert!(short.heatmap.is_none());
        let footer = short.footer.unwrap();
        assert_eq!(footer.y, 19);
    }

    #[test]
    fn sections_breathe_when_the_room_is_free() {
        // 46×30 portrait has rows to spare: every neighbor pair sits a
        // blank row apart.
        let plan = plan(rect(46, 30), 3, 4, 53);
        let (meters, today) = (plan.meters.unwrap(), plan.today.unwrap());
        assert_eq!(today.y, meters.y + meters.height + 1);
        assert!(plan.heatmap.is_some());
    }

    #[test]
    fn breathing_room_is_surrendered_before_a_section_is() {
        // 46×23 portrait: gapped planning would push the heatmap under
        // its 6-row minimum, so the tight plan wins and keeps it.
        let plan = plan(rect(46, 23), 3, 4, 53);
        assert!(plan.heatmap.is_some(), "the gap must never cost a section");
        let (meters, today) = (plan.meters.unwrap(), plan.today.unwrap());
        assert_eq!(today.y, meters.y + meters.height);
    }

    #[test]
    fn landscape_splits_columns_and_spans_the_footer() {
        let plan = plan(rect(100, 27), 3, 4, 53);
        let (header, models) = (plan.header.unwrap(), plan.models.unwrap());
        assert!(header.x < models.x, "models live in the right column");
        assert!(plan.heatmap.is_some());
        assert_eq!(plan.footer.unwrap().width, 100);
    }

    #[test]
    fn compact_landscape_sacrifices_the_heatmap_before_the_meters() {
        // 72×16 from the design doc: both columns viable, heatmap only if
        // ≥5 rows remain to its right column.
        let plan = plan(rect(72, 16), 3, 4, 53);
        assert!(plan.meters.is_some());
        assert!(plan.models.is_some());
        assert!(plan.heatmap.is_some());
    }

    #[test]
    fn heatmap_height_stops_at_the_data() {
        // 46×40 portrait with only 6 weeks of data: the heatmap gets
        // title + labels + 6 week rows + readout = 9 rows, not the whole
        // remainder; the reclaimed rows stay blank.
        let plan = plan(rect(46, 40), 3, 4, 6);
        assert_eq!(plan.heatmap.unwrap().height, 9);

        // Landscape caps at its 7 fixed weekday rows regardless of data.
        let wide = super::plan(rect(120, 56), 3, 4, 53);
        assert!(wide.heatmap.unwrap().height <= 9);
    }

    #[test]
    fn wide_portrait_splits_into_two_columns() {
        // 95×110 — the tall tmux pane: portrait by aspect, but wide enough
        // that one column would blacken the right half. The heatmap stands
        // full-height (data-capped) on the right; the priority sections
        // keep the left; the footer spans.
        let plan = plan(rect(95, 110), 3, 4, 53);
        let (header, heatmap) = (plan.header.unwrap(), plan.heatmap.unwrap());
        assert!(header.x < heatmap.x, "heatmap lives in the right column");
        assert_eq!(heatmap.y, 0, "heatmap starts at the top of the pane");
        assert_eq!(heatmap.height, 56, "53 data weeks + title + labels + readout");
        assert!(plan.models.is_some(), "priority sections keep the left column");
        assert_eq!(plan.footer.unwrap().width, 95);
        // Below the wide threshold the single column keeps the pane.
        let narrow = super::plan(rect(60, 80), 3, 4, 53);
        assert_eq!(narrow.heatmap.unwrap().x, 0);
    }
}
