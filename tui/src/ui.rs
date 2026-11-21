//! The dashboard renderer. Everything drawn here is a straight projection
//! of the digest — pre-phrased captions, resolved colors, precomputed
//! rollups; the only things the TUI formats itself are clocks and
//! countdowns (design §7). Calm at rest: fixed lines, no layout shift.
//! Every render pass rebuilds the hit map — the mouse resolves against
//! what was actually painted.

use crate::activity::{self, ModelTotal};
use crate::digest::{
    AllAgentsState, DayRollup, HourBucket, LiveState, NoticeCard, NoticesCard, Rgb,
    ServiceStatusCard,
};
use crate::layout::{self, Plan, Shape};
use crate::outline::{self, Kind, Note};
use crate::state::{App, Dimension, Freshness, Hit, Period, Surface};
use crate::surfaces;
pub use consumption::{cost_rollup, model_columns, model_row};
use consumption::{models, today};

mod consumption;
use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};
use std::collections::HashMap;
use std::sync::OnceLock;
use time::{Date, Duration, OffsetDateTime, UtcOffset};

// The app's pinned palette (StatusItemRenderer's values).
pub const WARNING: Color = Color::Rgb(255, 159, 10);
pub const CRITICAL: Color = Color::Rgb(255, 69, 58);
pub const DIM: Color = Color::Rgb(140, 140, 145);
pub const FAINT: Color = Color::Rgb(70, 70, 75);
/// The meter bars' empty track — a quiet solid, the terminal's version of
/// the app's `.quaternary` capsule (the ░ spray read as dots in many fonts).
const TRACK: Color = Color::Rgb(48, 48, 52);
/// The unreachable region's diagonal fill: CRITICAL held well back from the
/// data, the app's own `.red.opacity(0.13)` register.
pub const HATCH: Color = Color::Rgb(80, 22, 19);
/// What a chart that totals several agents is painted in when no model is
/// singled out — no one vendor owns the total (the app's `Color.primary`
/// rule for the merged heatmap).
pub const NEUTRAL: Rgb = Rgb {
    red: 0.80,
    green: 0.80,
    blue: 0.82,
};

/// The color normal-state fills wear: the host Mac's control accent when
/// the digest carries it (the app's bars are `controlAccentColor`-tinted),
/// the provider accent from engines that predate the field.
fn fill_accent(digest: &LiveState) -> Color {
    rgb(digest.engine.system_accent.unwrap_or(digest.engine.accent))
}

/// Every colored span routes here: NO_COLOR turns it into a plain style
/// so risk falls back to the glyph dialect (markers, density ramps).
pub fn style(color: Color) -> Style {
    if crate::state::look().no_color {
        Style::new()
    } else {
        Style::new().fg(color)
    }
}

/// The drawing alphabet — UTF-8 blocks, or ASCII when the locale can't.
pub struct Glyphs {
    pub bar_fill: &'static str,
    pub bar_empty: &'static str,
    pub spark: [char; 8],
    pub dot: &'static str,
    pub heat_density: [&'static str; 4],
    pub nub_active: &'static str,
    pub nub_idle: &'static str,
    pub live: &'static str,
    pub hollow: &'static str,
    pub backoff: &'static str,
    pub sep: &'static str,
    pub back: &'static str,
    pub pager_left: &'static str,
    pub pager_right: &'static str,
    pub prompt_cell: &'static str,
    pub ellipsis: char,
}

pub fn glyphs() -> &'static Glyphs {
    if crate::state::look().ascii {
        &Glyphs {
            bar_fill: "#",
            bar_empty: ".",
            spark: ['.', ',', ':', ';', '=', '+', '*', '#'],
            dot: ".",
            heat_density: [".", ":", "*", "#"],
            nub_active: "=",
            nub_idle: ".",
            live: "* ",
            hollow: "o ",
            backoff: "~ ",
            sep: " - ",
            back: "<- back",
            pager_left: "<",
            pager_right: ">",
            prompt_cell: ", ",
            ellipsis: '~',
        }
    } else {
        &Glyphs {
            bar_fill: "█",
            bar_empty: "░",
            spark: ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'],
            dot: "·",
            heat_density: ["░", "▒", "▓", "█"],
            nub_active: "▬",
            nub_idle: "░",
            live: "● ",
            hollow: "○ ",
            backoff: "◌ ",
            sep: " · ",
            back: "← back",
            pager_left: "‹",
            pager_right: "›",
            prompt_cell: "▪ ",
            ellipsis: '…',
        }
    }
}

pub fn rgb(color: Rgb) -> Color {
    Color::Rgb(
        (color.red * 255.0).round() as u8,
        (color.green * 255.0).round() as u8,
        (color.blue * 255.0).round() as u8,
    )
}

/// Terminal "alpha": scale toward black, the committed dark ground.
pub fn ramp(color: Rgb, alpha: f64) -> Color {
    Color::Rgb(
        (color.red * alpha * 255.0).round() as u8,
        (color.green * alpha * 255.0).round() as u8,
        (color.blue * alpha * 255.0).round() as u8,
    )
}

/// "12.3K", "1.2M" — TokenFormat.compact's tiers, ported.
pub fn compact(count: i64) -> String {
    let value = count as f64;
    let trimmed = |v: f64| {
        let text = if v >= 100.0 {
            format!("{v:.0}")
        } else {
            format!("{v:.1}")
        };
        text.strip_suffix(".0").map(str::to_owned).unwrap_or(text)
    };
    match count {
        c if c < 1_000 => format!("{c}"),
        c if c < 1_000_000 => format!("{}K", trimmed(value / 1_000.0)),
        c if c < 1_000_000_000 => format!("{}M", trimmed(value / 1_000_000.0)),
        _ => format!("{}B", trimmed(value / 1_000_000_000.0)),
    }
}

/// "$4.20", "$1,234", "<$0.01" — UsageFormatting.money's tiers, ported so
/// every surface spells money the way the app does. An unpriced figure is
/// never routed here: absent renders as "—", never $0.
pub fn money(dollars: f64) -> String {
    if dollars > 0.0 && dollars < 0.01 {
        return "<$0.01".into();
    }
    let digits = if dollars >= 100.0 { 0 } else { 2 };
    let text = format!("{dollars:.digits$}");
    let (whole, fraction) = match text.split_once('.') {
        Some((whole, fraction)) => (whole, Some(fraction)),
        None => (text.as_str(), None),
    };
    // Thousands separators, inserted from the right.
    let mut grouped = String::new();
    for (index, ch) in whole.chars().enumerate() {
        if index > 0 && (whole.len() - index) % 3 == 0 {
            grouped.push(',');
        }
        grouped.push(ch);
    }
    match fraction {
        Some(fraction) => format!("${grouped}.{fraction}"),
        None => format!("${grouped}"),
    }
}

fn clock(at: OffsetDateTime, offset: UtcOffset) -> String {
    let local = at.to_offset(offset);
    format!("{:02}:{:02}", local.hour(), local.minute())
}

/// "4m ago" — how long since something happened, at the precision a
/// glance needs.
fn ago(age: Duration) -> String {
    let seconds = age.whole_seconds().max(0);
    let minutes = seconds / 60;
    if minutes >= 60 {
        format!("{}h {}m ago", minutes / 60, minutes % 60)
    } else if minutes > 0 {
        format!("{minutes}m ago")
    } else {
        format!("{seconds}s ago")
    }
}

fn countdown(to: OffsetDateTime, now: OffsetDateTime) -> String {
    let seconds = (to - now).whole_seconds();
    if seconds <= 0 {
        return "any moment".into();
    }
    let (minutes, secs) = (seconds / 60, seconds % 60);
    if minutes >= 60 {
        format!("{}h {}m", minutes / 60, minutes % 60)
    } else if minutes > 0 {
        format!("{minutes}m {secs:02}s")
    } else {
        format!("{secs}s")
    }
}

/// The notices the section lists: everything pending that has no surface of
/// its own. An ongoing outage rides the status banner (and the footer rung),
/// so it never repeats here.
pub fn listed_notices(card: Option<&NoticesCard>) -> Vec<&NoticeCard> {
    card.map(|card| {
        card.items
            .iter()
            .filter(|item| !item.owns_menu_bar_surface)
            .collect()
    })
    .unwrap_or_default()
}

/// Rows the Notifications section wants: a title plus one per listed
/// notice, capped so a pile-up can't push the meters off a small pane.
pub fn notice_rows(card: Option<&NoticesCard>) -> u16 {
    let count = listed_notices(card).len().min(4) as u16;
    if count == 0 { 0 } else { count + 1 }
}

/// A notice row's rail color: the vendor's own act wears the accent, a
/// running incident its severity, an ended one grey.
fn notice_color(item: &NoticeCard, accent: Color) -> Color {
    match item.kind.as_str() {
        "reset" => accent,
        "outage" if item.ongoing => status_color(item.severity.as_deref().unwrap_or("")),
        _ => DIM,
    }
}

/// The Notifications section: a rail, the title (with the impact for
/// outages), the detail as room allows, the time line and — for a
/// dismissable notice — a × at the row's end. Words verbatim from the
/// digest; the `×` column is what `hits` registers for a click.
fn notices_section<'a>(items: &[&'a NoticeCard], accent: Color, rect: Rect) -> Paragraph<'a> {
    let mut lines = vec![section_title("Notifications")];
    let rail = if crate::state::look().ascii {
        "| "
    } else {
        "▍ "
    };
    let cross = if crate::state::look().ascii {
        "x"
    } else {
        "×"
    };
    for item in items {
        let color = notice_color(item, accent);
        let mut tail = format!("  {}", item.when);
        if item.dismissable {
            tail.push_str(&format!("  {cross}"));
        }
        let mut spans = vec![Span::styled(rail.to_owned(), style(color))];
        let mut head = item.title.clone();
        if let Some(severity) = &item.severity {
            head.push_str(&format!("{}{}", glyphs().sep, severity));
        }
        let fixed = rail.chars().count() + tail.chars().count();
        let room = (rect.width as usize).saturating_sub(fixed);
        let title_len = head.chars().count().min(room);
        spans.push(Span::styled(
            truncate(&head, title_len.max(4)),
            Style::new().add_modifier(Modifier::BOLD),
        ));
        // The detail fills whatever the title left, never cramping it; the
        // time line and × are then padded out to the row's right edge, so
        // the × always sits in the last cell (where the hit map expects it).
        let left = room.saturating_sub(title_len);
        let mut used = title_len;
        if let Some(detail) = &item.detail
            && left > 8
        {
            let shown = truncate(detail, left - 2);
            used += 2 + shown.chars().count();
            spans.push(Span::styled(format!("  {shown}"), style(DIM)));
        }
        spans.push(Span::raw(" ".repeat(room.saturating_sub(used))));
        spans.push(Span::styled(tail, style(DIM)));
        lines.push(Line::from(spans));
    }
    Paragraph::new(lines)
}

/// How loudly the service's health speaks, in rows of dashboard it earns.
/// Severity buys prominence and quiet buys silence — the terminal's answer
/// to the app's dot-then-badge-then-banner escalation.
///
/// 0 = the footer alone (a green cell when fine, a tinted note at minor);
/// 1 = a banner row under the header; 2 = that plus the latest message.
pub fn status_rungs(card: Option<&ServiceStatusCard>) -> u16 {
    let Some(card) = card else { return 0 };
    match card
        .active_incident()
        .map(|incident| incident.impact.as_str())
    {
        Some("critical") => 2,
        Some("major") => 1,
        // Minor rides the footer; maintenance and unknown never take rows.
        _ => 0,
    }
}

/// The indicator's color. `unknown` is deliberately DIM rather than a
/// warning tone: not knowing is not an alarm.
fn status_color(indicator: &str) -> Color {
    match indicator {
        "none" => Color::Rgb(52, 199, 106),
        "minor" => Color::Rgb(230, 197, 74),
        "major" => WARNING,
        "critical" => CRITICAL,
        "maintenance" => Color::Rgb(77, 163, 245),
        _ => DIM,
    }
}

/// The monochrome dialect (design §5, as `status.rs` speaks it): with color
/// off, severity has to arrive as text.
fn status_marker(indicator: &str) -> &'static str {
    match indicator {
        "minor" => "[MINOR] ",
        "major" => "[MAJOR] ",
        "critical" => "[CRITICAL] ",
        "maintenance" => "[MAINT] ",
        "unknown" => "[?] ",
        _ => "",
    }
}

/// The incident banner (rungs 1 and 2). A colored rail, the impact, the
/// name, its phase and how long it has run — and at rung 2 the latest
/// update's text on a second row.
fn status_banner<'a>(
    card: &'a ServiceStatusCard,
    now: OffsetDateTime,
    width: u16,
) -> Paragraph<'a> {
    Paragraph::new(status_banner_lines(card, now, width))
}

/// The banner's rows, built pure so the ladder's shape is testable without
/// a terminal: rung 1 is the headline alone, rung 2 adds the message.
fn status_banner_lines<'a>(
    card: &'a ServiceStatusCard,
    now: OffsetDateTime,
    width: u16,
) -> Vec<Line<'a>> {
    let Some(incident) = card.active_incident() else {
        return Vec::new();
    };
    let color = status_color(&incident.impact);
    let rail = if crate::state::look().ascii {
        "| "
    } else {
        "▍ "
    };

    let mut head = vec![
        Span::styled(rail.to_owned(), style(color)),
        Span::styled(
            incident.impact.to_uppercase(),
            style(color).add_modifier(Modifier::BOLD),
        ),
        Span::styled("  ".to_owned(), style(DIM)),
    ];
    // The name gets whatever the fixed parts leave: rail + impact + phase and
    // duration on the right, all of which must survive a narrow pane.
    let tail = format!(
        "{}{}{}",
        incident.phase,
        glyphs().sep,
        worked(incident.duration_seconds(now))
    );
    let spent =
        rail.chars().count() + incident.impact.chars().count() + 2 + tail.chars().count() + 2;
    let room = (width as usize).saturating_sub(spent);
    // Bare bold, not a pinned color: the name inherits the terminal's own
    // foreground, so it reads on any theme the user runs.
    head.push(Span::styled(
        truncate(&incident.name, room.max(8)),
        Style::new().add_modifier(Modifier::BOLD),
    ));
    head.push(Span::styled("  ".to_owned(), style(DIM)));
    head.push(Span::styled(tail, style(color)));

    let mut lines = vec![Line::from(head)];
    if status_rungs(Some(card)) >= 2
        && let Some(message) = &incident.last_message
    {
        // No marker here: the headline row above already spells the
        // impact in plain text, colour or not.
        let room = (width as usize).saturating_sub(rail.chars().count());
        lines.push(Line::from(vec![
            Span::styled(rail.to_owned(), style(color)),
            Span::styled(truncate(message, room), style(DIM)),
        ]));
    }
    lines
}

