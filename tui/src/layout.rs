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
        meters: (meter_count.max(1) as u16).min(4) + 1, // +1 section title
        today: 5,                                       // title + 3-row spark + totals
        models: (model_count as u16).min(4) + 1,
    }
}

pub fn plan(area: Rect, meter_count: usize, model_count: usize) -> Plan {
    match shape(area) {
        Shape::Strip => Plan::default(),
        Shape::Portrait => portrait(area, wants(meter_count, model_count)),
        Shape::Landscape => landscape(area, wants(meter_count, model_count)),
    }
}

/// One column, priority flow top-down; heatmap absorbs the remainder when
/// at least 6 rows of it survive.
fn portrait(area: Rect, want: Wants) -> Plan {
    let mut plan = Plan::default();
    let mut y = area.y;
    let bottom = area.y + area.height;
    let take = |rows: u16, y: &mut u16| -> Option<Rect> {
        // The footer's row is reserved off the bottom throughout.
        if *y + rows > bottom - 1 {
            return None;
        }
        let rect = Rect::new(area.x, *y, area.width, rows);
        *y += rows;
        Some(rect)
    };

    plan.header = take(2, &mut y);
    plan.meters = take(want.meters, &mut y);
    plan.today = take(want.today, &mut y);
    plan.models = take(want.models, &mut y);
    let remaining = (bottom - 1).saturating_sub(y);
    if remaining >= 6 {
        plan.heatmap = Some(Rect::new(area.x, y, area.width, remaining));
    }
    plan.footer = Some(Rect::new(area.x, bottom - 1, area.width, 1));
    plan
}

/// Two columns: identity + meters + today on the left, models + the
/// heatmap strip on the right; the footer spans the bottom.
fn landscape(area: Rect, want: Wants) -> Plan {
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
        *y += rows;
        Some(rect)
    };
    plan.header = take(2, &mut y);
    plan.meters = take(want.meters, &mut y);
    plan.today = take(want.today, &mut y);

    let mut ry = right.y;
    let right_bottom = right.y + right.height;
    if ry + want.models <= right_bottom {
        plan.models = Some(Rect::new(right.x, ry, right.width, want.models));
        ry += want.models;
    }
    let remaining = right_bottom.saturating_sub(ry);
    if remaining >= 5 {
        plan.heatmap = Some(Rect::new(right.x, ry, right.width, remaining));
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
        assert!(plan(rect(46, 8), 3, 4).header.is_none());
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
        let full = plan(rect(46, 30), 3, 4);
        assert!(full.header.is_some());
        assert!(full.meters.is_some());
        assert!(full.today.is_some());
        assert!(full.models.is_some());
        assert!(full.heatmap.is_some());
        assert!(full.footer.is_some());

        // 46×22 (still portrait — 46 < 2.1×22): header(2)+meters(4)+
        // today(5)+models(5) = 16, leaving 5 rows — under the heatmap's
        // 6-row minimum, so it drops whole; the footer keeps the last row.
        // (Any pane short enough to also drop models is below the strip
        // floor or landscape by aspect — the ladder's bottom rung in
        // portrait is the heatmap.)
        let short = plan(rect(46, 22), 3, 4);
        assert!(short.header.is_some());
        assert!(short.meters.is_some());
        assert!(short.today.is_some());
        assert!(short.models.is_some());
        assert!(short.heatmap.is_none());
        let footer = short.footer.unwrap();
        assert_eq!(footer.y, 21);
    }

    #[test]
    fn landscape_splits_columns_and_spans_the_footer() {
        let plan = plan(rect(100, 27), 3, 4);
        let (header, models) = (plan.header.unwrap(), plan.models.unwrap());
        assert!(header.x < models.x, "models live in the right column");
        assert!(plan.heatmap.is_some());
        assert_eq!(plan.footer.unwrap().width, 100);
    }

    #[test]
    fn compact_landscape_sacrifices_the_heatmap_before_the_meters() {
        // 72×16 from the design doc: both columns viable, heatmap only if
        // ≥5 rows remain to its right column.
        let plan = plan(rect(72, 16), 3, 4);
        assert!(plan.meters.is_some());
        assert!(plan.models.is_some());
        assert!(plan.heatmap.is_some());
    }
}
