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
/// models left, the activity section full-height right) — a tall pane
/// otherwise blackens its right half.
pub const WIDE_PORTRAIT_MIN_COLS: u16 = 84;

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
    /// The incident banner, when the service is loud enough to earn rows
    /// (rungs 2 and 3 of the prominence ladder). Sits directly under the
    /// header — but never at the meters' expense: a pane that can't seat
    /// both re-plans without it, and the footer rung still speaks.
    pub status: Option<Rect>,
    /// The Notifications section (0.93.0): pending notices with no surface
    /// of their own, between the banner and the meters. Yields exactly as
    /// the banner does — never at the meters' expense; the header dot still
    /// says something is pending.
    pub notices: Option<Rect>,
    pub meters: Option<Rect>,
    pub today: Option<Rect>,
    pub models: Option<Rect>,
    pub heatmap: Option<Rect>,
    /// The sessions shortlist — LAST in priority. It appears only where
    /// rows survive every other section, so adding it can never displace
    /// the meters or the activity chart on a small pane.
    pub sessions: Option<Rect>,
    pub footer: Option<Rect>,
}

/// Title plus at least two rows; anything less reads as a stub.
const SESSIONS_MIN_ROWS: u16 = 3;

/// Rows each section wants — the count it will actually paint, title
/// included. Callers know their own content (how many meters, whether a
/// credits line rides along, which activity form is up), so the layout
/// never guesses and never reserves a row nothing fills.
struct Wants {
    status: u16,
    notices: u16,
    meters: u16,
    today: u16,
    models: u16,
}

/// The quiet-service form — every test that predates the status banner
/// plans through here, which is also the assertion that adding the banner
/// changed nothing about a healthy dashboard.
#[cfg(test)]
pub fn plan(area: Rect, meter_rows: u16, model_rows: u16, activity_rows: u16) -> Plan {
    plan_with_status(area, 0, 0, meter_rows, model_rows, activity_rows)
}

/// The planner proper. `status_rows` is what the incident banner would paint
/// (0 when the service is quiet or only earns the footer rung).
///
/// Status is the one section that yields rather than displaces: if seating it
/// would cost the meters their slot, the pane is re-planned without it. The
/// user came for the meters, and the footer rung still carries the incident.
pub fn plan_with_status(
    area: Rect,
    status_rows: u16,
    notice_rows: u16,
    meter_rows: u16,
    model_rows: u16,
    activity_rows: u16,
) -> Plan {
    let planned = plan_inner(area, status_rows, notice_rows, meter_rows, model_rows, activity_rows);
    if planned.meters.is_some() {
        return planned;
    }
    // Notices go first (the header dot still speaks), then the banner (the
    // footer rung still speaks) — the meters are what the pane is for.
    if notice_rows > 0 {
        let without_notices = plan_inner(area, status_rows, 0, meter_rows, model_rows, activity_rows);
        if without_notices.meters.is_some() || status_rows == 0 {
            return without_notices;
        }
    }
    if status_rows > 0 {
        return plan_inner(area, 0, 0, meter_rows, model_rows, activity_rows);
    }
    planned
}

