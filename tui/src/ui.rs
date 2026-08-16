//! The dashboard renderer. Everything drawn here is a straight projection
//! of the digest — pre-phrased captions, resolved colors, precomputed
//! rollups; the only things the TUI formats itself are clocks and
//! countdowns (design §7). Calm at rest: fixed lines, no layout shift.
//! Every render pass rebuilds the hit map — the mouse resolves against
//! what was actually painted.

use crate::activity::{self, ModelTotal};
use crate::digest::{DayRollup, HourBucket, LiveState, Rgb};
use crate::layout::{self, Plan, Shape};
use crate::state::{App, Dimension, Freshness, Hit, Period, Surface};
use crate::surfaces;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};
use ratatui::Frame;
use std::collections::HashMap;
use std::sync::OnceLock;
use time::{Date, OffsetDateTime, UtcOffset};

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

pub fn truncate(text: &str, width: usize) -> String {
    if text.chars().count() <= width {
        text.to_owned()
    } else {
        let mut out: String = text.chars().take(width.saturating_sub(1)).collect();
        out.push(glyphs().ellipsis);
        out
    }
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
    let halo = app
        .hover_hit
        .as_ref()
        .and_then(|hit| app.hits.rect_of(hit));
    app.focus_hit = focus;
    app.hits.clear();
    let area = frame.area();
    let Some(digest) = app.digest.clone() else {
        render_offline(frame, area, app);
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
            let plan = layout::plan(area, data.meter_rows, data.model_rows, data.activity_rows);
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
                let plan =
                    layout::plan(left, data.meter_rows, data.model_rows, data.activity_rows);
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
                if !no_color {
                    if let Color::Rgb(r, g, b) = cell.fg {
                        lift = lift.fg(brighten(r, g, b));
                    }
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
    models: Vec<ModelTotal>,
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
    activity_rows: u16,
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
        let days = &digest.activity.days;
        let (start, end) = activity::span(app.period, app.heat_page, today, days);
        let (start_key, end_key) = (activity::day_key(start), activity::day_key(end));
        let (start_date, end_date) = (start, end);
        let models = activity::model_totals(&digest.activity, &start_key, &end_key);
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
        let activation_note = match app.period {
            Period::Week => digest
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
            models_truncated: activity::model_horizon_truncates(&digest.activity, &start_key),
            start: start_key,
            end: end_key,
            start_date,
            end_date,
            // Title, up to four models, and the cost rollup line.
            model_rows: (models.len().min(4) as u16) + 2,
            models,
            weeks,
            activation_note,
            // The credits line rides inside the meters section when the
            // provider sent one.
            meter_rows: digest.meters.len() as u16
                + u16::from(digest.engine.spend.is_some())
                + 1,
            activity_rows,
        }
    }

    /// The model the pane is currently focused on, if any — the one hover
    /// treatment every activity form reads.
    fn filter<'a>(&'a self, app: &App) -> Option<&'a ModelTotal> {
        match &app.hover_hit {
            Some(Hit::ModelRow(index)) => self.models.get(*index),
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
        frame.render_widget(header(digest, freshness, app, now, accent, rect.width), rect);
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
    if let Some(rect) = plan.today {
        frame.render_widget(today(digest, accent, rect), rect);
    }
    if let Some(rect) = plan.models {
        // Rows the section can seat: its height minus the title and the
        // cost rollup line that closes it.
        let seats = (rect.height as usize).saturating_sub(2);
        frame.render_widget(models(app, data, seats, rect), rect);
        for index in 0..data.models.len().min(seats) {
            app.hits.add(
                Rect::new(rect.x, rect.y + 1 + index as u16, rect.width, 1),
                Hit::ModelRow(index),
            );
        }
    }
    if let Some(rect) = plan.heatmap {
        match app.period {
            Period::Week => render_bars(frame, app, digest, data, rect),
            _ => render_heatmap(frame, app, digest, data, rect),
        }
    }
    if let Some(rect) = plan.footer {
        frame.render_widget(footer(digest, freshness, app, now), rect);
    }
}

fn section_title(text: &str) -> Line<'static> {
    Line::from(Span::styled(
        text.to_owned(),
        style(DIM).add_modifier(Modifier::BOLD),
    ))
}