/// The footer's own rung — the terminal counterpart of the app's footer dot.
/// A quiet service is one green cell; a minor incident borrows the footer's
/// right half rather than taking a row of its own.
fn status_footer_spans(
    card: Option<&ServiceStatusCard>,
    now: OffsetDateTime,
) -> Vec<Span<'static>> {
    let Some(card) = card else { return Vec::new() };
    let color = status_color(&card.indicator);
    let mono = crate::state::look().no_color;
    let mark = match card.indicator.as_str() {
        "unknown" => glyphs().hollow.trim_end().to_owned(),
        _ => glyphs().live.trim_end().to_owned(),
    };

    // Rungs 1 and 2 already carry the incident in the banner; the footer
    // then stays a bare mark so the same words aren't printed twice.
    let detail = match card.active_incident() {
        Some(incident) if status_rungs(Some(card)) == 0 => Some(format!(
            " {}{}{}",
            truncate(&incident.name, 22),
            glyphs().sep,
            worked(incident.duration_seconds(now))
        )),
        _ => None,
    };

    if mono {
        // Without colour a bare mark carries nothing, so the footer speaks
        // only when it has words worth printing: a healthy service says
        // nothing, and an incident already banner-ed above isn't repeated.
        let Some(detail) = detail else {
            return Vec::new();
        };
        return vec![Span::styled(
            format!("  {}{}", status_marker(&card.indicator).trim_end(), detail),
            style(DIM),
        )];
    }
    let mut spans = vec![Span::styled(format!("  {mark}"), style(color))];
    if let Some(detail) = detail {
        spans.push(Span::styled(detail, style(color)));
    }
    spans
}

pub fn truncate(text: &str, width: usize) -> String {
    if text.chars().count() <= width {
        text.to_owned()
    } else {
        let mut out: String = text.chars().take(width.saturating_sub(1)).collect();
        out.push(glyphs().ellipsis);
        out
    }
}

/// A meter label cut to `width`, keeping a trailing parenthetical when it
/// fits with at least four characters of the head: two meters of one pool
/// ("Claude + GPT (5h)", "Claude + GPT (7d)") differ only there, and a
/// plain cut would print both as "Claude + GP…". Otherwise as `truncate`.
pub fn truncate_label(text: &str, width: usize) -> String {
    if text.chars().count() <= width {
        return text.to_owned();
    }
    if text.ends_with(')')
        && let Some(open) = text.rfind(" (")
    {
        let suffix = &text[open..];
        let room = width.saturating_sub(suffix.chars().count() + 1);
        if room >= 4 {
            let head: String = text[..open].chars().take(room).collect();
            return format!("{}{}{suffix}", head.trim_end(), glyphs().ellipsis);
        }
    }
    truncate(text, width)
}

/// Greedy word wrap for the pane's few prose lines. A word longer than the
/// whole width goes on its own line and overflows rather than being cut —
/// the caller decides whether that many lines are affordable at all.
pub fn wrap_words(text: &str, width: usize) -> Vec<String> {
    if width == 0 {
        return Vec::new();
    }
    let mut lines: Vec<String> = Vec::new();
    for word in text.split_whitespace() {
        match lines.last_mut() {
            Some(line) if line.chars().count() + 1 + word.chars().count() <= width => {
                line.push(' ');
                line.push_str(word);
            }
            _ => lines.push(word.to_owned()),
        }
    }
    lines
}

pub fn render(frame: &mut Frame, app: &mut App, now: OffsetDateTime) {
    // The effective hot element: mouse hover or the keyboard cursor,
    // whichever device spoke last. A cursor whose target vanished from
    // the last frame (paged away, surface changed) is dropped, never
    // ghosted. Everything hover-reactive reads hover_hit, so the
    // keyboard cursor inherits every hover treatment.
    let mouse = app.pointer.and_then(|(x, y)| app.hits.at(x, y).cloned());
    let focus = app
        .focus_hit
        .take()
        .filter(|hit| app.hits.rect_of(hit).is_some());
    app.hover_hit = if app.keyboard_mode {
        focus.clone().or(mouse)
    } else {
        mouse.or(focus.clone())
    };
    // The halo band is painted after the widgets, from last frame's
    // geometry — the same one the hit resolved against.
    let halo = app.hover_hit.as_ref().and_then(|hit| app.hits.rect_of(hit));
    app.focus_hit = focus;
    app.hits.clear();
    let area = frame.area();
    let Some(digest) = app.digest.clone() else {
        // No digest yet, but a host holds the lease: starting under load,
        // not absent — and nothing to install.
        let busy = app.freshness(now) == Freshness::Busy;
        render_offline(frame, area, app, busy);
        return;
    };
    let freshness = app.freshness(now);
    if layout::shape(area) == Shape::Strip {
        render_strip(frame, area, &digest, freshness, now);
        return;
    }

    let data = Dash::build(app, &digest, area, now);

    match app.surface.clone() {
        Surface::Dashboard => {
            let plan = dashboard_plan(area, &digest, &data);
            render_dashboard(frame, app, &digest, freshness, &plan, &data, now);
        }
        surface => {
            if surfaces::split_viable(area) {
                // Side-by-side: the dashboard keeps the left region, the
                // surface owns the right (design §3, landscape).
                let left_width = (area.width / 2).clamp(40, 60);
                let left = Rect::new(area.x, area.y, left_width, area.height);
                let right = Rect::new(
                    area.x + left_width + 1,
                    area.y,
                    area.width - left_width - 1,
                    area.height,
                );
                let plan = dashboard_plan(left, &digest, &data);
                render_dashboard(frame, app, &digest, freshness, &plan, &data, now);
                render_surface(frame, app, &digest, &surface, right, false, now);
            } else {
                render_surface(frame, app, &digest, &surface, area, true, now);
            }
        }
    }
    if app.show_help {
        render_help(frame, area);
    } else if let Some(rect) = halo {
        highlight_band(frame, rect);
    }
}

/// The dashboard's plan. Sections drop whole, so the outline's extra rows
/// must never cost the pane a section it would otherwise show (MODELS
/// itself, or the activity chart below it): every MODELS size from the full
/// outline down to its agent rows alone is tried, and the largest that
/// lands the most sections wins (docs/TUI.md, the degrade).
fn dashboard_plan(area: Rect, digest: &LiveState, data: &Dash) -> Plan {
    let plan_with = |model_rows: u16| {
        layout::plan_with_status(
            area,
            status_rungs(digest.service_status.as_ref()),
            notice_rows(digest.notices.as_ref()),
            data.meter_rows,
            model_rows,
            data.activity_rows,
        )
    };
    let mut best = plan_with(data.model_rows);
    for rows in (data.compact_model_rows..data.model_rows).rev() {
        let candidate = plan_with(rows);
        if layout::landed(&candidate) > layout::landed(&best) {
            best = candidate;
        }
    }
    best
}

/// The selection halo, painted over whatever the widgets left in the
/// band: bold plus a lifted foreground — the modern register, no
/// background slab. Cells wearing the terminal's default color take
/// bold alone (an explicit "bright" literal would fight light themes).
/// NO_COLOR keeps REVERSED: bold barely registers on the monochrome
/// density glyphs, and that dialect already trades nuance for clarity.
fn highlight_band(frame: &mut Frame, rect: Rect) {
    let no_color = crate::state::look().no_color;
    let area = frame.area();
    let buffer = frame.buffer_mut();
    for y in rect.top()..rect.bottom().min(area.bottom()) {
        for x in rect.left()..rect.right().min(area.right()) {
            if let Some(cell) = buffer.cell_mut(ratatui::layout::Position::new(x, y)) {
                let mut lift = Style::new().add_modifier(if no_color {
                    Modifier::REVERSED
                } else {
                    Modifier::BOLD
                });
                if !no_color && let Color::Rgb(r, g, b) = cell.fg {
                    lift = lift.fg(brighten(r, g, b));
                }
                cell.set_style(lift);
            }
        }
    }
}

/// Lift a color ~45% toward white — enough to read as "lit", not enough
/// to wash the hue out.
fn brighten(r: u8, g: u8, b: u8) -> Color {
    let lift = |c: u8| c + ((255 - u16::from(c)) * 45 / 100) as u8;
    Color::Rgb(lift(r), lift(g), lift(b))
}

fn render_surface(
    frame: &mut Frame,
    app: &mut App,
    digest: &LiveState,
    surface: &Surface,
    rect: Rect,
    pushed: bool,
    now: OffsetDateTime,
) {
    match surface {
        Surface::Meter(index) => {
            surfaces::render_meter(frame, app, digest, *index, rect, pushed, now);
        }
        Surface::Day(day_key) => {
            surfaces::render_day(frame, app, digest, day_key, rect, pushed);
        }
        Surface::Dashboard => {}
    }
}

/// What every dashboard section must agree on before a single row is
/// planned: the scoped day span, its per-model rollup (ONE list, so a
/// hovered row means the same model to the table and to the chart), and
/// the row count each section will actually paint.
struct Dash {
    today: Date,
    start: String,
    end: String,
    start_date: Date,
    end_date: Date,
    /// The period's models in the bars' stacking order (outline order
    /// under "All agents", heaviest first otherwise).
    models: Vec<ModelTotal>,
    /// MODELS' rows: the agent ▸ model outline, or one account's models.
    rows: Vec<outline::Row>,
    /// The rows span agents (the outline is up).
    outlined: bool,
    /// The per-model horizon starts inside the span — the table speaks for
    /// less than the period claims and must say so.
    models_truncated: bool,
    /// Weeks the calendar forms will draw, capped by period and data.
    weeks: u16,
    /// The engine's forecast-maturity countdown, phrased once by the
    /// engine. Set only under the 7D bars, where the app prints it.
    activation_note: Option<String>,
    meter_rows: u16,
    model_rows: u16,
    /// MODELS at its smallest useful size — what the plan falls back to
    /// before the section would drop.
    compact_model_rows: u16,
    activity_rows: u16,
}

/// What a hovered or focused MODELS row singles out in the charts: its own
/// figures and every model key it counts (an agent row, all of its models).
struct Filter {
    total: ModelTotal,
    keys: Vec<String>,
}

impl Filter {
    fn covers(&self, key: &str) -> bool {
        self.keys.iter().any(|k| k == key)
    }
}

impl Dash {
    /// The 7D bars: title, plot, weekday row, date row, readout. Unlike
    /// the calendar forms — whose rows are pinned to real weeks — the plot
    /// simply grows into whatever the pane spares, up to this ceiling.
    const BAR_ROWS: u16 = 16;
    /// The landscape weekday-letter strip: title, 7 letters, readout.
    const STRIP_ROWS: u16 = 9;

    fn build(app: &App, digest: &LiveState, area: Rect, now: OffsetDateTime) -> Self {
        let today = now.to_offset(app.local_offset).date();
        let all = app.all_agents(digest);
        let reading = app.reading(digest);
        let days = &reading.days;
        let (start, end) = activity::span(app.period, app.heat_page, today, days);
        let (start_key, end_key) = (activity::day_key(start), activity::day_key(end));
        let (start_date, end_date) = (start, end);
        let totals = activity::model_totals(reading, &start_key, &end_key);
        let breakdown = match all {
            Some(all) => outline::build(totals, all, digest.harnesses.as_deref()),
            None => outline::flat(totals),
        };
        let outlined = breakdown.rows.iter().any(outline::Row::is_agent);
        // An outline is agents plus models: it may ask for a little more
        // than four rows, and gives rows back (models first, then agents —
        // `outline::seat`) down to a single one rather than cost the pane a
        // section one account's view would show.
        let (model_rows, compact_model_rows) = if outlined {
            (breakdown.rows.len().min(6) as u16 + 2, 1 + 2)
        } else {
            let rows = breakdown.rows.len().min(4) as u16 + 2;
            (rows, rows)
        };
        let weeks = match app.period {
            Period::Week => 1,
            // A 30D calendar shows all 30 days whether or not they carry
            // work — its rows are the weeks that window touches, blanks
            // included, exactly as the app draws it.
            Period::Month => {
                let lead = u16::from(start.weekday().number_days_from_monday());
                (lead + 30).div_ceil(7)
            }
            Period::All => data_weeks(days, today),
        };
        // The app prints the maturity countdown directly under its 7D bars
        // and goes silent once the profile is live; the pane does the same.
        // A digest without the field at all (an engine that predates it)
        // says nothing rather than guessing a countdown.
        // One account's limit rhythm: it steps aside when agents are totalled,
        // as the app's typical-week caption does.
        let activation_note = match app.period {
            Period::Week if all.is_none() => digest
                .engine
                .forecast_profile
                .as_ref()
                .and_then(|profile| profile.caption.clone()),
            _ => None,
        };
        let activity_rows = match app.period {
            Period::Week => Self::BAR_ROWS + u16::from(activation_note.is_some()),
            // Only the all-time grid takes the landscape weekday strip.
            Period::All if layout::shape(area) == Shape::Landscape => Self::STRIP_ROWS,
            // title + weekday header + week rows + readout
            _ => weeks + 3,
        };
        Self {
            today,
            models_truncated: activity::model_horizon_truncates(reading, &start_key),
            start: start_key,
            end: end_key,
            start_date,
            end_date,
            model_rows,
            compact_model_rows,
            models: breakdown.models,
            rows: breakdown.rows,
            outlined,
            weeks,
            activation_note,
            // The credits line rides inside the meters section when the
            // provider sent one.
            meter_rows: digest.meters.len() as u16 + u16::from(digest.engine.spend.is_some()) + 1,
            activity_rows,
        }
    }

    /// What the pane is currently singling out, if anything — the one hover
    /// treatment every activity form reads. A row that counts no model (an
    /// agent still scanning) singles out nothing, and dims nothing.
    fn filter(&self, app: &App) -> Option<Filter> {
        match &app.hover_hit {
            Some(Hit::ModelRow(id)) => {
                let row = self.rows.iter().find(|row| &row.id == id)?;
                (!row.keys.is_empty()).then(|| Filter {
                    total: row.total.clone(),
                    keys: row.keys.clone(),
                })
            }
            _ => None,
        }
    }
}

