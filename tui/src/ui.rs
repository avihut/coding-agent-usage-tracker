//! The dashboard renderer. Everything drawn here is a straight projection
//! of the digest — pre-phrased captions, resolved colors, precomputed
//! rollups; the only things the TUI formats itself are clocks and
//! countdowns (design §7). Calm at rest: fixed lines, no layout shift.
//! Every render pass rebuilds the hit map — the mouse resolves against
//! what was actually painted.

use crate::digest::{DayRollup, HourBucket, LiveState, Rgb};
use crate::layout::{self, Plan, Shape};
use crate::state::{App, Freshness, Hit, Surface};
use crate::surfaces;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};
use ratatui::Frame;
use std::collections::HashMap;
use time::{Date, OffsetDateTime, UtcOffset};

// The app's pinned palette (StatusItemRenderer's values).
pub const WARNING: Color = Color::Rgb(255, 159, 10);
pub const CRITICAL: Color = Color::Rgb(255, 69, 58);
pub const DIM: Color = Color::Rgb(140, 140, 145);
pub const FAINT: Color = Color::Rgb(70, 70, 75);

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

pub fn money(dollars: f64) -> String {
    if dollars >= 100.0 {
        format!("${dollars:.0}")
    } else {
        format!("${dollars:.2}")
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
        out.push('…');
        out
    }
}

pub fn render(frame: &mut Frame, app: &mut App, now: OffsetDateTime) {
    app.hover_hit = app
        .pointer
        .and_then(|(x, y)| app.hits.at(x, y).cloned());
    app.hits.clear();
    let area = frame.area();
    let Some(digest) = app.digest.clone() else {
        render_offline(frame, area, app);
        return;
    };
    let freshness = app.freshness(now);
    if layout::shape(area) == Shape::Strip {
        render_strip(frame, area, &digest, freshness);
        return;
    }

    match app.surface.clone() {
        Surface::Dashboard => {
            let plan = layout::plan(area, digest.meters.len(), digest.models.len().min(4));
            render_dashboard(frame, app, &digest, freshness, &plan, now);
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
                let plan = layout::plan(left, digest.meters.len(), digest.models.len().min(4));
                render_dashboard(frame, app, &digest, freshness, &plan, now);
                render_surface(frame, app, &digest, &surface, right, false, now);
            } else {
                render_surface(frame, app, &digest, &surface, area, true, now);
            }
        }
    }
    if app.show_help {
        render_help(frame, area);
    }
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

fn render_dashboard(
    frame: &mut Frame,
    app: &mut App,
    digest: &LiveState,
    freshness: Freshness,
    plan: &Plan,
    now: OffsetDateTime,
) {
    let accent = rgb(digest.engine.accent);
    if let Some(rect) = plan.header {
        frame.render_widget(header(digest, freshness, app, now, accent), rect);
    }
    if let Some(rect) = plan.meters {
        frame.render_widget(meters(digest, freshness, rect), rect);
        for (index, _) in digest
            .meters
            .iter()
            .take((rect.height.max(1) - 1) as usize)
            .enumerate()
        {
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
        frame.render_widget(models(digest, rect), rect);
        for (index, _) in digest
            .models
            .iter()
            .take((rect.height.max(1) - 1) as usize)
            .enumerate()
        {
            app.hits.add(
                Rect::new(rect.x, rect.y + 1 + index as u16, rect.width, 1),
                Hit::ModelRow(index),
            );
        }
    }
    if let Some(rect) = plan.heatmap {
        render_heatmap(frame, app, digest, rect, now);
    }
    if let Some(rect) = plan.footer {
        frame.render_widget(footer(digest, freshness, app, now), rect);
    }
}

fn section_title(text: &str) -> Line<'static> {
    Line::from(Span::styled(
        text.to_owned(),
        Style::new().fg(DIM).add_modifier(Modifier::BOLD),
    ))
}