fn header<'a>(
    digest: &'a LiveState,
    freshness: Freshness,
    app: &'a App,
    now: OffsetDateTime,
    accent: Color,
    width: u16,
) -> Paragraph<'a> {
    let engine = &digest.engine;
    let mut identity = vec![
        Span::styled(
            format!("{} ", engine.glyph),
            style(accent).add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            engine.service_name.clone(),
            Style::new().add_modifier(Modifier::BOLD),
        ),
    ];
    if let Some(plan) = &engine.plan_label {
        identity.push(Span::styled(format!("  {plan}"), style(DIM)));
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
                        if compact { stamp } else { format!("updated {stamp}") },
                        style(DIM),
                    ));
                }
                if let Some(next) = engine.next_poll_at {
                    let count = countdown(next, now);
                    status.push(Span::styled(
                        format!(
                            "{}{}",
                            glyphs().sep,
                            if compact { format!("next {count}") } else { format!("next in {count}") }
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
                        if compact { stamp } else { format!("as of {stamp}") },
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
            Freshness::EngineOffline => {
                status.push(Span::styled(
                    "engine offline — start: usage-cli daemon start",
                    style(CRITICAL),
                ));
                return status;
            }
        }
        // Cadence transparency, the panel status line's grammar: "idle ×N"
        // says why "next in" reads slower than the chosen pace.
        if engine.pace_multiplier > 1 {
            status.push(Span::styled(
                format!("{}idle ×{}", glyphs().sep, engine.pace_multiplier),
                style(DIM),
            ));
        }
        if !engine.is_local_provider {
            if let (Some(used), Some(ceiling)) =
                (engine.api_budget_used, engine.api_budget_ceiling)
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
        }
        status
    };
    let full = build(false);
    let length: usize = full.iter().map(|span| span.content.chars().count()).sum();
    let status = if length <= width as usize { full } else { build(true) };
    Paragraph::new(vec![Line::from(identity), Line::from(status)])
}

fn meters<'a>(digest: &'a LiveState, freshness: Freshness, rect: Rect) -> Paragraph<'a> {
    let mut lines = vec![section_title("LIMITS")];
    let grey = freshness == Freshness::Stale || freshness == Freshness::EngineOffline;
    let rows = (rect.height.max(1) - 1) as usize;
    let spend = digest.engine.spend.as_ref();
    let visible =
        &digest.meters[..digest.meters.len().min(rows.saturating_sub(usize::from(spend.is_some())))];

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
                format!("{:<label_width$} ", truncate(&meter.label, label_width)),
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
        if let Some(forecast) = &meter.forecast {
            if let Some(caption) = &forecast.caption {
                spans.push(Span::styled(
                    format!("{}{caption}", glyphs().sep),
                    style(bar_color),
                ));
            }
        }
        lines.push(Line::from(spans));
    }
    if let Some(spend) = spend {
        if lines.len() <= rows {
            lines.push(Line::from(vec![
                Span::styled(format!("{:<15}", "credits"), style(DIM)),
                Span::styled(spend_text(spend), Style::new()),
            ]));
        }
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
        format!("{symbol}{scaled:.precision$}", precision = spend.exponent.max(0) as usize)
    };
    match spend.limit_minor {
        Some(limit) => format!("{} of {}", amount(spend.used_minor), amount(limit)),
        None => amount(spend.used_minor),
    }
}