fn render_dashboard(
    frame: &mut Frame,
    app: &mut App,
    digest: &LiveState,
    freshness: Freshness,
    plan: &Plan,
    data: &Dash,
    now: OffsetDateTime,
) {
    let accent = rgb(digest.engine.accent);
    if let Some(rect) = plan.header {
        let (line, marks) = header(digest, freshness, app, now, accent, rect.width);
        frame.render_widget(line, rect);
        // Another harness's cell, wherever the line seated it whole, pins
        // focus on that account when clicked or entered — the menu bar's
        // click on a mark. Only accounts the engine will focus are offered.
        let candidates = crate::state::focus_candidates(digest);
        for (column, width, key) in marks {
            if column + width <= usize::from(rect.width)
                && candidates.iter().any(|profile| profile.id == key)
            {
                app.hits.add(
                    Rect::new(rect.x + column as u16, rect.y, width as u16, 1),
                    Hit::Account(key),
                );
            }
        }
    }
    if let Some(rect) = plan.notices {
        let items = listed_notices(digest.notices.as_ref());
        frame.render_widget(notices_section(&items, accent, rect), rect);
        for (index, item) in items
            .iter()
            .take((rect.height.max(1) - 1) as usize)
            .enumerate()
        {
            let row = Rect::new(rect.x, rect.y + 1 + index as u16, rect.width, 1);
            app.hits.add(row, Hit::Notice(item.id.clone()));
            if item.dismissable && rect.width >= 2 {
                // The × is the last cell; registered after the row so it
                // wins the hit (later additions win).
                app.hits.add(
                    Rect::new(rect.x + rect.width - 1, row.y, 1, 1),
                    Hit::NoticeDismiss(item.id.clone()),
                );
            }
        }
    }
    if let Some(rect) = plan.meters {
        frame.render_widget(meters(digest, freshness, rect), rect);
        // The credits line (when spend rides along) takes the last row and
        // is not a meter — no hit region for it.
        let hit_rows = ((rect.height.max(1) - 1) as usize)
            .saturating_sub(usize::from(digest.engine.spend.is_some()));
        for (index, _) in digest.meters.iter().take(hit_rows).enumerate() {
            app.hits.add(
                Rect::new(rect.x, rect.y + 1 + index as u16, rect.width, 1),
                Hit::Meter(index),
            );
        }
    }
    let all = app.all_agents(digest);
    if let Some(rect) = plan.today {
        frame.render_widget(today(digest, all, accent, rect, app.local_offset), rect);
    }
    if let Some(rect) = plan.models {
        // Rows the section can seat: its height minus the title and the
        // cost rollup line that closes it.
        let seats = (rect.height as usize).saturating_sub(2);
        let (shown, hidden) = outline::seat(&data.rows, seats);
        // One account still on its first scan says so; the all-agents
        // outline carries its own "partial" / "no total yet" rules.
        let scanning = all.is_none() && activity_scanning(digest);
        frame.render_widget(models(app, data, &shown, hidden, rect, scanning), rect);
        for (position, index) in shown.iter().enumerate() {
            app.hits.add(
                Rect::new(rect.x, rect.y + 1 + position as u16, rect.width, 1),
                Hit::ModelRow(data.rows[*index].id.clone()),
            );
        }
    }
    if let Some(rect) = plan.heatmap {
        if all.is_none() && activity_scanning(digest) {
            // Absent, never an empty chart reading "0 tokens".
            frame.render_widget(scanning_lines("ACTIVITY"), rect);
        } else {
            match app.period {
                Period::Week => render_bars(frame, app, digest, data, rect),
                _ => render_heatmap(frame, app, digest, data, rect),
            }
        }
    }
    if let Some(rect) = plan.sessions {
        // Under "All agents" the shortlist is still the focused account's —
        // its title says whose, so it can't read as everyone's.
        let owner = all.map(|_| {
            digest.focused_profile.as_deref().map_or_else(
                || digest.engine.agent_name.clone(),
                |key| crate::state::account_name(digest, key),
            )
        });
        frame.render_widget(sessions(digest, owner.as_deref(), accent, rect, app.local_offset), rect);
    }
    if let Some(rect) = plan.status
        && let Some(card) = digest.service_status.as_ref()
    {
        frame.render_widget(status_banner(card, now, rect.width), rect);
    }
    if let Some(rect) = plan.footer {
        frame.render_widget(footer(digest, freshness, app, now, rect.width), rect);
    }
}

fn section_title(text: &str) -> Line<'static> {
    Line::from(Span::styled(
        text.to_owned(),
        style(DIM).add_modifier(Modifier::BOLD),
    ))
}

/// One other harness in the header's miniature: its mark and colour, and
/// each of its menu bar cells as (account key, digits).
struct OtherHarness {
    glyph: String,
    accent: crate::digest::Rgb,
    cells: Vec<(String, String)>,
}

/// Every SHOWN harness other than the focused account's. Empty for a writer
/// that meters one, so a one-harness header is exactly what it was.
fn other_harnesses(digest: &LiveState) -> Vec<OtherHarness> {
    let (Some(harnesses), Some(cells)) =
        (digest.harnesses.as_ref(), digest.menu_bar_cells.as_ref())
    else {
        return Vec::new();
    };
    let focused = digest
        .focused_profile
        .as_ref()
        .and_then(|id| digest.profiles.as_ref()?.iter().find(|p| &p.id == id))
        .map(|profile| profile.provider_id.clone());
    harnesses
        .iter()
        .filter(|harness| harness.shown && Some(&harness.id) != focused.as_ref())
        .filter_map(|harness| {
            let cells: Vec<(String, String)> = cells
                .iter()
                .filter(|cell| cell.provider_id == harness.id)
                .map(|cell| {
                    // A cell with no meters (a harness that reads usage but
                    // reports no limit yet) keeps its mark with a dash, the
                    // way the bar draws it — absent, never dropped and
                    // never a zero.
                    if cell.segments.is_empty() {
                        return (cell.profile.clone(), "—".to_owned());
                    }
                    let digits: Vec<String> = cell
                        .segments
                        .iter()
                        .map(|segment| {
                            segment
                                .percent
                                .map(|p| format!("{}{p}", segment.tag))
                                .unwrap_or_else(|| format!("{}—", segment.tag))
                        })
                        .collect();
                    (cell.profile.clone(), digits.join(glyphs().sep))
                })
                .collect();
            if cells.is_empty() {
                return None;
            }
            Some(OtherHarness {
                glyph: harness.glyph.clone(),
                accent: harness.accent,
                cells,
            })
        })
        .collect()
}

/// Where the header's first line seated each other harness's cell, as
/// (column, width, account key) — the cells a click pins focus on.
type HeaderMarks = Vec<(usize, usize, String)>;

fn header<'a>(
    digest: &'a LiveState,
    freshness: Freshness,
    app: &'a App,
    now: OffsetDateTime,
    accent: Color,
    width: u16,
) -> (Paragraph<'a>, HeaderMarks) {
    let engine = &digest.engine;
    let mut identity = vec![Span::styled(
        format!("{} ", engine.glyph),
        style(accent).add_modifier(Modifier::BOLD),
    )];
    // The menu bar's pending-notice dot, in the header's own grammar: one
    // cell after the glyph, lit by the digest's `indicator` and nothing
    // else — so the app and the pane can never disagree about it.
    if digest.notices.as_ref().is_some_and(|card| card.indicator) {
        identity.push(Span::styled(
            format!("{} ", glyphs().live.trim_end()),
            style(Color::Reset).add_modifier(Modifier::BOLD),
        ));
    }
    identity.push(Span::styled(
        engine.service_name.clone(),
        Style::new().add_modifier(Modifier::BOLD),
    ));
    if let Some(plan) = &engine.plan_label {
        identity.push(Span::styled(format!("  {plan}"), style(DIM)));
    }
    // The strip's pin, in words: focus stays here whatever activity says
    // until `A` (or the panel's Auto) hands it back. Only where another
    // account could have had it, and only while the pin is what holds it.
    if digest.pinned_profile.is_some()
        && digest.pinned_profile == digest.focused_profile
        && crate::state::focus_candidates(digest).len() > 1
    {
        identity.push(Span::styled("  pinned", style(DIM)));
    }
    // The OTHER metered harnesses, in miniature (0.101.0): this pane's
    // meters are the focused account's, and a terminal that could not see
    // the second vendor at all would be a worse face than the menu bar.
    // Each keeps its own mark in its own colour; a hidden harness is absent,
    // and a writer that meters one adds nothing here.
    let seated = |spans: &[Span]| spans.iter().map(Span::width).sum::<usize>();
    let mut marks = HeaderMarks::new();
    for other in other_harnesses(digest) {
        let lead = "   ";
        let mark_column = seated(&identity) + lead.len();
        identity.push(Span::styled(
            format!("{lead}{} ", other.glyph),
            style(Color::Rgb(
                (other.accent.red * 255.0).round() as u8,
                (other.accent.green * 255.0).round() as u8,
                (other.accent.blue * 255.0).round() as u8,
            ))
            .add_modifier(Modifier::BOLD),
        ));
        for (index, (key, digits)) in other.cells.into_iter().enumerate() {
            if index > 0 {
                identity.push(Span::styled(glyphs().sep, style(DIM)));
            }
            // The first cell owns the mark too, as the menu bar's click on
            // a mark lands on that harness's account.
            let column = if index == 0 {
                mark_column
            } else {
                seated(&identity)
            };
            identity.push(Span::styled(digits, style(DIM)));
            marks.push((column, seated(&identity) - column, key));
        }
    }

    // The status line is built at full phrasing first; when the pane can't
    // seat it, the compact register drops the filler words ("updated",
    // "in") so the cadence facts — idle ×N, the budget gauge — survive
    // instead of clipping off the edge.
    let build = |compact: bool| -> Vec<Span<'a>> {
        let mut status: Vec<Span> = Vec::new();
        match freshness {
            Freshness::Live => {
                status.push(Span::styled(glyphs().live, style(accent)));
                if let Some(fetched) = engine.fetched_at {
                    let stamp = clock(fetched, app.local_offset);
                    status.push(Span::styled(
                        if compact {
                            stamp
                        } else {
                            format!("updated {stamp}")
                        },
                        style(DIM),
                    ));
                }
                if let Some(next) = engine.next_poll_at {
                    let count = countdown(next, now);
                    status.push(Span::styled(
                        format!(
                            "{}{}",
                            glyphs().sep,
                            if compact {
                                format!("next {count}")
                            } else {
                                format!("next in {count}")
                            }
                        ),
                        style(DIM),
                    ));
                }
            }
            Freshness::Stale => {
                status.push(Span::styled(glyphs().hollow, style(DIM)));
                if let Some(fetched) = engine.fetched_at {
                    let stamp = clock(fetched, app.local_offset);
                    status.push(Span::styled(
                        if compact {
                            stamp
                        } else {
                            format!("as of {stamp}")
                        },
                        style(DIM),
                    ));
                }
                if let Some(error) = &engine.error {
                    // The typed error, pre-phrased by the engine's
                    // taxonomy; the hint rides along when there is one
                    // (the app's error block shows both). Clips at the
                    // pane edge when even the hint is too much.
                    let mut copy = error.text.clone();
                    if let Some(hint) = &error.hint {
                        copy.push_str(&format!(" — {hint}"));
                    }
                    status.push(Span::styled(
                        format!("{}{copy}", glyphs().sep),
                        style(WARNING),
                    ));
                }
            }
            Freshness::Backoff => {
                status.push(Span::styled(glyphs().backoff, style(WARNING)));
                if let Some(until) = engine.backoff_until {
                    let count = countdown(until, now);
                    status.push(Span::styled(
                        if compact {
                            format!("429{}resumes {count}", glyphs().sep)
                        } else {
                            format!("rate limited — resumes in {count}")
                        },
                        style(WARNING),
                    ));
                }
            }
            Freshness::Busy => {
                // Alive and late: the host holds its lease but hasn't
                // rewritten the digest in a while. The numbers stand, with
                // the age of the last rewrite beside them.
                status.push(Span::styled(glyphs().hollow, style(WARNING)));
                status.push(Span::styled(
                    if compact {
                        "busy".to_owned()
                    } else {
                        "engine busy — updating…".to_owned()
                    },
                    style(WARNING),
                ));
                let age = (now - engine.generated_at).max(Duration::ZERO);
                status.push(Span::styled(
                    format!(
                        "{}{}{}",
                        glyphs().sep,
                        if compact { "" } else { "last update " },
                        ago(age)
                    ),
                    style(DIM),
                ));
            }
            Freshness::EngineOffline => {
                status.push(Span::styled(
                    "engine offline — start: usage-cli daemon start",
                    style(CRITICAL),
                ));
                return status;
            }
        }
        // Pending notices, counted where the dot can't say how many.
        // Only the ones the section lists — the ongoing outage is the
        // banner's to announce.
        let pending = listed_notices(digest.notices.as_ref()).len();
        if pending > 0 {
            status.push(Span::styled(
                format!(
                    "{}{pending} notice{}",
                    glyphs().sep,
                    if pending == 1 { "" } else { "s" }
                ),
                style(DIM),
            ));
        }
        // Cadence transparency, the panel status line's grammar: "idle ×N"
        // says why "next in" reads slower than the chosen pace.
        if engine.pace_multiplier > 1 {
            status.push(Span::styled(
                format!("{}idle ×{}", glyphs().sep, engine.pace_multiplier),
                style(DIM),
            ));
        }
        if !engine.is_local_provider
            && let (Some(used), Some(ceiling)) = (engine.api_budget_used, engine.api_budget_ceiling)
        {
            // The refresh button's pressure grammar: orange nearing
            // the hourly budget, red at or past it, quiet otherwise.
            let pressure = match engine.api_budget_fraction {
                Some(fraction) if fraction >= 1.0 => style(CRITICAL),
                Some(fraction) if fraction >= 0.8 => style(WARNING),
                _ => style(FAINT),
            };
            status.push(Span::styled(
                format!("{}API {used}/{ceiling}h", glyphs().sep),
                pressure,
            ));
        }
        status
    };
    let full = build(false);
    let length: usize = full.iter().map(|span| span.content.chars().count()).sum();
    let status = if length <= width as usize {
        full
    } else {
        build(true)
    };
    (
        Paragraph::new(vec![Line::from(identity), Line::from(status)]),
        marks,
    )
}