fn header<'a>(
    digest: &'a LiveState,
    freshness: Freshness,
    app: &'a App,
    now: OffsetDateTime,
    accent: Color,
) -> Paragraph<'a> {
    let engine = &digest.engine;
    let mut identity = vec![
        Span::styled(
            format!("{} ", engine.glyph),
            Style::new().fg(accent).add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            engine.service_name.clone(),
            Style::new().add_modifier(Modifier::BOLD),
        ),
    ];
    if let Some(plan) = &engine.plan_label {
        identity.push(Span::styled(format!("  {plan}"), Style::new().fg(DIM)));
    }

    let mut status: Vec<Span> = Vec::new();
    match freshness {
        Freshness::Live => {
            status.push(Span::styled("● ", Style::new().fg(accent)));
            if let Some(fetched) = engine.fetched_at {
                status.push(Span::styled(
                    format!("updated {}", clock(fetched, app.local_offset)),
                    Style::new().fg(DIM),
                ));
            }
            if let Some(next) = engine.next_poll_at {
                status.push(Span::styled(
                    format!(" · next in {}", countdown(next, now)),
                    Style::new().fg(DIM),
                ));
            }
        }
        Freshness::Stale => {
            status.push(Span::styled("○ ", Style::new().fg(DIM)));
            if let Some(fetched) = engine.fetched_at {
                status.push(Span::styled(
                    format!("as of {}", clock(fetched, app.local_offset)),
                    Style::new().fg(DIM),
                ));
            }
            if let Some(error) = &engine.error {
                status.push(Span::styled(
                    format!(" · {}", error.text),
                    Style::new().fg(WARNING),
                ));
            }
        }
        Freshness::Backoff => {
            status.push(Span::styled("◌ ", Style::new().fg(WARNING)));
            if let Some(until) = engine.backoff_until {
                status.push(Span::styled(
                    format!("rate limited — resumes in {}", countdown(until, now)),
                    Style::new().fg(WARNING),
                ));
            }
        }
        Freshness::EngineOffline => {
            status.push(Span::styled(
                "engine offline — start: usage-cli daemon start",
                Style::new().fg(CRITICAL),
            ));
        }
    }
    if !engine.is_local_provider {
        if let (Some(used), Some(ceiling)) = (engine.api_budget_used, engine.api_budget_ceiling) {
            status.push(Span::styled(
                format!(" · API {used}/{ceiling}h"),
                Style::new().fg(FAINT),
            ));
        }
    }
    Paragraph::new(vec![Line::from(identity), Line::from(status)])
}

fn meters<'a>(digest: &'a LiveState, freshness: Freshness, rect: Rect) -> Paragraph<'a> {
    let mut lines = vec![section_title("LIMITS")];
    let grey = freshness == Freshness::Stale || freshness == Freshness::EngineOffline;
    for meter in digest.meters.iter().take((rect.height.max(1) - 1) as usize) {
        let bar_color = if grey {
            DIM
        } else if let Some(risk) = meter.risk {
            rgb(risk)
        } else {
            match meter.level.as_str() {
                "warning" => WARNING,
                "critical" => CRITICAL,
                _ => rgb(digest.engine.accent),
            }
        };
        let label_width = 12usize;
        let bar_width = (rect.width as usize)
            .saturating_sub(label_width + 25)
            .clamp(8, 30);
        let percent = meter.percent.unwrap_or(0).clamp(0, 100) as usize;
        let filled = (percent * bar_width).div_ceil(100).min(bar_width);
        let mut spans = vec![
            Span::styled(
                format!("{} ", meter.tag),
                Style::new().fg(DIM).add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!("{:<label_width$} ", truncate(&meter.label, label_width)),
                Style::new(),
            ),
            Span::styled("█".repeat(filled), Style::new().fg(bar_color)),
            Span::styled("░".repeat(bar_width - filled), Style::new().fg(FAINT)),
            match meter.percent {
                Some(p) => Span::styled(
                    format!(" {p:>3}%"),
                    Style::new().fg(bar_color).add_modifier(Modifier::BOLD),
                ),
                None => Span::styled("   —".to_owned(), Style::new().fg(DIM)),
            },
        ];
        if let Some(caption) = &meter.reset_caption {
            spans.push(Span::styled(format!("  {caption}"), Style::new().fg(DIM)));
        }
        if let Some(forecast) = &meter.forecast {
            if let Some(caption) = &forecast.caption {
                spans.push(Span::styled(
                    format!(" · {caption}"),
                    Style::new().fg(bar_color),
                ));
            }
        }
        lines.push(Line::from(spans));
    }
    Paragraph::new(lines)
}

fn today<'a>(digest: &'a LiveState, accent: Color, rect: Rect) -> Paragraph<'a> {
    let activity = &digest.activity;
    let mut title = format!("TODAY · {} tok", compact(activity.today_tokens));
    if let Some(cost) = activity.today_cost {
        title.push_str(&format!(" · {}", money(cost)));
    }
    title.push_str(&format!(" · {} prompts", activity.today_prompts));
    let mut lines = vec![section_title(&title)];

    let mut buckets = [0i64; 24];
    for HourBucket { hour, tokens, .. } in &activity.today_hours {
        if (*hour as usize) < 24 {
            buckets[*hour as usize] = *tokens;
        }
    }
    let max = buckets.iter().copied().max().unwrap_or(0).max(1);
    let glyphs = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
    let cell_width = ((rect.width as usize) / 24).clamp(1, 3);
    let mut spark: Vec<Span> = Vec::with_capacity(24);
    for tokens in buckets {
        let span = if tokens == 0 {
            Span::styled("·".repeat(cell_width), Style::new().fg(FAINT))
        } else {
            let step = (((tokens * 7 + max - 1) / max) as usize).min(7);
            Span::styled(
                glyphs[step].to_string().repeat(cell_width),
                Style::new().fg(accent),
            )
        };
        spark.push(span);
    }
    lines.push(Line::from(spark));
    lines.push(Line::from(Span::styled(
        format!("{:<width$}12{:>width$}", "0", "23", width = cell_width * 12 - 1),
        Style::new().fg(FAINT),
    )));
    Paragraph::new(lines)
}