fn plan_inner(
    area: Rect,
    status_rows: u16,
    notice_rows: u16,
    meter_rows: u16,
    model_rows: u16,
    activity_rows: u16,
) -> Plan {
    let want = Wants {
        status: status_rows,
        notices: notice_rows,
        meters: meter_rows.max(2),
        today: 3, // title + spark + hour axis
        models: model_rows.max(2),
    };
    let activity = activity_rows.max(1);
    match shape(area) {
        Shape::Strip => Plan::default(),
        // A blank row between sections is a luxury, bought only when it
        // costs nothing: whichever plan lands more sections wins, and
        // the breathing room breaks the tie.
        Shape::Portrait if area.width >= WIDE_PORTRAIT_MIN_COLS => pick(
            wide_portrait(area, &want, 1, activity),
            wide_portrait(area, &want, 0, activity),
        ),
        Shape::Portrait => pick(
            portrait(area, &want, 1, activity),
            portrait(area, &want, 0, activity),
        ),
        Shape::Landscape => pick(
            landscape(area, &want, 1, activity),
            landscape(area, &want, 0, activity),
        ),
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

/// One column, priority flow top-down; the activity section absorbs the
/// remainder when at least 6 rows of it survive, up to what it will paint.
fn portrait(area: Rect, want: &Wants, gap: u16, activity: u16) -> Plan {
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
    if want.status > 0 {
        plan.status = take(want.status, &mut y);
    }
    if want.notices > 0 {
        plan.notices = take(want.notices, &mut y);
    }
    plan.meters = take(want.meters, &mut y);
    plan.today = take(want.today, &mut y);
    plan.models = take(want.models, &mut y);
    let remaining = (bottom - 1).saturating_sub(y);
    if remaining >= 6 {
        let height = remaining.min(activity);
        plan.heatmap = Some(Rect::new(area.x, y, area.width, height));
        y += height + gap;
    }
    let leftover = (bottom - 1).saturating_sub(y);
    if leftover >= SESSIONS_MIN_ROWS {
        plan.sessions = Some(Rect::new(area.x, y, area.width, leftover));
    }
    plan.footer = Some(Rect::new(area.x, bottom - 1, area.width, 1));
    plan
}

/// The wide-portrait tier: the priority column keeps the left, the heatmap
/// stands full-height (data-capped) on the right — same two-column idea as
/// landscape, but the pane's tall shape favors the calendar form.
fn wide_portrait(area: Rect, want: &Wants, gap: u16, activity: u16) -> Plan {
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
    if want.status > 0 {
        plan.status = take(want.status, &mut y);
    }
    if want.notices > 0 {
        plan.notices = take(want.notices, &mut y);
    }
    plan.meters = take(want.meters, &mut y);
    plan.today = take(want.today, &mut y);
    plan.models = take(want.models, &mut y);

    let height = body_height.min(activity);
    if height >= 6 {
        plan.heatmap = Some(Rect::new(right.x, right.y, right.width, height));
        let leftover = body_height.saturating_sub(height + gap);
        if leftover >= SESSIONS_MIN_ROWS {
            plan.sessions = Some(Rect::new(
                right.x, right.y + height + gap, right.width, leftover));
        }
    }
    plan.footer = Some(Rect::new(area.x, area.y + area.height - 1, area.width, 1));
    plan
}

/// Two columns: identity + meters + today on the left, models + the
/// heatmap strip on the right; the footer spans the bottom.
fn landscape(area: Rect, want: &Wants, gap: u16, activity: u16) -> Plan {
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
    if want.status > 0 {
        plan.status = take(want.status, &mut y);
    }
    if want.notices > 0 {
        plan.notices = take(want.notices, &mut y);
    }
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
        plan.heatmap = Some(Rect::new(right.x, ry, right.width, remaining.min(activity)));
    }
    // Landscape puts the shortlist in the LEFT column's tail: the right one
    // is already carrying models plus the activity chart.
    let left_leftover = left_bottom.saturating_sub(y);
    if left_leftover >= SESSIONS_MIN_ROWS {
        plan.sessions = Some(Rect::new(left.x, y, left.width, left_leftover));
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
        assert!(plan(rect(46, 8), 4, 5, 56).header.is_none());
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
        let full = plan(rect(46, 30), 4, 5, 56);
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
        let short = plan(rect(40, 20), 4, 5, 56);
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
        let plan = plan(rect(46, 30), 4, 5, 56);
        let (meters, today) = (plan.meters.unwrap(), plan.today.unwrap());
        assert_eq!(today.y, meters.y + meters.height + 1);
        assert!(plan.heatmap.is_some());
    }

    #[test]
    fn breathing_room_is_surrendered_before_a_section_is() {
        // 46×23 portrait: gapped planning would push the heatmap under
        // its 6-row minimum, so the tight plan wins and keeps it.
        let plan = plan(rect(46, 23), 4, 5, 56);
        assert!(plan.heatmap.is_some(), "the gap must never cost a section");
        let (meters, today) = (plan.meters.unwrap(), plan.today.unwrap());
        assert_eq!(today.y, meters.y + meters.height);
    }

    #[test]
    fn landscape_splits_columns_and_spans_the_footer() {
        let plan = plan(rect(100, 27), 4, 5, 56);
        let (header, models) = (plan.header.unwrap(), plan.models.unwrap());
        assert!(header.x < models.x, "models live in the right column");
        assert!(plan.heatmap.is_some());
        assert_eq!(plan.footer.unwrap().width, 100);
    }

    #[test]
    fn compact_landscape_sacrifices_the_heatmap_before_the_meters() {
        // 72×16 from the design doc: both columns viable, heatmap only if
        // ≥5 rows remain to its right column.
        let plan = plan(rect(72, 16), 4, 5, 56);
        assert!(plan.meters.is_some());
        assert!(plan.models.is_some());
        assert!(plan.heatmap.is_some());
    }

    #[test]
    fn the_activity_section_stops_at_what_it_paints() {
        // 46×40 portrait with only 6 weeks of data (title + labels + 6
        // week rows + readout = 9): the section takes 9, not the whole
        // remainder; the reclaimed rows stay blank.
        let plan = plan(rect(46, 40), 4, 5, 9);
        assert_eq!(plan.heatmap.unwrap().height, 9);

        // Same rule in a tall landscape pane, where the weekday-letter
        // strip form asks for its 9 rows and no more.
        let wide = super::plan(rect(120, 56), 4, 5, 9);
        assert_eq!(wide.heatmap.unwrap().height, 9);
    }

    #[test]
    fn wide_portrait_splits_into_two_columns() {
        // 95×110 — the tall tmux pane: portrait by aspect, but wide enough
        // that one column would blacken the right half. The heatmap stands
        // full-height (data-capped) on the right; the priority sections
        // keep the left; the footer spans.
        let plan = plan(rect(95, 110), 4, 5, 56);
        let (header, heatmap) = (plan.header.unwrap(), plan.heatmap.unwrap());
        assert!(header.x < heatmap.x, "heatmap lives in the right column");
        assert_eq!(heatmap.y, 0, "heatmap starts at the top of the pane");
        assert_eq!(heatmap.height, 56, "53 data weeks + title + labels + readout");
        assert!(plan.models.is_some(), "priority sections keep the left column");
        assert_eq!(plan.footer.unwrap().width, 95);
        // Below the wide threshold the single column keeps the pane.
        let narrow = super::plan(rect(60, 80), 4, 5, 56);
        assert_eq!(narrow.heatmap.unwrap().x, 0);
    }
}

#[cfg(test)]
mod status_slot_tests {
    use super::*;

    fn area(width: u16, height: u16) -> Rect {
        Rect::new(0, 0, width, height)
    }

    /// A quiet service costs the dashboard nothing at all.
    #[test]
    fn no_status_rows_leaves_the_plan_untouched() {
        let quiet = plan(area(46, 30), 4, 5, 56);
        let same = plan_with_status(area(46, 30), 0, 0, 4, 5, 56);
        assert!(quiet.status.is_none());
        assert!(same.status.is_none());
        assert_eq!(quiet.meters.unwrap(), same.meters.unwrap());
    }

    /// The banner sits directly under the header, above the meters, in every
    /// shape — the incident is the first thing read, as in the app's panel.
    #[test]
    fn the_banner_sits_between_the_header_and_the_meters() {
        for pane in [area(46, 30), area(95, 110), area(100, 27)] {
            let plan = plan_with_status(pane, 2, 0, 4, 5, 56);
            let header = plan.header.expect("header");
            let status = plan.status.expect("status banner");
            let meters = plan.meters.expect("meters");
            assert!(status.y >= header.y + header.height, "banner is below the header");
            assert!(meters.y >= status.y + status.height, "meters are below the banner");
            assert_eq!(status.height, 2);
        }
    }

    /// D7: status yields rather than displaces. A pane that can seat the
    /// meters without the banner must keep the meters.
    #[test]
    fn the_meters_outrank_the_banner_on_a_cramped_pane() {
        // 40x20 portrait seats header+meters+today+models with 5 rows spare;
        // asking for a 2-row banner would push the models off, and a big
        // enough ask pushes the meters themselves — which is refused.
        for rows in 1..=6u16 {
            let plan = plan_with_status(area(40, 20), rows, 0, 4, 5, 56);
            assert!(
                plan.meters.is_some(),
                "a {rows}-row banner must never cost the meters their slot"
            );
        }
    }

    /// The activity chart is what the banner spends. At 46x22 the quiet plan
    /// seats a 7-row heatmap; asking for two banner rows pushes it under its
    /// 6-row minimum, so it drops WHOLE — while the meters, today and models
    /// all keep their slots. That is the priority order working.
    #[test]
    fn the_banner_is_paid_for_out_of_the_chart() {
        let quiet = plan(area(46, 22), 4, 5, 56);
        assert!(quiet.heatmap.is_some(), "the quiet plan seats a chart");

        let loud = plan_with_status(area(46, 22), 2, 0, 4, 5, 56);
        assert!(loud.status.is_some(), "the banner landed");
        assert!(loud.heatmap.is_none(), "the chart paid for it");
        assert!(loud.meters.is_some(), "the meters did not");
        assert!(loud.today.is_some());
        assert!(loud.models.is_some());
    }

    /// The strip tier has no dashboard, so it has no banner — the footer
    /// rung is the whole story down there.
    #[test]
    fn the_strip_has_no_banner() {
        assert!(plan_with_status(area(38, 8), 2, 0, 3, 4, 8).status.is_none());
    }
}

#[cfg(test)]
mod sessions_slot_tests {
    use super::*;

    fn area(width: u16, height: u16) -> Rect {
        Rect::new(0, 0, width, height)
    }

    /// The shortlist is LAST in priority: a pane too short for it must still
    /// land the meters and the activity chart. Adding a section can never
    /// cost an existing one its slot.
    #[test]
    fn a_short_pane_drops_sessions_before_anything_else() {
        let plan = plan(area(46, 20), 3, 4, 8);
        assert!(plan.meters.is_some());
        assert!(plan.sessions.is_none() || plan.heatmap.is_some());
    }

    /// Given room, it lands — and never overlaps the footer or the chart.
    #[test]
    fn a_tall_pane_seats_sessions_clear_of_its_neighbours() {
        let full = area(60, 60);
        let plan = plan(full, 3, 4, 8);
        let sessions = plan.sessions.expect("tall pane seats sessions");
        let footer = plan.footer.expect("footer");

        assert!(sessions.height >= SESSIONS_MIN_ROWS);
        assert!(sessions.y + sessions.height <= footer.y);
        if let Some(heat) = plan.heatmap {
            assert!(sessions.y >= heat.y + heat.height, "overlaps the chart");
        }
    }

    /// The strip tier has no dashboard at all, so it has no shortlist.
    #[test]
    fn the_strip_has_no_sessions() {
        assert!(plan(area(38, 8), 3, 4, 8).sessions.is_none());
    }

    /// The Notifications section sits between the banner and the meters,
    /// and yields before the banner does when the pane can't seat everyone
    /// — the meters are never the price of either.
    #[test]
    fn notices_sit_under_the_banner_and_yield_first() {
        let roomy = plan_with_status(area(46, 30), 1, 3, 4, 5, 56);
        let (status, notices, meters) =
            (roomy.status.unwrap(), roomy.notices.unwrap(), roomy.meters.unwrap());
        assert!(status.y < notices.y && notices.y < meters.y);
        assert_eq!(notices.height, 3);

        // 40×12 is landscape (40 ≥ 2.1×12): the left column's 11 rows seat
        // header 2 + banner 1 + notices 3 + meters 4 only ungapped — the
        // planner picks the tight plan rather than dropping anyone.
        let tight = plan_with_status(area(40, 12), 1, 3, 4, 5, 56);
        assert!(tight.meters.is_some() && tight.notices.is_some());
        // 40×10: 9 usable rows can't seat all four; the notices go first,
        // the banner stays, the meters never move.
        let tighter = plan_with_status(area(40, 10), 1, 3, 4, 5, 56);
        assert!(tighter.meters.is_some());
        assert!(tighter.status.is_some(), "the banner outranks the notices");
        assert!(tighter.notices.is_none(), "notices yield before the meters");
    }
}