fn meters<'a>(digest: &'a LiveState, freshness: Freshness, rect: Rect) -> Paragraph<'a> {
    let mut lines = vec![section_title("LIMITS")];
    let grey = freshness == Freshness::Stale || freshness == Freshness::EngineOffline;
    let rows = (rect.height.max(1) - 1) as usize;
    let spend = digest.engine.spend.as_ref();
    let visible = &digest.meters[..digest
        .meters
        .len()
        .min(rows.saturating_sub(usize::from(spend.is_some())))];

    // One track width for the whole section, stretched into whatever the
    // longest caption leaves free — the app's full-width capsule,
    // terminal-fitted. Bars align because the width is shared.
    let label_width = 12usize;
    let suffix_len = |meter: &crate::digest::LiveMeter| -> usize {
        let mut len = 5; // " 100%"
        if let Some(caption) = &meter.reset_caption {
            len += 2 + caption.chars().count();
        }
        if let Some(caption) = meter.forecast.as_ref().and_then(|f| f.caption.as_ref()) {
            len += glyphs().sep.chars().count() + caption.chars().count();
        }
        len
    };
    let max_suffix = visible.iter().map(suffix_len).max().unwrap_or(5);
    let bar_width = (rect.width as usize)
        .saturating_sub(2 + label_width + 1 + max_suffix)
        .clamp(8, 64);

    for meter in visible {
        // The app's ladder: grey when stale, the risk blend while the
        // forecast is severe, otherwise the level — where normal wears the
        // system accent, exactly like controlAccentColor-tinted capsules.
        let bar_color = if grey {
            DIM
        } else if let Some(risk) = meter.risk {
            rgb(risk)
        } else {
            match meter.level.as_str() {
                "warning" => WARNING,
                "critical" => CRITICAL,
                _ => fill_accent(digest),
            }
        };
        let percent = meter.percent.unwrap_or(0).clamp(0, 100) as usize;
        let filled = (percent * bar_width).div_ceil(100).min(bar_width);
        // The empty track: a quiet solid where color can carry the
        // difference; the distinct-glyph dialects keep their own alphabet.
        let look = crate::state::look();
        let track = if look.no_color || look.ascii {
            Span::styled(glyphs().bar_empty.repeat(bar_width - filled), style(FAINT))
        } else {
            Span::styled("█".repeat(bar_width - filled), Style::new().fg(TRACK))
        };
        let mut spans = vec![
            Span::styled(
                format!("{} ", meter.tag),
                style(DIM).add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!(
                    "{:<label_width$} ",
                    truncate_label(&meter.label, label_width)
                ),
                Style::new(),
            ),
            Span::styled(glyphs().bar_fill.repeat(filled), style(bar_color)),
            track,
            match meter.percent {
                // Neutral bold, the app's big figure — state color stays
                // on the bar and the runs-out caption.
                Some(p) => Span::styled(
                    format!(" {p:>3}%"),
                    Style::new().add_modifier(Modifier::BOLD),
                ),
                None => Span::styled("   —".to_owned(), style(DIM)),
            },
        ];
        if let Some(caption) = &meter.reset_caption {
            spans.push(Span::styled(format!("  {caption}"), style(DIM)));
        }
        if let Some(forecast) = &meter.forecast
            && let Some(caption) = &forecast.caption
        {
            spans.push(Span::styled(
                format!("{}{caption}", glyphs().sep),
                style(bar_color),
            ));
        }
        lines.push(Line::from(spans));
    }
    if let Some(spend) = spend
        && lines.len() <= rows
    {
        lines.push(Line::from(vec![
            Span::styled(format!("{:<15}", "credits"), style(DIM)),
            Span::styled(spend_text(spend), Style::new()),
        ]));
    }
    Paragraph::new(lines)
}

/// SpendLine.formatted, ported: "$0.00 of $50.00" — minor units scaled by
/// the currency's exponent, "$" only for USD.
fn spend_text(spend: &crate::digest::SpendStatus) -> String {
    let amount = |minor: i64| -> String {
        let symbol = if spend.currency == "USD" {
            "$".to_owned()
        } else {
            format!("{} ", spend.currency)
        };
        let scaled = minor as f64 / 10f64.powi(spend.exponent);
        format!(
            "{symbol}{scaled:.precision$}",
            precision = spend.exponent.max(0) as usize
        )
    };
    match spend.limit_minor {
        Some(limit) => format!("{} of {}", amount(spend.used_minor), amount(limit)),
        None => amount(spend.used_minor),
    }
}

/// While the writer's first scan hasn't landed, the top level's empty
/// rollup is not zero usage — the section says "scanning…" instead.
fn activity_scanning(digest: &LiveState) -> bool {
    digest
        .activity_status
        .as_ref()
        .is_some_and(|status| status.is_scanning())
}

/// " · as of 22:15" when the activity shown is the previous run's scan.
fn activity_as_of(digest: &LiveState, offset: UtcOffset) -> Option<String> {
    let at = digest.activity_status.as_ref()?.cached_as_of()?;
    Some(format!("{}as of {}", glyphs().sep, clock(at, offset)))
}

fn scanning_lines(title: &str) -> Paragraph<'static> {
    Paragraph::new(vec![
        section_title(title),
        Line::from(Span::styled("scanning…", style(DIM))),
    ])
}

// MARK: - Heatmap (two forms, weekday-true, paged — design §4)

/// The four density cells, doubled to cell width — leaked once, static
/// forever (four tiny strings).
fn heat_cell_text(quartile: usize) -> &'static str {
    static CELLS: OnceLock<[String; 4]> = OnceLock::new();
    let cells = CELLS.get_or_init(|| {
        let g = glyphs().heat_density;
        [
            g[0].repeat(2),
            g[1].repeat(2),
            g[2].repeat(2),
            g[3].repeat(2),
        ]
    });
    &cells[quartile.min(3)]
}

struct HeatGrid {
    /// Weeks in the visible window, oldest first; each week is 7 Mondays-
    /// first day keys.
    weeks: Vec<[Option<Date>; 7]>,
    has_older: bool,
    has_newer: bool,
}

/// How many Monday-aligned weeks the day data actually spans, today's week
/// included — the ceiling on useful heatmap rows/columns. Empty data reads
/// as one week (today's own).
fn data_weeks(days: &[DayRollup], today: Date) -> u16 {
    let monday =
        |d: Date| d - time::Duration::days(i64::from(d.weekday().number_days_from_monday()));
    let Some(oldest) = days
        .first()
        .and_then(|day| Date::parse(&day.day_key, surfaces::DAY_KEY).ok())
    else {
        return 1;
    };
    let span = monday(today) - monday(oldest);
    (span.whole_weeks().max(0) as u16) + 1
}

/// The 30D calendar: exactly the period's days, padded to whole weeks with
/// blanks — never the extra real days a Monday-aligned window would sweep
/// in. (The app pads with nil cells for the same reason: the grid and the
/// summary must describe the same window.)
fn span_grid(start: Date, end: Date, oldest: Option<Date>, page: usize) -> HeatGrid {
    let mut cells: Vec<Option<Date>> =
        vec![None; start.weekday().number_days_from_monday() as usize];
    let mut day = start;
    while day <= end {
        cells.push(Some(day));
        let Some(next) = day.next_day() else { break };
        day = next;
    }
    while !cells.len().is_multiple_of(7) {
        cells.push(None);
    }
    let weeks = cells
        .chunks(7)
        .map(|chunk| {
            let mut week = [None; 7];
            week[..chunk.len()].copy_from_slice(chunk);
            week
        })
        .collect();
    HeatGrid {
        weeks,
        has_older: oldest.is_some_and(|oldest| oldest < start),
        has_newer: page > 0,
    }
}

fn heat_grid(days: &[DayRollup], weeks_visible: usize, page: usize, today: Date) -> HeatGrid {
    // Anchor on today's week (Monday start), step whole windows back.
    let monday = today - time::Duration::days(i64::from(today.weekday().number_days_from_monday()));
    let window_end = monday - time::Duration::weeks((weeks_visible * page) as i64);
    let mut weeks = Vec::with_capacity(weeks_visible);
    for week in (0..weeks_visible).rev() {
        let start = window_end - time::Duration::weeks(week as i64);
        let mut row = [None; 7];
        for (slot, cell) in row.iter_mut().enumerate() {
            *cell = start.checked_add(time::Duration::days(slot as i64));
        }
        weeks.push(row);
    }
    let oldest_key = days.first().map(|d| d.day_key.clone()).unwrap_or_default();
    let window_start = window_end - time::Duration::weeks(weeks_visible as i64 - 1);
    let has_older = window_start
        .format(surfaces::DAY_KEY)
        .map(|key| key > oldest_key)
        .unwrap_or(false)
        && !days.is_empty();
    HeatGrid {
        weeks,
        has_older,
        has_newer: page > 0,
    }
}

/// The ACTIVITY title: section name, the active period, the filtered
/// model, how far back the window has been paged, and the pager glyphs.
/// Returns the columns where the two pager arrows landed so the caller can
/// register them as hits — the title's own width is the only truth about
/// where they sit.
fn activity_title(
    app: &App,
    filter: Option<&Filter>,
    back_label: Option<String>,
    has_older: bool,
    has_newer: bool,
) -> (Line<'static>, u16, u16) {
    /// Appends a span and keeps the running column count — the pager hits
    /// are placed from this width, so every span must pass through here.
    fn push(spans: &mut Vec<Span<'static>>, width: &mut usize, text: String, style: Style) {
        *width += text.chars().count();
        spans.push(Span::styled(text, style));
    }
    let mut spans = vec![Span::styled(
        "ACTIVITY".to_owned(),
        style(DIM).add_modifier(Modifier::BOLD),
    )];
    let mut width = "ACTIVITY".chars().count();
    push(
        &mut spans,
        &mut width,
        format!("{}{}", glyphs().sep, app.period.label()),
        style(DIM),
    );
    if app.dimension == Dimension::Cost {
        push(
            &mut spans,
            &mut width,
            format!("{}cost", glyphs().sep),
            style(DIM),
        );
    }
    if let Some(filter) = filter {
        push(
            &mut spans,
            &mut width,
            format!("{}{}", glyphs().sep, filter.total.display_name),
            style(rgb(filter.total.color)),
        );
    }
    if let Some(back) = back_label {
        push(
            &mut spans,
            &mut width,
            format!("{}{back}", glyphs().sep),
            style(DIM),
        );
    }
    push(&mut spans, &mut width, "  ".to_owned(), Style::new());
    let older_x = width as u16;
    push(
        &mut spans,
        &mut width,
        if has_older { glyphs().pager_left } else { " " }.to_owned(),
        style(if has_older { DIM } else { FAINT }),
    );
    push(&mut spans, &mut width, " ".to_owned(), Style::new());
    let newer_x = width as u16;
    push(
        &mut spans,
        &mut width,
        if has_newer { glyphs().pager_right } else { " " }.to_owned(),
        style(if has_newer { DIM } else { FAINT }),
    );
    (Line::from(spans), older_x, newer_x)
}

/// The line under every activity form: the hovered day's facts, else the
/// focused model's scoped totals, else the period summary — the app's
/// footerStats, one register down.
/// `window` is the span actually drawn, which is the period's own span
/// except in the paged all-time grid — there the pane shows the weeks
/// that fit, and the line must describe those, not the whole history.
fn activity_readout(
    app: &App,
    digest: &LiveState,
    filter: Option<&Filter>,
    window: (&str, &str),
    width: usize,
) -> String {
    let reading = app.reading(digest);
    if let Some(Hit::HeatDay(key)) = &app.hover_hit
        && let Some(day) = reading.days.iter().find(|day| &day.day_key == key)
    {
        let mut text = format!("{}{}{} tok", day.day_key, glyphs().sep, compact(day.tokens));
        if let Some(cost) = day.cost {
            text.push_str(&format!("{}{}", glyphs().sep, money(cost)));
        }
        if day.prompts > 0 {
            text.push_str(&format!("{}{} prompts", glyphs().sep, day.prompts));
        }
        text.push_str("  (click to drill)");
        return text;
    }
    let measure = |value: f64| match app.dimension {
        Dimension::Tokens => format!("{} tokens", compact(value as i64)),
        Dimension::Cost => format!("≈ {}", money(value)),
    };
    let (start, end) = window;
    if let Some(filter) = filter {
        let days = reading
            .model_days
            .iter()
            .filter(|day| day.day_key.as_str() >= start && day.day_key.as_str() <= end)
            .filter(|day| {
                day.models
                    .iter()
                    .any(|m| filter.covers(&activity::row_key(m.agent.as_deref(), &m.id)))
            })
            .count();
        // Absent ≠ zero: a selection with nothing priced has no cost.
        let figure = match (app.dimension, filter.total.cost) {
            (Dimension::Cost, None) => "— unpriced".to_owned(),
            _ => measure(filter.total.value(app.dimension)),
        };
        return format!(
            "{}{}{figure}{}{days} active days",
            filter.total.display_name,
            glyphs().sep,
            glyphs().sep
        );
    }
    let sep = glyphs().sep;
    if app.no_total_yet(digest)
        && let Some(all) = app.all_agents(digest)
    {
        return format!("no total yet{sep}{}{sep}partial", all.count_label);
    }
    let total = activity::total_value(&reading.days, start, end, app.dimension);
    let active = activity::active_days(&reading.days, start, end);
    let figure = measure(total);
    let days = format!("{sep}{active} active days");
    // Whose total this is, and whether it is all of it yet. "partial" is
    // the one word saying a scan is still out of the total (the count label
    // reads alike for an agent that reports no tokens), so it gives way
    // last: the active days first, then the label.
    let (label, partial) = app
        .all_agents(digest)
        .map(|all| {
            (
                format!("{sep}{}", all.count_label),
                if all.partial {
                    format!("{sep}partial")
                } else {
                    String::new()
                },
            )
        })
        .unwrap_or_default();
    let candidates = [
        format!("{figure}{days}{label}{partial}"),
        format!("{figure}{label}{partial}"),
        format!("{figure}{partial}"),
    ];
    candidates
        .iter()
        .find(|text| text.chars().count() <= width)
        .unwrap_or(&candidates[2])
        .clone()
}