fn models<'a>(digest: &'a LiveState, rect: Rect) -> Paragraph<'a> {
    let mut lines = vec![section_title("MODELS · today")];
    let rows = (rect.height.max(1) - 1) as usize;
    if digest.models.is_empty() {
        lines.push(Line::from(Span::styled(
            "no usage yet today",
            Style::new().fg(FAINT),
        )));
    }
    for model in digest.models.iter().take(rows) {
        let name_width = (rect.width as usize).saturating_sub(20).clamp(8, 22);
        let cost = match model.cost {
            Some(cost) => money(cost),
            None => "—".into(),
        };
        lines.push(Line::from(vec![
            Span::styled("● ", Style::new().fg(rgb(model.color))),
            Span::styled(
                format!("{:<name_width$}", truncate(&model.display_name, name_width)),
                Style::new(),
            ),
            Span::styled(
                format!("{:>7}", compact(model.tally.total())),
                Style::new().fg(DIM),
            ),
            Span::styled(format!("{cost:>9}"), Style::new()),
        ]));
    }
    Paragraph::new(lines)
}

// MARK: - Heatmap (two forms, weekday-true, paged — design §4)

struct HeatGrid {
    /// Weeks in the visible window, oldest first; each week is 7 Mondays-
    /// first day keys.
    weeks: Vec<[Option<Date>; 7]>,
    has_older: bool,
    has_newer: bool,
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

fn render_heatmap(
    frame: &mut Frame,
    app: &mut App,
    digest: &LiveState,
    rect: Rect,
    now: OffsetDateTime,
) {
    let days = &digest.activity.days;
    let by_key: HashMap<&str, &DayRollup> =
        days.iter().map(|d| (d.day_key.as_str(), d)).collect();
    let max = days.iter().map(|d| d.tokens).max().unwrap_or(0).max(1);
    let today = now.to_offset(app.local_offset).date();
    let landscape = rect.width > rect.height * 4;

    // Rows: title, grid, readout. Portrait grids weeks-as-rows; landscape
    // weeks-as-columns (7 fixed rows).
    let grid_height = rect.height.saturating_sub(2) as usize;
    let weeks_visible = if landscape {
        ((rect.width as usize).saturating_sub(3) / 2).clamp(4, 60)
    } else {
        grid_height.max(1)
    };
    let grid = heat_grid(days, weeks_visible, app.heat_page, today);

    // Title row with the pager; zones register as hits.
    let mut title_spans = vec![Span::styled(
        "ACTIVITY".to_owned(),
        Style::new().fg(DIM).add_modifier(Modifier::BOLD),
    )];
    if app.heat_page > 0 {
        title_spans.push(Span::styled(
            format!(" · {}w back", weeks_visible * app.heat_page),
            Style::new().fg(DIM),
        ));
    }
    title_spans.push(Span::raw("  "));
    title_spans.push(Span::styled(
        if grid.has_older { "‹" } else { " " }.to_owned(),
        Style::new().fg(if grid.has_older { DIM } else { FAINT }),
    ));
    title_spans.push(Span::raw(" "));
    title_spans.push(Span::styled(
        if grid.has_newer { "›" } else { " " }.to_owned(),
        Style::new().fg(if grid.has_newer { DIM } else { FAINT }),
    ));
    frame.render_widget(
        Paragraph::new(Line::from(title_spans)),
        Rect::new(rect.x, rect.y, rect.width, 1),
    );
    let pager_x = rect.x + 8 + if app.heat_page > 0 { 9 } else { 0 };
    if grid.has_older {
        app.hits
            .add(Rect::new(pager_x + 2, rect.y, 1, 1), Hit::PageEarlier);
    }
    if grid.has_newer {
        app.hits
            .add(Rect::new(pager_x + 4, rect.y, 1, 1), Hit::PageLater);
    }

    let hovered_day = match &app.hover_hit {
        Some(Hit::HeatDay(key)) => Some(key.clone()),
        _ => None,
    };

    let cell = |date: Option<Date>| -> (String, Style) {
        let Some(date) = date else {
            return ("  ".into(), Style::new());
        };
        let key = date.format(surfaces::DAY_KEY).unwrap_or_default();
        let entry = by_key.get(key.as_str());
        let mut style;
        let text;
        match entry {
            Some(day) if day.tokens > 0 => {
                let alpha = 0.25 + 0.75 * (day.tokens as f64 / max as f64).sqrt();
                style = Style::new().fg(ramp(digest.engine.accent, alpha));
                text = "██";
            }
            Some(day) if day.prompts > 0 => {
                style = Style::new().fg(ramp(digest.engine.accent, 0.35));
                text = "▪ ";
            }
            _ => {
                style = Style::new().fg(FAINT);
                text = "· ";
            }
        }
        if date == today {
            style = style.add_modifier(Modifier::UNDERLINED);
        }
        if hovered_day.as_deref() == Some(key.as_str()) {
            style = style.add_modifier(Modifier::REVERSED);
        }
        (text.into(), style)
    };

    let grid_y = rect.y + 1;
    if landscape {
        // Weekday letters gutter + weeks as columns.
        let letters = ["M", "T", "W", "T", "F", "S", "S"];
        for row in 0..7usize.min(grid_height) {
            let mut spans = vec![Span::styled(
                format!("{} ", letters[row]),
                Style::new().fg(FAINT),
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
                Style::new().fg(FAINT),
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

    // Fixed readout line: the hovered day, else the pager hint.
    let readout_y = rect.y + rect.height - 1;
    let readout = hovered_day
        .as_deref()
        .and_then(|key| by_key.get(key).copied())
        .map(|day| {
            let mut text = format!("{} · {} tok", day.day_key, compact(day.tokens));
            if let Some(cost) = day.cost {
                text.push_str(&format!(" · {}", money(cost)));
            }
            if day.prompts > 0 {
                text.push_str(&format!(" · {} prompts", day.prompts));
            }
            text.push_str("  (click to drill)");
            text
        })
        .unwrap_or_else(|| "[ ] page · click a day to drill".into());
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(readout, Style::new().fg(FAINT)))),
        Rect::new(rect.x, readout_y, rect.width, 1),
    );
}

fn footer<'a>(
    digest: &'a LiveState,
    freshness: Freshness,
    app: &'a App,
    now: OffsetDateTime,
) -> Paragraph<'a> {
    let keys = match app.surface {
        Surface::Dashboard => "q quit · r refresh · 1-3 meters · ? help",
        _ => "esc back · ←→ step · r refresh · ? help",
    };
    let mut spans = vec![Span::styled(keys, Style::new().fg(FAINT))];
    if let Some(notice) = &app.notice {
        spans.push(Span::styled(format!("  {notice}"), Style::new().fg(DIM)));
    } else if freshness == Freshness::Backoff {
        if let Some(until) = digest.engine.backoff_until {
            spans.push(Span::styled(
                format!("  429 backoff · resumes in {}", countdown(until, now)),
                Style::new().fg(WARNING),
            ));
        }
    } else {
        spans.push(Span::styled(
            format!(
                "  {} · v{} · {}",
                digest.engine.host, digest.engine.app_version, digest.activity.time_zone
            ),
            Style::new().fg(FAINT),
        ));
    }
    Paragraph::new(Line::from(spans))
}