fn today<'a>(digest: &'a LiveState, accent: Color, rect: Rect) -> Paragraph<'a> {
    let activity = &digest.activity;
    let mut title = format!("TODAY{}{} tok", glyphs().sep, compact(activity.today_tokens));
    if let Some(cost) = activity.today_cost {
        title.push_str(&format!("{}{}", glyphs().sep, money(cost)));
    }
    title.push_str(&format!("{}{} prompts", glyphs().sep, activity.today_prompts));
    let mut lines = vec![section_title(&title)];

    let mut buckets = [0i64; 24];
    for HourBucket { hour, tokens, .. } in &activity.today_hours {
        if (*hour as usize) < 24 {
            buckets[*hour as usize] = *tokens;
        }
    }
    let max = buckets.iter().copied().max().unwrap_or(0).max(1);
    let spark_glyphs = glyphs().spark;
    let cell_width = ((rect.width as usize) / 24).clamp(1, 6);
    let mut spark: Vec<Span> = Vec::with_capacity(24);
    for tokens in buckets {
        let span = if tokens == 0 {
            Span::styled(glyphs().dot.repeat(cell_width), style(FAINT))
        } else {
            let step = (((tokens * 7 + max - 1) / max) as usize).min(7);
            Span::styled(
                spark_glyphs[step].to_string().repeat(cell_width),
                style(accent),
            )
        };
        spark.push(span);
    }
    lines.push(Line::from(spark));
    lines.push(Line::from(Span::styled(
        format!("{:<width$}12{:>width$}", "0", "23", width = cell_width * 12 - 1),
        style(FAINT),
    )));
    Paragraph::new(lines)
}

/// The MODELS section: the app's breakdown grid, terminal-fitted. Rows
/// follow the active period (not just today), and where the pane affords
/// it they carry the same four columns the app separates — fresh input
/// apart from the cache re-reads an agentic loop dwarfs it with.
fn models<'a>(app: &App, data: &'a Dash, seats: usize, rect: Rect) -> Paragraph<'a> {
    let wide = rect.width >= 46;
    let name_width = (rect.width as usize)
        .saturating_sub(if wide { 36 } else { 20 })
        .clamp(8, 22);
    let mut lines = vec![models_title(app, data, name_width, wide, rect.width)];

    if data.models.is_empty() {
        lines.push(Line::from(Span::styled(
            format!("no usage in this {}", app.period.label()),
            style(FAINT),
        )));
        return Paragraph::new(lines);
    }
    for model in data.models.iter().take(seats) {
        let dim = data
            .filter(app)
            .is_some_and(|filter| filter.id != model.id);
        lines.push(model_row(model, name_width, wide, dim));
    }
    lines.push(cost_rollup(&data.models, seats));
    Paragraph::new(lines)
}

/// One breakdown row: the model's dot and name, then either the four
/// token classes the app separates or a single total, and its cost — "—"
/// when unpriced, never $0. `dim` is the legend-filter treatment.
pub fn model_row(model: &ModelTotal, name_width: usize, wide: bool, dim: bool) -> Line<'static> {
    let mut spans = vec![
        Span::styled(
            glyphs().live,
            style(if dim {
                ramp(model.color, 0.45)
            } else {
                rgb(model.color)
            }),
        ),
        Span::styled(
            format!("{:<name_width$}", truncate(&model.display_name, name_width)),
            if dim { style(DIM) } else { Style::new() },
        ),
    ];
    if wide {
        spans.push(Span::styled(
            format!("{:>8}", compact(model.tally.uncached_input())),
            style(DIM),
        ));
        spans.push(Span::styled(
            format!("{:>8}", compact(model.tally.cache_read)),
            style(FAINT),
        ));
        spans.push(Span::styled(
            format!("{:>8}", compact(model.tally.output)),
            style(DIM),
        ));
    } else {
        spans.push(Span::styled(
            format!("{:>8}", compact(model.tally.total())),
            style(DIM),
        ));
    }
    spans.push(Span::styled(
        format!(
            "{:>10}",
            model.cost.map(money).unwrap_or_else(|| "—".into())
        ),
        if dim { style(DIM) } else { Style::new() },
    ));
    Line::from(spans)
}