/// The 7D form: one stacked bar per day in the models' ledger colors, its
/// total floating above, weekday and date beneath — the app's signature
/// activity chart, terminal-fitted (item 10).
fn render_bars(frame: &mut Frame, app: &mut App, digest: &LiveState, data: &Dash, rect: Rect) {
    let filter = data.filter(app);
    let reading = app.reading(digest);
    // Agents share the bars: a day with no per-model split, or only a
    // prompt count, is painted neutral — no one vendor's accent.
    let (fill, stub) = if app
        .all_agents(digest)
        .is_some_and(crate::state::spans_agents)
    {
        (rgb(NEUTRAL), ramp(NEUTRAL, 0.35))
    } else {
        (fill_accent(digest), ramp(digest.engine.accent, 0.35))
    };
    let by_key: HashMap<&str, &DayRollup> = reading
        .days
        .iter()
        .map(|day| (day.day_key.as_str(), day))
        .collect();
    let start = data.today - time::Duration::days(6 + 7 * app.heat_page as i64);
    let days: Vec<Date> = (0..7)
        .filter_map(|offset| start.checked_add(time::Duration::days(offset)))
        .collect();

    // Paging back is possible while data predates the window; forward only
    // once we have stepped away from the current week.
    let oldest = reading
        .days
        .first()
        .map(|day| day.day_key.as_str())
        .unwrap_or("");
    let has_older = days
        .first()
        .map(|date| activity::day_key(*date))
        .is_some_and(|key| key.as_str() > oldest);
    let back_label = (app.heat_page > 0).then(|| format!("{}w back", app.heat_page));
    let (title, older_x, newer_x) = activity_title(
        app,
        filter.as_ref(),
        back_label,
        has_older,
        app.heat_page > 0,
    );
    frame.render_widget(title, Rect::new(rect.x, rect.y, rect.width, 1));
    if has_older {
        app.hits
            .add(Rect::new(rect.x + older_x, rect.y, 1, 1), Hit::PageEarlier);
    }
    if app.heat_page > 0 {
        app.hits
            .add(Rect::new(rect.x + newer_x, rect.y, 1, 1), Hit::PageLater);
    }

    // The maturity note sits between the date row and the readout, as it
    // does under the app's bars — and wraps there too, rather than being
    // cut mid-word. Two lines is the ceiling: past that the sentence costs
    // more plot than it's worth, and the bars are the section's reason to
    // be.
    let note: Vec<String> = data
        .activation_note
        .as_deref()
        .filter(|_| rect.height >= 9)
        .map(|text| wrap_words(text, rect.width as usize))
        .filter(|lines| lines.len() <= 2)
        .unwrap_or_default();

    // Rows: title, plot, weekday, date, [note,] readout. The plot keeps one
    // row of headroom so the tallest bar's own total still has somewhere to
    // sit.
    let plot_top = rect.y + 1;
    let plot_height = rect.height.saturating_sub(4 + note.len() as u16).max(1) as usize;
    let usable = plot_height.saturating_sub(1).max(1);
    let slot = ((rect.width as usize) / 7).max(1);
    let bar_width = slot.saturating_sub(1).max(1);
    let pad = (slot - bar_width) / 2;

    // A legend filter dims the other bands but never resizes a bar: the
    // day's own total is what its height and its floating label mean, and
    // the app keeps both steady under hover for exactly that reason.
    // (The calendar forms DO rescale to the model — see render_heatmap,
    // which mirrors the app's own split treatment.)
    let value_of = |date: Date| -> f64 {
        by_key
            .get(activity::day_key(date).as_str())
            .map(|day| activity::day_value(day, app.dimension))
            .unwrap_or(0.0)
    };
    let max = days
        .iter()
        .map(|date| value_of(*date))
        .fold(0.0_f64, f64::max)
        .max(f64::MIN_POSITIVE);

    // Per bar: how tall, what each row's color is (bottom-up), and the
    // floating total's text.
    // Each painted row carries its own ink AND its own glyph: where color
    // is unavailable the density alphabet keeps the stack legible, the
    // same trade the heat cells make.
    struct Bar {
        rows: usize,
        cells: Vec<(Color, &'static str)>,
        label: String,
    }
    let mono = crate::state::look().no_color || crate::state::look().ascii;
    let bars: Vec<Bar> = days
        .iter()
        .map(|date| {
            let key = activity::day_key(*date);
            let value = value_of(*date);
            let prompts = by_key.get(key.as_str()).map_or(0, |day| day.prompts);
            if value <= 0.0 {
                // Prompt-only days keep a stub: the app never lets a day
                // with recorded work render as nothing.
                let rows = usize::from(prompts > 0);
                return Bar {
                    rows,
                    cells: vec![(stub, glyphs().bar_fill); rows],
                    label: String::new(),
                };
            }
            let rows = (((value / max) * usable as f64).round() as usize).clamp(1, plot_height);
            let segments = activity::segments(reading, &key, &data.models, app.dimension);
            let mut colors: Vec<(Color, &'static str)> = Vec::with_capacity(rows);
            if segments.is_empty() {
                colors.resize(rows, (fill, glyphs().bar_fill));
            } else {
                // Rows split by share, largest remainder so the stack sums
                // to the bar's height exactly; the stacking order is the
                // period's (heaviest first, or agent by agent under All
                // agents), the same for every bar, so bands line up.
                let mut assigned: Vec<(usize, (Color, &'static str))> = segments
                    .iter()
                    .enumerate()
                    .map(|(index, (key, color, fraction))| {
                        let dim = filter.as_ref().is_some_and(|filter| !filter.covers(key));
                        let paint = if dim { ramp(*color, 0.3) } else { rgb(*color) };
                        // Monochrome: the stack's bands separate by
                        // density instead of hue, brightest band first.
                        let glyph = if mono {
                            glyphs().heat_density[3 - index.min(3)]
                        } else {
                            glyphs().bar_fill
                        };
                        ((fraction * rows as f64).floor() as usize, (paint, glyph))
                    })
                    .collect();
                let mut spare = rows.saturating_sub(assigned.iter().map(|(n, _)| n).sum::<usize>());
                let mut order: Vec<usize> = (0..segments.len()).collect();
                order.sort_by(|a, b| {
                    let remainder = |i: usize| {
                        let scaled = segments[i].2 * rows as f64;
                        scaled - scaled.floor()
                    };
                    remainder(*b)
                        .partial_cmp(&remainder(*a))
                        .unwrap_or(std::cmp::Ordering::Equal)
                });
                for index in order {
                    if spare == 0 {
                        break;
                    }
                    assigned[index].0 += 1;
                    spare -= 1;
                }
                for (count, cell) in assigned {
                    colors.extend(std::iter::repeat_n(cell, count));
                }
                colors.resize(rows, (fill, glyphs().bar_fill));
            }
            Bar {
                rows,
                cells: colors,
                label: match app.dimension {
                    Dimension::Tokens => compact(value as i64),
                    Dimension::Cost => money(value),
                },
            }
        })
        .collect();

    // Paint top-down: a bar's own total rides in the row just above it.
    for row in 0..plot_height {
        let from_bottom = plot_height - 1 - row;
        let mut spans: Vec<Span> = Vec::new();
        for bar in &bars {
            if from_bottom < bar.rows {
                let (color, glyph) = bar.cells[from_bottom];
                spans.push(Span::raw(" ".repeat(pad)));
                spans.push(Span::styled(glyph.repeat(bar_width), style(color)));
                spans.push(Span::raw(" ".repeat(slot - bar_width - pad)));
            } else if from_bottom == bar.rows && !bar.label.is_empty() && bar.label.len() <= slot {
                let lead = (slot - bar.label.chars().count()) / 2;
                spans.push(Span::styled(
                    format!(
                        "{:lead$}{}{:trail$}",
                        "",
                        bar.label,
                        "",
                        trail = slot - lead - bar.label.chars().count()
                    ),
                    style(FAINT),
                ));
            } else {
                spans.push(Span::raw(" ".repeat(slot)));
            }
        }
        frame.render_widget(
            Paragraph::new(Line::from(spans)),
            Rect::new(rect.x, plot_top + row as u16, rect.width, 1),
        );
    }

    // Weekday and date rows; today wears the bold the app gives it.
    let weekday = |date: Date| format!("{:?}", date.weekday())[..3].to_owned();
    for (offset, format) in [
        (0u16, Box::new(weekday) as Box<dyn Fn(Date) -> String>),
        (1, Box::new(|date: Date| date.day().to_string())),
    ] {
        let mut spans: Vec<Span> = Vec::new();
        for date in &days {
            let text = format(*date);
            let lead = (slot.saturating_sub(text.chars().count())) / 2;
            let mut style = if offset == 0 {
                style(DIM)
            } else {
                style(FAINT)
            };
            if *date == data.today {
                style = style.add_modifier(Modifier::BOLD);
            }
            spans.push(Span::styled(
                format!(
                    "{:lead$}{}{:trail$}",
                    "",
                    truncate(&text, slot),
                    "",
                    trail = slot.saturating_sub(lead + text.chars().count())
                ),
                style,
            ));
        }
        frame.render_widget(
            Paragraph::new(Line::from(spans)),
            Rect::new(
                rect.x,
                plot_top + plot_height as u16 + offset,
                rect.width,
                1,
            ),
        );
    }

    // Whole columns are the hit targets, as in the app — hover lifts the
    // bar, click drills the day.
    for (index, date) in days.iter().enumerate() {
        app.hits.add(
            Rect::new(
                rect.x + (index * slot) as u16,
                plot_top,
                slot as u16,
                plot_height as u16 + 2,
            ),
            Hit::HeatDay(activity::day_key(*date)),
        );
    }

    for (offset, line) in note.iter().enumerate() {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(line.clone(), style(FAINT)))),
            Rect::new(
                rect.x,
                plot_top + plot_height as u16 + 2 + offset as u16,
                rect.width,
                1,
            ),
        );
    }

    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            activity_readout(
                app,
                digest,
                filter.as_ref(),
                (&data.start, &data.end),
                rect.width as usize,
            ),
            style(FAINT),
        ))),
        Rect::new(rect.x, rect.y + rect.height - 1, rect.width, 1),
    );
}

/// The 30D and All forms: the calendar grid (portrait) or the weekday
/// strip (landscape), scoped to the active period.
fn render_heatmap(frame: &mut Frame, app: &mut App, digest: &LiveState, data: &Dash, rect: Rect) {
    let reading = app.reading(digest);
    let days = &reading.days;
    // Agents share the grid: its ramp is neutral (the app's Color.primary).
    let ground = if app
        .all_agents(digest)
        .is_some_and(crate::state::spans_agents)
    {
        NEUTRAL
    } else {
        digest.engine.accent
    };
    let by_key: HashMap<&str, &DayRollup> = days.iter().map(|d| (d.day_key.as_str(), d)).collect();
    // A hovered/focused model row filters the grid to that model's own
    // days, in its ledger color — the pane's version of the app's
    // hover-to-filter. Calendar geometry stays unfiltered: paging and
    // week rows never shrink under a filter.
    let filter = data.filter(app);
    let heat_values: HashMap<&str, f64> = match &filter {
        Some(filter) => reading
            .model_days
            .iter()
            .filter_map(|day| {
                let counted: Vec<f64> = day
                    .models
                    .iter()
                    .filter(|m| filter.covers(&activity::row_key(m.agent.as_deref(), &m.id)))
                    .map(|m| match app.dimension {
                        Dimension::Tokens => m.tally.total() as f64,
                        Dimension::Cost => m.cost.unwrap_or(0.0),
                    })
                    .collect();
                (!counted.is_empty()).then(|| (day.day_key.as_str(), counted.iter().sum()))
            })
            .collect(),
        None => days
            .iter()
            .map(|d| (d.day_key.as_str(), activity::day_value(d, app.dimension)))
            .collect(),
    };
    let max = heat_values
        .values()
        .copied()
        .fold(0.0_f64, f64::max)
        .max(f64::MIN_POSITIVE);
    let heat_color = filter.as_ref().map_or(ground, |f| f.total.color);
    let today = data.today;
    // The 30D form is the app's calendar in both orientations; only the
    // all-time grid takes the landscape weekday strip, where a year of
    // weeks-as-columns is the only shape that fits.
    let landscape = app.period == Period::All && rect.width > rect.height * 4;
    let oldest = days
        .first()
        .and_then(|day| Date::parse(&day.day_key, surfaces::DAY_KEY).ok());

    // Rows: title, grid, readout. Portrait grids weeks-as-rows; landscape
    // weeks-as-columns (7 fixed rows). Both stop at the period's own week
    // span — the window never manufactures empty dot-weeks beyond it, and
    // the paging stride equals what is actually painted (portrait's grid
    // budget loses one row to the weekday-letter line).
    let span_cap = data.weeks as usize;
    let grid_height = rect.height.saturating_sub(2) as usize;
    let weeks_visible = if landscape {
        ((rect.width as usize).saturating_sub(3) / 2)
            .clamp(4, 60)
            .min(span_cap.max(4))
    } else {
        grid_height.saturating_sub(1).clamp(1, span_cap.max(1))
    };
    let grid = match app.period {
        // 30D pages by its own window, so the calendar is built from that
        // window rather than from a count of week rows.
        Period::Month => span_grid(data.start_date, data.end_date, oldest, app.heat_page),
        _ => heat_grid(days, weeks_visible, app.heat_page, today),
    };

    let back_label = (app.heat_page > 0).then(|| match app.period {
        Period::Month => format!("{}d back", 30 * app.heat_page),
        _ => format!("{}w back", weeks_visible * app.heat_page),
    });
    let (title, older_x, newer_x) = activity_title(
        app,
        filter.as_ref(),
        back_label,
        grid.has_older,
        grid.has_newer,
    );
    frame.render_widget(title, Rect::new(rect.x, rect.y, rect.width, 1));
    if grid.has_older {
        app.hits
            .add(Rect::new(rect.x + older_x, rect.y, 1, 1), Hit::PageEarlier);
    }
    if grid.has_newer {
        app.hits
            .add(Rect::new(rect.x + newer_x, rect.y, 1, 1), Hit::PageLater);
    }

    let cell = |date: Option<Date>| -> (String, Style) {
        let Some(date) = date else {
            return ("  ".into(), Style::new());
        };
        let key = date.format(surfaces::DAY_KEY).unwrap_or_default();
        let value = heat_values.get(key.as_str()).copied().unwrap_or(0.0);
        let mut cell_style;
        let text;
        let look = crate::state::look();
        if value > 0.0 {
            let alpha = 0.25 + 0.75 * (value / max).sqrt();
            if look.no_color || look.ascii {
                // Density carries intensity when color can't.
                let quartile = (((alpha - 0.25) / 0.75) * 3.0).round() as usize;
                text = heat_cell_text(quartile.min(3));
                cell_style = Style::new();
            } else {
                cell_style = style(ramp(heat_color, alpha));
                text = "██";
            }
        } else if filter.is_none() && by_key.get(key.as_str()).is_some_and(|day| day.prompts > 0) {
            cell_style = style(ramp(ground, 0.35));
            text = glyphs().prompt_cell;
        } else {
            cell_style = style(FAINT);
            text = if look.ascii { ". " } else { "· " };
        }
        if date == today {
            cell_style = cell_style.add_modifier(Modifier::UNDERLINED);
        }
        // The hovered/focused day's lift comes from the shared halo pass.
        (text.into(), cell_style)
    };

    let grid_y = rect.y + 1;
    if landscape {
        // Weekday letters gutter + weeks as columns.
        let letters = ["M", "T", "W", "T", "F", "S", "S"];
        for row in 0..7usize.min(grid_height) {
            let mut spans = vec![Span::styled(format!("{} ", letters[row]), style(FAINT))];
            for (week_index, week) in grid.weeks.iter().enumerate() {
                let (text, style) = cell(week[row]);
                spans.push(Span::styled(text, style));
                if let Some(date) = week[row]
                    && let Ok(key) = date.format(surfaces::DAY_KEY)
                {
                    app.hits.add(
                        Rect::new(
                            rect.x + 2 + (week_index as u16) * 2,
                            grid_y + row as u16,
                            2,
                            1,
                        ),
                        Hit::HeatDay(key),
                    );
                }
            }
            frame.render_widget(
                Paragraph::new(Line::from(spans)),
                Rect::new(rect.x, grid_y + row as u16, rect.width, 1),
            );
        }
    } else {
        // Weeks as rows, weekday columns with a label line consumed from
        // the grid budget.
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                "M  T  W  T  F  S  S".to_owned(),
                style(FAINT),
            ))),
            Rect::new(rect.x, grid_y, rect.width, 1),
        );
        for (row, week) in grid
            .weeks
            .iter()
            .rev()
            .take(grid_height.saturating_sub(1))
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .enumerate()
        {
            let mut spans: Vec<Span> = Vec::new();
            for (slot, date) in week.iter().enumerate() {
                let (text, style) = cell(*date);
                spans.push(Span::styled(text, style));
                spans.push(Span::raw(" "));
                if let Some(date) = date
                    && let Ok(key) = date.format(surfaces::DAY_KEY)
                {
                    app.hits.add(
                        Rect::new(rect.x + (slot as u16) * 3, grid_y + 1 + row as u16, 2, 1),
                        Hit::HeatDay(key),
                    );
                }
            }
            frame.render_widget(
                Paragraph::new(Line::from(spans)),
                Rect::new(rect.x, grid_y + 1 + row as u16, rect.width, 1),
            );
        }
    }

    // The grid's own bounds: for a paged all-time view these are the weeks
    // on screen, not the whole history the period nominally covers.
    let drawn: Vec<Date> = grid.weeks.iter().flatten().flatten().copied().collect();
    let window = match (drawn.iter().min(), drawn.iter().max()) {
        (Some(first), Some(last)) => (activity::day_key(*first), activity::day_key(*last)),
        _ => (data.start.clone(), data.end.clone()),
    };
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            activity_readout(
                app,
                digest,
                filter.as_ref(),
                (&window.0, &window.1),
                rect.width as usize,
            ),
            style(FAINT),
        ))),
        Rect::new(rect.x, rect.y + rect.height - 1, rect.width, 1),
    );
}

