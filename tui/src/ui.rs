//! The dashboard renderer. Everything drawn here is a straight projection
//! of the digest — pre-phrased captions, resolved colors, precomputed
//! rollups; the only things the TUI formats itself are clocks and
//! countdowns (design §7). Calm at rest: fixed lines, no layout shift.

use crate::digest::{HourBucket, LiveState, Rgb};
use crate::layout::{self, Plan, Shape};
use crate::state::{App, Freshness};
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};
use ratatui::Frame;
use time::{OffsetDateTime, UtcOffset};

// The app's pinned palette (StatusItemRenderer's values).
const WARNING: Color = Color::Rgb(255, 159, 10);
const CRITICAL: Color = Color::Rgb(255, 69, 58);
const DIM: Color = Color::Rgb(140, 140, 145);
const FAINT: Color = Color::Rgb(70, 70, 75);

fn rgb(color: Rgb) -> Color {
    Color::Rgb(
        (color.red * 255.0).round() as u8,
        (color.green * 255.0).round() as u8,
        (color.blue * 255.0).round() as u8,
    )
}

/// Terminal "alpha": scale toward black, the committed dark ground.
fn ramp(color: Rgb, alpha: f64) -> Color {
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

fn money(dollars: f64) -> String {
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

pub fn render(frame: &mut Frame, app: &App, now: OffsetDateTime) {
    let area = frame.area();
    let Some(digest) = &app.digest else {
        render_offline(frame, area, app);
        return;
    };
    let freshness = app.freshness(now);
    if layout::shape(area) == Shape::Strip {
        render_strip(frame, area, digest, freshness);
        return;
    }
    let plan = layout::plan(area, digest.meters.len(), digest.models.len().min(4));
    render_dashboard(frame, digest, freshness, &plan, app, now);
    if app.show_help {
        render_help(frame, area);
    }
}

fn render_dashboard(
    frame: &mut Frame,
    digest: &LiveState,
    freshness: Freshness,
    plan: &Plan,
    app: &App,
    now: OffsetDateTime,
) {
    let accent = rgb(digest.engine.accent);
    if let Some(rect) = plan.header {
        frame.render_widget(header(digest, freshness, app, now, accent), rect);
    }
    if let Some(rect) = plan.meters {
        frame.render_widget(meters(digest, freshness, rect), rect);
    }
    if let Some(rect) = plan.today {
        frame.render_widget(today(digest, accent, rect), rect);
    }
    if let Some(rect) = plan.models {
        frame.render_widget(models(digest, rect), rect);
    }
    if let Some(rect) = plan.heatmap {
        frame.render_widget(heatmap(digest, rect), rect);
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
            spans.push(Span::styled(
                format!("  {caption}"),
                Style::new().fg(DIM),
            ));
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
    let mut lines = vec![section_title(&title.clone())];

    // 24 fixed hour cells so the day reads as a clock face; heights over
    // the day's own max.
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

/// The GitHub-strip form: weeks as columns, weekdays as rows, intensity as
/// an accent ramp; faint dots keep empty days visible (design §4).
fn heatmap<'a>(digest: &'a LiveState, rect: Rect) -> Paragraph<'a> {
    let days = &digest.activity.days;
    let mut lines = vec![section_title("ACTIVITY")];
    let grid_rows = 7usize;
    let cell = 2usize;
    let weeks = ((rect.width as usize).saturating_sub(4) / cell).clamp(4, 60);
    let visible = weeks * 7;
    let tail: Vec<_> = days
        .iter()
        .rev()
        .take(visible)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    let max = tail.iter().map(|d| d.tokens).max().unwrap_or(0).max(1);

    let available = (rect.height.max(1) - 1) as usize;
    let rows = grid_rows.min(available);
    for row in 0..rows {
        let mut spans: Vec<Span> = Vec::with_capacity(weeks);
        for week in 0..weeks {
            let index = week * 7 + row;
            let span = match tail.get(index) {
                Some(day) if day.tokens > 0 => {
                    let alpha = 0.25 + 0.75 * (day.tokens as f64 / max as f64).sqrt();
                    Span::styled("█".repeat(cell), Style::new().fg(ramp(digest.engine.accent, alpha)))
                }
                Some(day) if day.prompts > 0 => {
                    // Prompt-only day (transcripts cleaned up): faint but
                    // present, exactly like the app's faint wash.
                    Span::styled(
                        "▪".to_string() + &" ".repeat(cell - 1),
                        Style::new().fg(ramp(digest.engine.accent, 0.35)),
                    )
                }
                Some(_) => Span::styled(
                    "·".to_string() + &" ".repeat(cell - 1),
                    Style::new().fg(FAINT),
                ),
                None => Span::raw(" ".repeat(cell)),
            };
            spans.push(span);
        }
        lines.push(Line::from(spans));
    }
    Paragraph::new(lines)
}

fn footer<'a>(
    digest: &'a LiveState,
    freshness: Freshness,
    app: &'a App,
    now: OffsetDateTime,
) -> Paragraph<'a> {
    let mut spans = vec![Span::styled(
        "q quit · r refresh · ? help",
        Style::new().fg(FAINT),
    )];
    if let Some(notice) = &app.notice {
        spans.push(Span::styled(
            format!("  {notice}"),
            Style::new().fg(DIM),
        ));
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
        Line::raw("q / esc     quit (esc closes this help)"),
        Line::raw("r           ask the engine to refresh now"),
        Line::raw("?           toggle this help"),
        Line::raw(""),
        Line::from(Span::styled(
            "meter charts, heatmap paging, and the mouse grammar land in v0.68",
            Style::new().fg(DIM),
        )),
    ];
    let width = 64.min(area.width.saturating_sub(2)).max(20);
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

fn truncate(text: &str, width: usize) -> String {
    if text.chars().count() <= width {
        text.to_owned()
    } else {
        let mut out: String = text.chars().take(width.saturating_sub(1)).collect();
        out.push('…');
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compact_matches_token_format_tiers() {
        assert_eq!(compact(999), "999");
        assert_eq!(compact(12_300), "12.3K");
        assert_eq!(compact(1_200_000), "1.2M");
        assert_eq!(compact(3_000_000_000), "3B");
        assert_eq!(compact(150_000), "150K");
    }
}