/// The breakdown table's column labels, for surfaces that seat them on
/// their own row rather than folding them into a section title.
pub fn model_columns(name_width: usize, wide: bool) -> Line<'static> {
    let labels = if wide {
        format!("{:>8}{:>8}{:>8}{:>10}", "input", "cached", "output", "est. cost")
    } else {
        format!("{:>8}{:>10}", "tokens", "est. cost")
    };
    Line::from(Span::styled(
        format!("{:width$}{labels}", "", width = 2 + name_width),
        style(FAINT),
    ))
}

/// "MODELS · 7D" with the grid's column labels flushed right when the pane
/// is wide enough to seat them over their own columns.
fn models_title(app: &App, data: &Dash, name_width: usize, wide: bool, width: u16) -> Line<'static> {
    let mut title = format!("MODELS{}{}", glyphs().sep, app.period.label());
    if data.models_truncated {
        // No silent caps: per-model rows exist for ~35 days only.
        title.push_str(&format!("{}last ~35d", glyphs().sep));
    }
    let labels = if wide {
        format!("{:>8}{:>8}{:>8}{:>10}", "input", "cached", "output", "est. cost")
    } else {
        String::new()
    };
    // Labels ride the title line only when they fit over their own
    // columns without crowding the title.
    let head_room = 2 + name_width;
    if labels.is_empty()
        || title.chars().count() + 1 > head_room
        || head_room + labels.chars().count() > width as usize
    {
        return section_title(&title);
    }
    let pad = head_room - title.chars().count();
    Line::from(vec![
        Span::styled(title, style(DIM).add_modifier(Modifier::BOLD)),
        Span::styled(format!("{:pad$}{labels}", ""), style(FAINT)),
    ])
}

/// "≈ $1,308 at API list prices" — the grid's headline over EVERY model
/// in scope, the honest tail when some have no rates at all, and the
/// count of any the section had no room to seat (a cap nobody is told
/// about reads as "this is all of it").
pub fn cost_rollup(rows: &[ModelTotal], shown: usize) -> Line<'static> {
    let priced: Vec<f64> = rows.iter().filter_map(|row| row.cost).collect();
    let unpriced = rows.len() - priced.len();
    let total: f64 = priced.iter().sum();
    let mut text = if priced.is_empty() {
        "no priced models — costs unavailable".to_owned()
    } else {
        format!("≈ {} at API list prices", money(total))
    };
    if unpriced > 0 && !priced.is_empty() {
        text.push_str(&format!("{}{unpriced} unpriced", glyphs().sep));
    }
    if rows.len() > shown {
        text.push_str(&format!("{}+{} more", glyphs().sep, rows.len() - shown));
    }
    Line::from(Span::styled(text, style(FAINT)))
}

// MARK: - Heatmap (two forms, weekday-true, paged — design §4)