fn footer<'a>(
    digest: &'a LiveState,
    freshness: Freshness,
    app: &'a App,
    now: OffsetDateTime,
    width: u16,
) -> Paragraph<'a> {
    // `a` is offered only where there is another account to go to.
    let switchable = crate::state::focus_candidates(digest).len() > 1;
    // `u` only where there is a total to switch to.
    let agents = digest.all_agents.is_some();
    let keys = match app.surface {
        Surface::Dashboard if switchable && agents => {
            "q quit / r refresh / a account / u agents / v span / c cost / p pace / 1-3 meters / ? help"
        }
        Surface::Dashboard if switchable => {
            "q quit / r refresh / a account / v span / c cost / p pace / 1-3 meters / ? help"
        }
        Surface::Dashboard if agents => {
            "q quit / r refresh / u agents / v span / c cost / p pace / 1-3 meters / ? help"
        }
        Surface::Dashboard => "q quit / r refresh / v span / c cost / p pace / 1-3 meters / ? help",
        Surface::Meter(_) => "esc back / arrows scrub / s span / z zoom / r refresh / ? help",
        _ => "esc back / arrows step / r refresh / ? help",
    };
    let status = status_footer_spans(digest.service_status.as_ref(), now);
    let claim: usize = status.iter().map(|span| span.content.chars().count()).sum();
    let keys = footer_keys(keys, app.notice.as_deref(), claim, width);
    let mut spans = vec![Span::styled(keys, style(FAINT))];
    if let Some(notice) = &app.notice {
        spans.push(Span::styled(format!("  {notice}"), style(DIM)));
    } else if freshness == Freshness::Backoff {
        if let Some(until) = digest.engine.backoff_until {
            spans.push(Span::styled(
                format!(
                    "  429 backoff{}resumes in {}",
                    glyphs().sep,
                    countdown(until, now)
                ),
                style(WARNING),
            ));
        }
    } else {
        spans.push(Span::styled(
            format!(
                "  {}{}v{}{}{}",
                digest.engine.host,
                glyphs().sep,
                digest.engine.app_version,
                glyphs().sep,
                digest.activity.time_zone
            ),
            style(FAINT),
        ));
    }
    // Rung 0: the service's health closes the footer, pushed flush right —
    // one green cell when all is well, and the incident itself when it's
    // minor enough not to have earned a banner row of its own. Right-aligned
    // rather than appended, so it can't be the thing a narrow pane clips.
    place_status_in_footer(&mut spans, status, width);
    Paragraph::new(Line::from(spans))
}

/// A reply outranks the full key list: when the footer can't seat both —
/// and the health mark — the keys fold to the one that lists the rest, so
/// the answer to `a`, `p` or `r` is read rather than clipped (or dropped
/// first, as the footer's tail).
fn footer_keys(keys: &'static str, notice: Option<&str>, claim: usize, width: u16) -> &'static str {
    match notice {
        Some(notice)
            if keys.chars().count() + 2 + notice.chars().count() + claim > width as usize =>
        {
            "? help"
        }
        _ => keys,
    }
}

/// Seats the health mark at the footer's right edge and decides what gives
/// when the row can't hold everything. Split out from `footer` so the width
/// arithmetic is testable without a terminal.
fn place_status_in_footer(spans: &mut Vec<Span<'_>>, status: Vec<Span<'static>>, width: u16) {
    if !status.is_empty() {
        let used: usize = spans.iter().map(|span| span.content.chars().count()).sum();
        let claim: usize = status.iter().map(|span| span.content.chars().count()).sum();
        let room = width as usize;
        if used + claim <= room {
            spans.push(Span::raw(" ".repeat(room - used - claim)));
            spans.extend(status);
        } else if claim < room {
            // Too tight for both: drop from the TAIL — the host/version
            // trailer goes before the key hints, which are how the pane is
            // driven. A shortest-first pass would sacrifice exactly the
            // wrong span.
            let keep = room - claim;
            let mut kept: usize = spans.iter().map(|s| s.content.chars().count()).sum();
            while kept > keep && spans.len() > 1 {
                if let Some(dropped) = spans.pop() {
                    kept -= dropped.content.chars().count();
                }
            }
            if kept > keep {
                // One span left and still over: clip it rather than blank the
                // row — losing "q quit" entirely to a one-column overrun
                // would be a poor trade.
                if let Some(last) = spans.pop() {
                    let style = last.style;
                    let text: String = last.content.chars().take(keep).collect();
                    kept = text.chars().count();
                    spans.push(Span::styled(text, style));
                } else {
                    kept = 0;
                }
            }
            if keep > kept {
                spans.push(Span::raw(" ".repeat(keep - kept)));
            }
            spans.extend(status);
        }
    }
}

/// Below the floor: one line that still says everything (design §3).
fn render_strip(
    frame: &mut Frame,
    area: Rect,
    digest: &LiveState,
    freshness: Freshness,
    now: OffsetDateTime,
) {
    let accent = rgb(digest.engine.accent);
    let grey = !matches!(
        freshness,
        Freshness::Live | Freshness::Backoff | Freshness::Busy
    );
    let mut spans = vec![Span::styled(
        format!("{} ", digest.engine.glyph),
        style(if grey { DIM } else { accent }),
    )];
    // The pending-notice dot spends one cell, same as the header's.
    if digest.notices.as_ref().is_some_and(|card| card.indicator) {
        spans.push(Span::styled(
            format!("{} ", glyphs().live.trim_end()),
            Style::new().add_modifier(Modifier::BOLD),
        ));
    }
    for (index, segment) in digest.menu_bar.iter().enumerate() {
        if index > 0 {
            spans.push(Span::styled(glyphs().sep.to_owned(), style(FAINT)));
        }
        let color = if grey {
            DIM
        } else if let Some(risk) = segment.risk {
            rgb(risk)
        } else {
            match segment.level.as_str() {
                "warning" => WARNING,
                "critical" => CRITICAL,
                _ => Color::Reset,
            }
        };
        spans.push(Span::styled(format!("{} ", segment.tag), style(DIM)));
        spans.push(Span::styled(
            segment
                .percent
                .map(|p| format!("{p}"))
                .unwrap_or_else(|| "—".into()),
            style(color).add_modifier(Modifier::BOLD),
        ));
    }
    if freshness == Freshness::EngineOffline {
        spans.push(Span::styled("  offline".to_owned(), style(CRITICAL)));
    } else if freshness == Freshness::Busy {
        spans.push(Span::styled("  busy".to_owned(), style(WARNING)));
    } else if freshness == Freshness::Backoff {
        // The 429 marker with its ticking retry countdown — the strip's
        // only word on it, so it earns its columns.
        if let Some(until) = digest.engine.backoff_until {
            spans.push(Span::styled(
                format!("  {}{}", glyphs().backoff, countdown(until, now)),
                style(WARNING),
            ));
        }
    } else if grey {
        spans.push(Span::styled("  stale".to_owned(), style(DIM)));
    }
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

fn render_offline(frame: &mut Frame, area: Rect, app: &App, busy: bool) {
    let message = if let Some(error) = &app.decode_error {
        format!("digest unreadable: {error}")
    } else if busy {
        format!(
            "engine busy — starting…\n\nno live-state digest yet at\n{}",
            app.digest_path.display()
        )
    } else {
        format!(
            "no live-state digest at\n{}\n\nlaunch the menu bar app, or: usage-cli daemon start",
            app.digest_path.display()
        )
    };
    let lines: Vec<Line> = message
        .lines()
        .map(|line| Line::from(Span::styled(line.to_owned(), style(DIM))))
        .collect();
    let height = lines.len() as u16;
    let top = area.y + area.height.saturating_sub(height) / 2;
    let rect = Rect::new(area.x, top, area.width, height.min(area.height));
    frame.render_widget(Paragraph::new(lines).centered(), rect);
}

fn render_help(frame: &mut Frame, area: Rect) {
    let lines = vec![
        Line::from(Span::styled(
            "usage-tui",
            Style::new().add_modifier(Modifier::BOLD),
        )),
        Line::raw(""),
        Line::raw("q           quit"),
        Line::raw("r           ask the engine to refresh now"),
        Line::raw("v           activity span: 7D / 30D / All"),
        Line::raw("c           measure in tokens or cost"),
        Line::raw("u           count all agents / the focused account"),
        Line::raw("p           polling pace: 3m / 5m / 15m"),
        Line::raw("a / A       pin the next account / back to auto"),
        Line::raw("click a mark pin that harness's account"),
        Line::raw("s z         on a meter: span, then zoom the frame"),
        Line::raw("arrows      move the cursor; enter/space opens"),
        Line::raw("1-3 / click open a meter's window chart"),
        Line::raw("click a day drill into it; ←→ step days"),
        Line::raw("[ ]         page the activity view into the past"),
        Line::raw("n           jump to the notifications"),
        Line::raw("x / X       dismiss the focused notification / all"),
        Line::raw("←→          scrub the open meter chart"),
        Line::raw("esc         back (cursor → surface → quit)"),
        Line::raw("mouse       hover readouts · wheel pages/scrubs"),
        Line::raw("?           toggle this help"),
    ];
    let width = 56.min(area.width.saturating_sub(2)).max(20);
    let height = (lines.len() as u16 + 2).min(area.height);
    let rect = Rect::new(
        area.x + (area.width - width) / 2,
        area.y + (area.height - height) / 2,
        width,
        height,
    );
    frame.render_widget(Clear, rect);
    frame.render_widget(
        Paragraph::new(lines).block(ratatui::widgets::Block::bordered().title(" help ")),
        rect,
    );
}

/// Item 25: the recent-sessions shortlist, the panel's strip in terminal
/// form. Titles and a basename-only project label are what the digest is
/// permitted to carry (§10 re-amendment 2026-08-17); this renders exactly
/// those fields and derives nothing further.
///
/// The line degrades by width rather than truncating to nonsense: a narrow
/// pane keeps the title and the cost, a roomier one earns duration, tokens
/// and prompts, and the widest adds project·branch. Model dots ride at the
/// left in the engine's ledger colours.
/// "SESSIONS · Claude Code (work) · 6 recent", fitted: under All agents the
/// owner says whose list this is, so the count gives way first, then the
/// owner is clipped.
fn sessions_title(owner: Option<&str>, count: usize, width: usize) -> String {
    let sep = glyphs().sep;
    let recent = if count > 0 {
        format!("{sep}{count} recent")
    } else {
        String::new()
    };
    let Some(owner) = owner else {
        return format!("SESSIONS{recent}");
    };
    let full = format!("SESSIONS{sep}{owner}{recent}");
    if full.chars().count() <= width {
        return full;
    }
    let head = format!("SESSIONS{sep}");
    let room = width.saturating_sub(head.chars().count()).max(4);
    format!("{head}{}", truncate(owner, room))
}

fn sessions<'a>(
    digest: &'a LiveState,
    owner: Option<&str>,
    accent: Color,
    rect: Rect,
    offset: UtcOffset,
) -> Paragraph<'a> {
    if activity_scanning(digest) {
        return scanning_lines("SESSIONS");
    }
    let cards = &digest.sessions;
    let mut title = sessions_title(owner, cards.len(), rect.width as usize);
    if let Some(as_of) = activity_as_of(digest, offset) {
        title.push_str(&as_of);
    }
    let mut lines = vec![section_title(&title)];

    if cards.is_empty() {
        lines.push(Line::from(Span::styled(
            "no sessions recorded yet",
            style(DIM),
        )));
        return Paragraph::new(lines);
    }

    let seats = (rect.height as usize).saturating_sub(1);
    let wide = rect.width >= 60;
    let shown: Vec<_> = cards.iter().take(seats).collect();

    // Column layout, right-anchored: the cost sits flush right in a fixed
    // column, the model dots right-align in their own column beside it
    // (up to three — beyond that they stop reading as a mix), and the
    // title owns what is left, clipping at the dots. Widths come from the
    // cards on screen, never from a guess: a guessed width once clipped
    // "$1,235.85" to "$1," — a wrong number, not a shortened one.
    let cost_w = shown
        .iter()
        .filter_map(|c| c.cost.map(|v| money(v).chars().count()))
        .max()
        .unwrap_or(0);
    let worked_w = shown
        .iter()
        .map(|c| worked(c.active_seconds).chars().count())
        .max()
        .unwrap_or(0);
    let tokens_w = shown
        .iter()
        .map(|c| compact(c.tokens).chars().count())
        .max()
        .unwrap_or(0);
    let dots_w = shown
        .iter()
        .map(|c| c.model_colors.len().min(3))
        .max()
        .unwrap_or(0);

    let block = |facts: bool| {
        let mut t = 0usize;
        if facts {
            t += 2 + worked_w + 2 + tokens_w;
        }
        if dots_w > 0 {
            t += 1 + dots_w;
        }
        if cost_w > 0 {
            t += 1 + cost_w;
        }
        t
    };
    // The time and token columns ride along only while the title keeps a
    // readable zone.
    let facts = rect.width >= 44 && (rect.width as usize) >= block(true) + 12;
    let tail = block(facts);

    for card in shown {
        let dot_count = card.model_colors.len().min(3);
        // A row with nothing on its right keeps the whole width — a blank
        // reserved grid would shorten a bare title for nothing.
        let tailed = facts || dot_count > 0 || card.cost.is_some();
        let zone = if tailed {
            (rect.width as usize).saturating_sub(tail).max(8)
        } else {
            rect.width as usize
        };

        let mut cells: Vec<Span> = Vec::new();
        // wide: the project rides dim after the title, and only when it
        // fits WHOLE — clipping the title to seat a branch name reads
        // worse than omitting the branch.
        let project = if wide {
            card.project.as_ref().map(|p| match &card.branch {
                Some(branch) => format!("{p}@{branch}"),
                None => p.clone(),
            })
        } else {
            None
        };
        let title_len = card.title.chars().count();
        let used = match project {
            Some(pb) if title_len + glyphs().sep.chars().count() + pb.chars().count() <= zone => {
                cells.push(Span::styled(card.title.clone(), style(accent)));
                cells.push(Span::styled(format!("{}{pb}", glyphs().sep), style(DIM)));
                title_len + glyphs().sep.chars().count() + pb.chars().count()
            }
            _ => {
                let visible = clip(&card.title, zone);
                let used = visible.chars().count();
                cells.push(Span::styled(visible, style(accent)));
                used
            }
        };
        if tailed {
            cells.push(Span::styled(
                " ".repeat(zone.saturating_sub(used)),
                style(DIM),
            ));
            if facts {
                cells.push(Span::styled(
                    format!(
                        "  {:>ww$}  {:>tw$}",
                        worked(card.active_seconds),
                        compact(card.tokens),
                        ww = worked_w,
                        tw = tokens_w
                    ),
                    style(DIM),
                ));
            }
            if dots_w > 0 {
                cells.push(Span::styled(" ".repeat(1 + dots_w - dot_count), style(DIM)));
                for color in card.model_colors.iter().take(3) {
                    cells.push(Span::styled(glyphs().dot.to_owned(), ramp(*color, 1.0)));
                }
            }
            if cost_w > 0 {
                match card.cost {
                    Some(cost) => cells.push(Span::styled(
                        format!(" {:>cw$}", money(cost), cw = cost_w),
                        style(DIM),
                    )),
                    // Absent cost is absent — blank, never "$0".
                    None => cells.push(Span::styled(" ".repeat(1 + cost_w), style(DIM))),
                }
            }
        }
        lines.push(Line::from(cells));
    }
    Paragraph::new(lines)
}