/// Below the floor: one line that still says everything (design §3).
fn render_strip(frame: &mut Frame, area: Rect, digest: &LiveState, freshness: Freshness) {
    let accent = rgb(digest.engine.accent);
    let grey = freshness != Freshness::Live && freshness != Freshness::Backoff;
    let mut spans = vec![Span::styled(
        format!("{} ", digest.engine.glyph),
        Style::new().fg(if grey { DIM } else { accent }),
    )];
    for (index, segment) in digest.menu_bar.iter().enumerate() {
        if index > 0 {
            spans.push(Span::styled(" · ".to_owned(), Style::new().fg(FAINT)));
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
            Style::new().fg(DIM),
        ));
        spans.push(Span::styled(
            segment
                .percent
                .map(|p| format!("{p}"))
                .unwrap_or_else(|| "—".into()),
            Style::new().fg(color).add_modifier(Modifier::BOLD),
        ));
    }
    if freshness == Freshness::EngineOffline {
        spans.push(Span::styled(
            "  offline".to_owned(),
            Style::new().fg(CRITICAL),
        ));
    } else if grey {
        spans.push(Span::styled("  stale".to_owned(), Style::new().fg(DIM)));
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
        .map(|line| Line::from(Span::styled(line.to_owned(), Style::new().fg(DIM))))
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
        Line::raw("1-3 / click open a meter's window chart"),
        Line::raw("click a day drill into it; ←→ step days"),
        Line::raw("[ ]         page the heatmap into the past"),
        Line::raw("←→          scrub the open meter chart"),
        Line::raw("esc         back (surface → dashboard → quit)"),
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