/// The four density cells, doubled to cell width — leaked once, static
/// forever (four tiny strings).
fn heat_cell_text(quartile: usize) -> &'static str {
    static CELLS: OnceLock<[String; 4]> = OnceLock::new();
    let cells = CELLS.get_or_init(|| {
        let g = glyphs().heat_density;
        [g[0].repeat(2), g[1].repeat(2), g[2].repeat(2), g[3].repeat(2)]
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
    while cells.len() % 7 != 0 {
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
    filter: Option<&ModelTotal>,
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
    if let Some(model) = filter {
        push(
            &mut spans,
            &mut width,
            format!("{}{}", glyphs().sep, model.display_name),
            style(rgb(model.color)),
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
    filter: Option<&ModelTotal>,
    window: (&str, &str),
) -> String {
    if let Some(Hit::HeatDay(key)) = &app.hover_hit {
        if let Some(day) = digest
            .activity
            .days
            .iter()
            .find(|day| &day.day_key == key)
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
    }
    let measure = |value: f64| match app.dimension {
        Dimension::Tokens => format!("{} tokens", compact(value as i64)),
        Dimension::Cost => format!("≈ {}", money(value)),
    };
    let (start, end) = window;
    if let Some(model) = filter {
        let days = digest
            .activity
            .model_days
            .iter()
            .filter(|day| day.day_key.as_str() >= start && day.day_key.as_str() <= end)
            .filter(|day| day.models.iter().any(|m| m.id == model.id))
            .count();
        return format!(
            "{}{}{}{}{days} active days",
            model.display_name,
            glyphs().sep,
            measure(model.value(app.dimension)),
            glyphs().sep
        );
    }
    let total = activity::total_value(&digest.activity.days, start, end, app.dimension);
    let active = activity::active_days(&digest.activity.days, start, end);
    format!("{}{}{active} active days", measure(total), glyphs().sep)
}

/// The 7D form: one stacked bar per day in the models' ledger colors, its
/// total floating above, weekday and date beneath — the app's signature
/// activity chart, terminal-fitted (item 10).
fn render_bars(frame: &mut Frame, app: &mut App, digest: &LiveState, data: &Dash, rect: Rect) {
    let filter = data.filter(app);
    let by_key: HashMap<&str, &DayRollup> = digest
        .activity
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
    let oldest = digest
        .activity
        .days
        .first()
        .map(|day| day.day_key.as_str())
        .unwrap_or("");
    let has_older = days
        .first()
        .map(|date| activity::day_key(*date))
        .is_some_and(|key| key.as_str() > oldest);
    let back_label = (app.heat_page > 0).then(|| format!("{}w back", app.heat_page));
    let (title, older_x, newer_x) =
        activity_title(app, filter, back_label, has_older, app.heat_page > 0);
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
    let plot_height = rect
        .height
        .saturating_sub(4 + note.len() as u16)
        .max(1) as usize;
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
                    cells: vec![(ramp(digest.engine.accent, 0.35), glyphs().bar_fill); rows],
                    label: String::new(),
                };
            }
            let rows = (((value / max) * usable as f64).round() as usize).clamp(1, plot_height);
            let segments = activity::segments(&digest.activity, &key, &data.models, app.dimension);
            let mut colors: Vec<(Color, &'static str)> = Vec::with_capacity(rows);
            if segments.is_empty() {
                colors.resize(rows, (fill_accent(digest), glyphs().bar_fill));
            } else {
                // Rows split by share, largest remainder so the stack sums
                // to the bar's height exactly; the period's heaviest model
                // sits at the bottom of every bar, so bands line up.
                let mut assigned: Vec<(usize, (Color, &'static str))> = segments
                    .iter()
                    .enumerate()
                    .map(|(index, (id, color, fraction))| {
                        let dim = filter.is_some_and(|model| &model.id != id);
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
                colors.resize(rows, (fill_accent(digest), glyphs().bar_fill));
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
            let mut style = if offset == 0 { style(DIM) } else { style(FAINT) };
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
            Rect::new(rect.x, plot_top + plot_height as u16 + offset, rect.width, 1),
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
            activity_readout(app, digest, filter, (&data.start, &data.end)),
            style(FAINT),
        ))),
        Rect::new(rect.x, rect.y + rect.height - 1, rect.width, 1),
    );
}

/// The 30D and All forms: the calendar grid (portrait) or the weekday
/// strip (landscape), scoped to the active period.
fn render_heatmap(frame: &mut Frame, app: &mut App, digest: &LiveState, data: &Dash, rect: Rect) {
    let days = &digest.activity.days;
    let by_key: HashMap<&str, &DayRollup> =
        days.iter().map(|d| (d.day_key.as_str(), d)).collect();
    // A hovered/focused model row filters the grid to that model's own
    // days, in its ledger color — the pane's version of the app's
    // hover-to-filter. Calendar geometry stays unfiltered: paging and
    // week rows never shrink under a filter.
    let filter = data.filter(app);
    let heat_values: HashMap<&str, f64> = match filter {
        Some(model) => digest
            .activity
            .model_days
            .iter()
            .filter_map(|day| {
                day.models
                    .iter()
                    .find(|m| m.id == model.id)
                    .map(|m| {
                        let value = match app.dimension {
                            Dimension::Tokens => m.tally.total() as f64,
                            Dimension::Cost => m.cost.unwrap_or(0.0),
                        };
                        (day.day_key.as_str(), value)
                    })
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
    let heat_color = filter.map(|m| m.color).unwrap_or(digest.engine.accent);
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
    let (title, older_x, newer_x) =
        activity_title(app, filter, back_label, grid.has_older, grid.has_newer);
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
        } else if filter.is_none()
            && by_key.get(key.as_str()).is_some_and(|day| day.prompts > 0)
        {
            cell_style = style(ramp(digest.engine.accent, 0.35));
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
            let mut spans = vec![Span::styled(
                format!("{} ", letters[row]),
                style(FAINT),
            )];
            for (week_index, week) in grid.weeks.iter().enumerate() {
                let (text, style) = cell(week[row]);
                spans.push(Span::styled(text, style));
                if let Some(date) = week[row] {
                    if let Ok(key) = date.format(surfaces::DAY_KEY) {
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
                if let Some(date) = date {
                    if let Ok(key) = date.format(surfaces::DAY_KEY) {
                        app.hits.add(
                            Rect::new(
                                rect.x + (slot as u16) * 3,
                                grid_y + 1 + row as u16,
                                2,
                                1,
                            ),
                            Hit::HeatDay(key),
                        );
                    }
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
            activity_readout(app, digest, filter, (&window.0, &window.1)),
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
) -> Paragraph<'a> {
    let keys = match app.surface {
        Surface::Dashboard => "q quit / r refresh / v span / c cost / p pace / 1-3 meters / ? help",
        Surface::Meter(_) => "esc back / arrows scrub / s span / z zoom / r refresh / ? help",
        _ => "esc back / arrows step / r refresh / ? help",
    };
    let mut spans = vec![Span::styled(keys, style(FAINT))];
    if let Some(notice) = &app.notice {
        spans.push(Span::styled(format!("  {notice}"), style(DIM)));
    } else if freshness == Freshness::Backoff {
        if let Some(until) = digest.engine.backoff_until {
            spans.push(Span::styled(
                format!("  429 backoff{}resumes in {}", glyphs().sep, countdown(until, now)),
                style(WARNING),
            ));
        }
    } else {
        spans.push(Span::styled(
            format!(
                "  {}{}v{}{}{}",
                digest.engine.host, glyphs().sep, digest.engine.app_version, glyphs().sep,
                digest.activity.time_zone
            ),
            style(FAINT),
        ));
    }
    Paragraph::new(Line::from(spans))
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
    let grey = freshness != Freshness::Live && freshness != Freshness::Backoff;
    let mut spans = vec![Span::styled(
        format!("{} ", digest.engine.glyph),
        style(if grey { DIM } else { accent }),
    )];
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
        spans.push(Span::styled(
            format!("{} ", segment.tag),
            style(DIM),
        ));
        spans.push(Span::styled(
            segment
                .percent
                .map(|p| format!("{p}"))
                .unwrap_or_else(|| "—".into()),
            style(color).add_modifier(Modifier::BOLD),
        ));
    }
    if freshness == Freshness::EngineOffline {
        spans.push(Span::styled(
            "  offline".to_owned(),
            style(CRITICAL),
        ));
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

fn render_offline(frame: &mut Frame, area: Rect, app: &App) {
    let message = if let Some(error) = &app.decode_error {
        format!("digest unreadable: {error}")
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
        Line::raw("p           polling pace: 3m / 5m / 15m"),
        Line::raw("s z         on a meter: span, then zoom the frame"),
        Line::raw("arrows      move the cursor; enter/space opens"),
        Line::raw("1-3 / click open a meter's window chart"),
        Line::raw("click a day drill into it; ←→ step days"),
        Line::raw("[ ]         page the activity view into the past"),
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

#[cfg(test)]
mod tests {
    use super::*;
    use time::macros::date;

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