/// A session's honest working time — "2h 15m", "45m". Not `countdown`,
/// which measures toward a future instant and says "any moment" at zero.
fn worked(seconds: f64) -> String {
    let minutes = (seconds / 60.0).round() as i64;
    if minutes >= 60 {
        format!("{}h {}m", minutes / 60, minutes % 60)
    } else {
        format!("{}m", minutes.max(0))
    }
}

/// Trims to `room` columns, marking the cut so a clipped title never looks
/// like the whole one.
fn clip(text: &str, room: usize) -> String {
    if text.chars().count() <= room {
        return text.to_owned();
    }
    let kept: String = text.chars().take(room.saturating_sub(1)).collect();
    format!("{kept}{}", glyphs().ellipsis)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::digest::StatusIncident;
    use time::macros::date;

    /// The harness golden with one more shown harness whose only cell
    /// carries no meters — a harness that reads usage but no limit yet.
    fn digest_with_meterless_harness() -> LiveState {
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../Tests/UsageCoreTests/Fixtures/digest/live-state-v1-harnesses.json");
        let mut object: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).expect("harness golden"))
                .expect("golden is json");
        let harnesses = object["harnesses"].as_array_mut().expect("harnesses");
        let mut harness = harnesses
            .iter()
            .find(|h| h["id"] == "codex")
            .expect("codex harness")
            .clone();
        harness["id"] = "meterless".into();
        harness["glyph"] = "∩".into();
        harness["shown"] = true.into();
        harnesses.push(harness);
        let cells = object["menuBarCells"].as_array_mut().expect("cells");
        let mut cell = cells
            .iter()
            .find(|c| c["providerID"] == "codex")
            .expect("codex cell")
            .clone();
        cell["providerID"] = "meterless".into();
        cell["profile"] = "meterless".into();
        cell["segments"] = serde_json::json!([]);
        cells.push(cell);
        serde_json::from_value(object).expect("digest decodes")
    }

    fn harness_golden() -> serde_json::Value {
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../Tests/UsageCoreTests/Fixtures/digest/live-state-v1-harnesses.json");
        serde_json::from_slice(&std::fs::read(&path).expect("harness golden")).expect("json")
    }

    fn app_on(object: serde_json::Value) -> App {
        let mut app = App::new(
            std::path::PathBuf::from("/nonexistent/live-state.json"),
            None,
            time::UtcOffset::UTC,
        );
        app.digest = Some(serde_json::from_value(object).expect("digest decodes"));
        app
    }

    /// The golden's own clock, so its 7D period holds its activity.
    fn golden_now() -> OffsetDateTime {
        time::macros::datetime!(2026-09-19 12:00 UTC)
    }

    fn screen(app: &mut App, width: u16, height: u16) -> Vec<String> {
        let backend = ratatui::backend::TestBackend::new(width, height);
        let mut terminal = ratatui::Terminal::new(backend).expect("terminal");
        terminal
            .draw(|frame| render(frame, app, golden_now()))
            .expect("draw");
        let buffer = terminal.backend().buffer().clone();
        (0..height)
            .map(|y| (0..width).map(|x| buffer[(x, y)].symbol()).collect())
            .collect()
    }

    /// The keyboard cursor holds a ROW, not a position: a scan that lands
    /// and puts a row above it can't move it onto a row nobody chose.
    #[test]
    fn the_cursor_keeps_its_row_across_a_reload() {
        let mut app = app_on(harness_golden());
        screen(&mut app, 140, 40);
        let codex = app
            .hits
            .find(|hit| matches!(hit, Hit::ModelRow(id) if id.ends_with("gpt-5.2-codex")))
            .expect("the Codex model row is drawn");
        app.keyboard_mode = true;
        app.focus_hit = Some(codex);
        screen(&mut app, 140, 40);
        let activity_line = |lines: &[String]| {
            lines
                .iter()
                .find(|line| line.contains("ACTIVITY"))
                .cloned()
                .unwrap_or_default()
        };
        assert!(activity_line(&screen(&mut app, 140, 40)).contains("GPT 5.2 Codex"));
        // A heavier Codex model lands, seated above it.
        let mut object = harness_golden();
        let days = object["allAgents"]["activity"]["modelDays"]
            .as_array_mut()
            .expect("modelDays");
        let last = days.last_mut().expect("a day");
        let mut heavier = last["models"][1].clone();
        heavier["id"] = "zz-heavier".into();
        heavier["displayName"] = "Heavier".into();
        heavier["tally"]["input"] = 9_000_000.into();
        last["models"]
            .as_array_mut()
            .expect("models")
            .insert(0, heavier);
        app.digest = Some(serde_json::from_value(object).expect("digest decodes"));
        let after = screen(&mut app, 140, 40);
        let line = activity_line(&after);
        assert!(line.contains("GPT 5.2 Codex"), "{line}");
        assert!(!line.contains("Heavier"), "{line}");
    }

    /// The outline's extra rows never cost the pane a section one
    /// account's view would show (the activity chart, MODELS itself).
    #[test]
    fn the_outline_never_costs_a_section() {
        for (width, height) in [
            (46, 22),
            (90, 13),
            (46, 18),
            (60, 20),
            (72, 16),
            (100, 27),
            (120, 15),
        ] {
            let area = Rect::new(0, 0, width, height);
            let mut app = app_on(harness_golden());
            let digest = app.digest.clone().expect("digest");
            let all = dashboard_plan(
                area,
                &digest,
                &Dash::build(&app, &digest, area, golden_now()),
            );
            app.scope = crate::state::Scope::Account;
            let account = dashboard_plan(
                area,
                &digest,
                &Dash::build(&app, &digest, area, golden_now()),
            );
            assert!(
                layout::landed(&all) >= layout::landed(&account),
                "{width}x{height}: all agents lands {} sections, the account {}",
                layout::landed(&all),
                layout::landed(&account)
            );
        }
    }

    /// The day drill under All agents names its scope, and a model name
    /// two agents share stays two tellable rows.
    #[test]
    fn the_day_drill_names_its_scope_and_its_twins() {
        let mut app = app_on(harness_golden());
        app.surface = Surface::Day("2026-09-19".into());
        let lines = screen(&mut app, 160, 40);
        let text = lines.join("\n");
        assert!(text.contains("2 agents"), "{text}");
        assert!(text.contains("Other (Codex)"), "{text}");
        assert!(text.contains("Other (Claude)"), "{text}");
        // The focused account's own day names no twins.
        app.scope = crate::state::Scope::Account;
        let text = screen(&mut app, 160, 40).join("\n");
        assert!(!text.contains("Other ("), "{text}");
    }

    /// Whose sessions these are outlives the count when the title is tight.
    #[test]
    fn the_sessions_title_keeps_its_owner() {
        let owner = Some("Claude Code (dev@example.com)");
        assert_eq!(
            sessions_title(owner, 6, 80),
            "SESSIONS · Claude Code (dev@example.com) · 6 recent"
        );
        assert_eq!(
            sessions_title(owner, 6, 44),
            "SESSIONS · Claude Code (dev@example.com)"
        );
        let tight = sessions_title(owner, 6, 30);
        assert!(tight.starts_with("SESSIONS · Claude Code"), "{tight}");
        assert!(tight.chars().count() <= 30, "{tight}");
        assert_eq!(sessions_title(None, 6, 20), "SESSIONS · 6 recent");
    }

    /// "partial" is the one word saying a scan is still out of the total;
    /// a narrow readout gives up everything else first.
    #[test]
    fn a_narrow_readout_keeps_partial() {
        let mut object = harness_golden();
        object["allAgents"]["partial"] = true.into();
        object["allAgents"]["members"][1]["state"] = "scanning".into();
        object["allAgents"]["countLabel"] = "1 of 2 agents".into();
        let app = app_on(object);
        let digest = app.digest.clone().expect("digest");
        let window = ("2026-09-13", "2026-09-19");
        let wide = activity_readout(&app, &digest, None, window, 80);
        assert!(
            wide.contains("active days") && wide.ends_with("partial"),
            "{wide}"
        );
        // The narrowest dashboard column is ~38 wide (below 40 the strip
        // takes over); every width from there keeps the word.
        for width in [24, 30, 38, 46] {
            let line = activity_readout(&app, &digest, None, window, width);
            assert!(line.ends_with("partial"), "{width}: {line}");
            assert!(line.chars().count() <= width, "{width}: {line}");
        }
    }

    /// Where the account's MODELS title seats its column labels, the
    /// outline's does too.
    #[test]
    fn the_outline_keeps_the_column_labels() {
        for width in [46u16, 52, 60, 100] {
            let mut app = app_on(harness_golden());
            let all = screen(&mut app, width, 40);
            app.scope = crate::state::Scope::Account;
            let account = screen(&mut app, width, 40);
            let labelled = |lines: &[String], title: &str| {
                lines
                    .iter()
                    .find(|line| line.contains(title))
                    .is_some_and(|line| line.contains("input"))
            };
            assert_eq!(
                labelled(&all, "AGENTS · 7D"),
                labelled(&account, "MODELS · 7D"),
                "{width} columns"
            );
        }
    }

    /// The header's miniature keeps a shown harness that has no limits to
    /// show: its mark and a dash, as the menu bar draws `A–` (user-reported
    /// 2026-11-21: Antigravity's mark was missing beside Claude's).
    #[test]
    fn a_meterless_harness_keeps_its_mark() {
        let digest = digest_with_meterless_harness();
        let others = other_harnesses(&digest);
        let meterless = others
            .iter()
            .find(|other| other.glyph == "∩")
            .expect("the meterless harness is in the header");
        assert_eq!(
            meterless.cells,
            vec![("meterless".to_owned(), "—".to_owned())]
        );
        // The harness with meters still reads as before, and a hidden
        // harness (the golden's Gemini) stays absent.
        assert!(others.iter().any(|other| {
            other
                .cells
                .iter()
                .any(|(_, digits)| digits.chars().any(|c| c.is_ascii_digit()))
        }));
        assert!(others.iter().all(|other| other.glyph != "✦"));
    }

    #[test]
    fn meter_labels_keep_the_window_that_tells_them_apart() {
        let five = truncate_label("Claude + GPT (5h)", 12);
        let seven = truncate_label("Claude + GPT (7d)", 12);
        assert_eq!(five.chars().count(), 12);
        assert!(five.ends_with(" (5h)") && seven.ends_with(" (7d)"));
        assert_ne!(five, seven);
        // Too little head left: the plain cut, as before.
        assert_eq!(
            truncate_label("Weekly (Fable)", 12),
            truncate("Weekly (Fable)", 12)
        );
        assert_eq!(truncate_label("Argon (7d)", 12), "Argon (7d)");
        assert_eq!(truncate_label("Session (5h)", 12), "Session (5h)");
    }

    fn golden_digest(status: Option<(&str, Option<OffsetDateTime>)>) -> LiveState {
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../Tests/UsageCoreTests/Fixtures/digest/live-state-v1.json");
        let mut digest = LiveState::parse(&std::fs::read(path).unwrap()).unwrap();
        digest.activity_status = status.map(|(state, as_of)| crate::digest::ActivityStatus {
            state: state.into(),
            as_of,
        });
        digest
    }

    fn text(paragraph: Paragraph<'_>, width: u16, height: u16) -> String {
        use ratatui::buffer::Buffer;
        use ratatui::widgets::Widget;
        let rect = Rect::new(0, 0, width, height);
        let mut buffer = Buffer::empty(rect);
        paragraph.render(rect, &mut buffer);
        (0..height)
            .map(|y| {
                (0..width)
                    .map(|x| buffer[(x, y)].symbol().to_owned())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// Absent ≠ zero (2026-11-21): before the writer's first scan, the empty
    /// rollup must never read as "0 tok" or "no sessions recorded yet".
    #[test]
    fn a_scanning_digest_says_scanning_never_zero() {
        let digest = golden_digest(Some(("scanning", None)));
        let rect = Rect::new(0, 0, 60, 4);
        let head = text(today(&digest, None, Color::Reset, rect, UtcOffset::UTC), 60, 4);
        assert!(head.contains("scanning…"), "{head}");
        assert!(!head.contains("tok"), "{head}");
        let sessions = text(sessions(&digest, None, Color::Reset, rect, UtcOffset::UTC), 60, 4);
        assert!(sessions.contains("scanning…"), "{sessions}");
        assert!(!sessions.contains("no sessions recorded yet"), "{sessions}");
    }

    /// Busy is a sentence, not a grey-out (2026-11-21): the header says the
    /// engine is busy and how old the numbers are; the strip keeps its
    /// colours and adds `busy`.
    #[test]
    fn a_busy_engine_reads_busy_with_its_age_never_offline() {
        let digest = golden_digest(None);
        let now = digest.engine.generated_at + Duration::minutes(4);
        let app = crate::state::App::new(
            std::path::PathBuf::from("/nonexistent/live-state.json"),
            Some(std::path::PathBuf::from("/nonexistent/control.sock")),
            UtcOffset::UTC,
        );
        let (paragraph, _) = header(&digest, Freshness::Busy, &app, now, Color::Reset, 120);
        let head = text(paragraph, 120, 3);
        assert!(head.contains("engine busy — updating…"), "{head}");
        assert!(head.contains("last update 4m ago"), "{head}");
        assert!(!head.contains("offline"), "{head}");

        let backend = ratatui::backend::TestBackend::new(60, 1);
        let mut terminal = ratatui::Terminal::new(backend).unwrap();
        terminal
            .draw(|frame| render_strip(frame, frame.area(), &digest, Freshness::Busy, now))
            .unwrap();
        let buffer = terminal.backend().buffer();
        let strip: String = (0..60)
            .map(|x| buffer[(x, 0)].symbol().to_owned())
            .collect();
        assert!(
            strip.contains("busy") && !strip.contains("offline"),
            "{strip}"
        );
        let glyph = buffer[(0, 0)].style().fg;
        assert_ne!(glyph, Some(DIM), "a busy strip is not greyed: {strip}");
    }

    fn rendered(app: &mut crate::state::App, now: OffsetDateTime, width: u16, height: u16) -> String {
        let backend = ratatui::backend::TestBackend::new(width, height);
        let mut terminal = ratatui::Terminal::new(backend).unwrap();
        terminal.draw(|frame| render(frame, app, now)).unwrap();
        let buffer = terminal.backend().buffer();
        (0..height)
            .map(|y| {
                (0..width)
                    .map(|x| buffer[(x, y)].symbol().to_owned())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn app_at(lock: std::path::PathBuf) -> crate::state::App {
        let mut app = crate::state::App::new(
            lock.with_file_name("live-state.json"),
            Some(std::path::PathBuf::from("/nonexistent/control.sock")),
            UtcOffset::UTC,
        );
        app.lock_path = lock;
        app
    }

    /// The whole dashboard of a scanning account: the activity chart is
    /// "scanning…", never an empty chart over "0 tokens · 0 active days".
    #[test]
    fn a_scanning_dashboard_draws_no_empty_chart() {
        let digest = golden_digest(Some(("scanning", None)));
        let now = digest.engine.generated_at + Duration::minutes(1);
        let mut app = app_at(std::path::PathBuf::from("/nonexistent/engine.lock"));
        app.digest = Some(digest);
        let text = rendered(&mut app, now, 140, 50);
        assert!(text.contains("ACTIVITY"), "{text}");
        assert!(text.contains("scanning…"), "{text}");
        assert!(!text.contains("active days"), "{text}");
        assert!(!text.contains("0 tok"), "{text}");
    }

    /// No digest yet while a host holds the lease: busy starting, not the
    /// "launch the menu bar app" screen.
    #[test]
    fn no_digest_with_the_lease_held_is_busy_not_offline() {
        let dir = std::env::temp_dir().join(format!("tui-busy-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let lock = dir.join("engine.lock");
        let holder = std::fs::File::create(&lock).unwrap();
        holder.lock().unwrap();
        let mut app = app_at(lock.clone());
        let now = OffsetDateTime::now_utc();
        let busy = rendered(&mut app, now, 80, 12);
        assert!(busy.contains("engine busy — starting…"), "{busy}");
        assert!(!busy.contains("launch the menu bar app"), "{busy}");
        holder.unlock().unwrap();
        let offline = rendered(&mut app, now, 80, 12);
        assert!(offline.contains("launch the menu bar app"), "{offline}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_cached_digest_shows_its_numbers_and_their_age() {
        let as_of = OffsetDateTime::parse(
            "2026-08-16T11:12:00Z",
            &time::format_description::well_known::Rfc3339,
        )
        .unwrap();
        let digest = golden_digest(Some(("cached", Some(as_of))));
        let rect = Rect::new(0, 0, 80, 4);
        let cached = text(today(&digest, None, Color::Reset, rect, UtcOffset::UTC), 80, 4);
        assert!(
            cached.contains("tok") && cached.contains("as of 11:12"),
            "{cached}"
        );
        // A scanned (or marker-less) digest carries no age line.
        let plain = golden_digest(None);
        let fresh = text(today(&plain, None, Color::Reset, rect, UtcOffset::UTC), 80, 4);
        assert!(!fresh.contains("as of"), "{fresh}");
    }

    fn incident(impact: &str) -> ServiceStatusCard {
        card(
            impact,
            vec![StatusIncident {
                id: "i".into(),
                name: "Degraded performance for multiple models".into(),
                impact: impact.into(),
                phase: "monitoring".into(),
                started_at: OffsetDateTime::UNIX_EPOCH,
                last_update_at: None,
                last_message: Some("A fix has been implemented.".into()),
                url: None,
                component_names: vec![],
                resolved_at: None,
            }],
        )
    }

    fn card(indicator: &str, incidents: Vec<StatusIncident>) -> ServiceStatusCard {
        ServiceStatusCard {
            provider_id: "claude".into(),
            page_name: "Claude".into(),
            page_url: "https://status.claude.com".into(),
            indicator: indicator.into(),
            description_text: "".into(),
            checked_at: OffsetDateTime::UNIX_EPOCH,
            ok_at: None,
            stale: false,
            components: vec![],
            incidents,
            recently_resolved: vec![],
            maintenances: vec![],
        }
    }

    /// The prominence ladder (surface S6): severity buys rows, and quiet
    /// buys silence. A minor incident deliberately earns none — it speaks
    /// from the footer instead of pushing the dashboard down.
    #[test]
    fn severity_buys_dashboard_rows() {
        assert_eq!(status_rungs(None), 0);
        assert_eq!(status_rungs(Some(&card("none", vec![]))), 0);
        assert_eq!(status_rungs(Some(&card("maintenance", vec![]))), 0);
        assert_eq!(status_rungs(Some(&card("unknown", vec![]))), 0);
        assert_eq!(status_rungs(Some(&incident("minor"))), 0);
        assert_eq!(status_rungs(Some(&incident("major"))), 1);
        assert_eq!(status_rungs(Some(&incident("critical"))), 2);
    }

    /// Only the top rung spends a row on the message text; a major incident
    /// gets its name and phase, and nothing more.
    #[test]
    fn only_the_top_rung_carries_the_message() {
        let now = OffsetDateTime::UNIX_EPOCH + time::Duration::minutes(72);

        let major_card = incident("major");
        assert_eq!(status_banner_lines(&major_card, now, 80).len(), 1);

        let critical_card = incident("critical");
        let critical = status_banner_lines(&critical_card, now, 80);
        assert_eq!(critical.len(), 2);
        let message: String = critical[1]
            .spans
            .iter()
            .map(|span| span.content.to_string())
            .collect();
        assert!(message.contains("A fix has been implemented"));

        // A card with nothing open paints no banner at all.
        let quiet = card("none", vec![]);
        assert!(status_banner_lines(&quiet, now, 80).is_empty());
    }

    /// A quiet service says nothing at all in the footer without color —
    /// there is no news, and a bare mark would read as some.
    #[test]
    fn the_monochrome_footer_stays_silent_when_healthy() {
        let now = OffsetDateTime::UNIX_EPOCH;
        // The colored path always marks health; the mono path only speaks
        // when something is worth saying.
        let healthy = card("none", vec![]);
        let spans = status_footer_spans(Some(&healthy), now);
        if crate::state::look().no_color {
            assert!(spans.is_empty());
        } else {
            assert_eq!(spans.len(), 1, "one green cell");
        }
        assert!(
            status_footer_spans(None, now).is_empty(),
            "no card, no cell"
        );
    }

    /// The health mark owns the footer's right edge, and a pane too narrow
    /// for both clips the key hints rather than losing the mark or blanking
    /// the row.
    #[test]
    fn the_footer_keeps_the_mark_at_the_right_edge() {
        let now = OffsetDateTime::UNIX_EPOCH + time::Duration::minutes(72);
        let minor = incident("minor");
        let claim: usize = status_footer_spans(Some(&minor), now)
            .iter()
            .map(|span| span.content.chars().count())
            .sum();

        for width in [claim as u16 + 4, 80, 100, 200] {
            let mut spans = vec![Span::raw("q quit / r refresh / ? help".to_owned())];
            place_status_in_footer(&mut spans, status_footer_spans(Some(&minor), now), width);
            let painted: String = spans.iter().map(|s| s.content.to_string()).collect();
            assert!(
                painted.chars().count() <= width as usize,
                "footer must never overrun {width} columns"
            );
            assert!(
                painted.contains("1h 12m"),
                "the incident keeps the tail at {width} columns"
            );
            assert!(painted.starts_with('q'), "the key hints keep the head");
        }
    }

    #[test]
    fn a_reply_is_read_whole_and_the_keys_fold_to_help() {
        let keys =
            "q quit / r refresh / a account / v span / c cost / p pace / 1-3 meters / ? help";
        let reply = "focus pinned: Claude Code (A for auto)";
        // Room for both: nothing folds.
        assert_eq!(footer_keys(keys, Some(reply), 0, 200), keys);
        // A pane that would clip the reply keeps the reply, and `?` still
        // leads to every other key.
        assert_eq!(footer_keys(keys, Some(reply), 0, 100), "? help");
        // The health mark's claim counts too.
        assert_eq!(footer_keys(keys, Some(reply), 60, 130), "? help");
        // No reply: the full list, however tight — the trailer goes first.
        assert_eq!(footer_keys(keys, None, 0, 60), keys);
    }

    /// Rungs that own a banner must not repeat themselves in the footer.
    #[test]
    fn the_footer_only_narrates_what_the_banner_does_not() {
        let now = OffsetDateTime::UNIX_EPOCH + time::Duration::minutes(72);
        let text = |card: &ServiceStatusCard| {
            status_footer_spans(Some(card), now)
                .iter()
                .map(|span| span.content.to_string())
                .collect::<String>()
        };
        // Minor owns no banner rows, so the footer carries the whole story.
        assert!(text(&incident("minor")).contains("Degraded performance"));
        assert!(text(&incident("minor")).contains("1h 12m"));
        // Major and critical are already on screen above.
        assert!(!text(&incident("major")).contains("Degraded performance"));
        assert!(!text(&incident("critical")).contains("Degraded performance"));
    }

    #[test]
    fn compact_matches_token_format_tiers() {
        assert_eq!(compact(999), "999");
        assert_eq!(compact(12_300), "12.3K");
        assert_eq!(compact(1_200_000), "1.2M");
        assert_eq!(compact(3_000_000_000), "3B");
        assert_eq!(compact(150_000), "150K");
    }

    #[test]
    fn data_weeks_spans_monday_to_monday() {
        let day = |key: &str| DayRollup {
            day_key: key.into(),
            tokens: 1,
            prompts: 0,
            cost: None,
        };
        // 2026-08-16 is a Sunday (week of Mon 08-10). One same-week day.
        assert_eq!(data_weeks(&[day("2026-08-12")], date!(2026 - 08 - 16)), 1);
        // A Sunday one week back sits in the previous Monday week.
        assert_eq!(data_weeks(&[day("2026-08-09")], date!(2026 - 08 - 16)), 2);
        // Mon 06-01 → Mon 08-10 is ten whole weeks, both endpoints counted.
        assert_eq!(data_weeks(&[day("2026-06-01")], date!(2026 - 08 - 16)), 11);
        // No data: today's own week.
        assert_eq!(data_weeks(&[], date!(2026 - 08 - 16)), 1);
    }

    #[test]
    fn heat_grid_aligns_weeks_to_monday_and_pages_back() {
        let days = vec![DayRollup {
            day_key: "2026-06-01".into(),
            tokens: 10,
            prompts: 0,
            cost: None,
        }];
        // 2026-08-16 is a Sunday; its week's Monday is 08-10.
        let grid = heat_grid(&days, 4, 0, date!(2026 - 08 - 16));
        let last_week = grid.weeks.last().unwrap();
        assert_eq!(last_week[0], Some(date!(2026 - 08 - 10)));
        assert_eq!(last_week[6], Some(date!(2026 - 08 - 16)));
        assert!(grid.has_older);
        assert!(!grid.has_newer);

        let paged = heat_grid(&days, 4, 1, date!(2026 - 08 - 16));
        assert_eq!(paged.weeks.last().unwrap()[0], Some(date!(2026 - 07 - 13)));
        assert!(paged.has_newer);
    }
}
