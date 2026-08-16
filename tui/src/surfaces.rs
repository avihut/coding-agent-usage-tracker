//! Detail surfaces (design §3): a meter's window chart and a day's drill.
//! In landscape they sit beside the dashboard; in portrait they replace it
//! behind a `← back` header. Readouts are fixed lines — hover and scrub
//! swap text in place, never reflowing the layout under the cursor.

use crate::activity::ModelTotal;
use crate::digest::{DayRollup, LiveState, LiveMeter};
use crate::state::{App, Dimension, Hit};
use crate::ui::{compact, glyphs, money, ramp, rgb, CRITICAL, DIM, FAINT, WARNING};
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::symbols;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Axis, Chart, Dataset, GraphType, Paragraph};
use ratatui::Frame;
use time::format_description::BorrowedFormatItem;
use time::macros::format_description;
use time::{Date, OffsetDateTime};

pub const DAY_KEY: &[BorrowedFormatItem<'static>] = format_description!("[year]-[month]-[day]");
const AXIS_TIME: &[BorrowedFormatItem<'static>] = format_description!("[hour]:[minute]");
const AXIS_DAY: &[BorrowedFormatItem<'static>] =
    format_description!("[day padding:none].[month padding:none]");

/// The `← back` affordance both surfaces share in push mode.
pub fn back_line(app: &mut App, rect: Rect, title: &str) -> Line<'static> {
    app.hits.add(Rect::new(rect.x, rect.y, 7, 1), Hit::Back);
    Line::from(vec![
        Span::styled(glyphs().back, crate::ui::style(DIM).add_modifier(Modifier::BOLD)),
        Span::styled(format!("  {title}"), Style::new().add_modifier(Modifier::BOLD)),
    ])
}

// MARK: - Meter surface

pub fn render_meter(
    frame: &mut Frame,
    app: &mut App,
    digest: &LiveState,
    index: usize,
    rect: Rect,
    pushed: bool,
    now: OffsetDateTime,
) {
    let Some(meter) = digest.meters.get(index) else { return };
    let accent = rgb(digest.engine.accent);
    let risk = meter.risk.map(rgb);
    let line_color = risk.unwrap_or(accent);

    let mut lines: Vec<Line> = Vec::new();
    let title = format!(
        "{} {}  {}",
        meter.tag,
        meter.label,
        meter
            .percent
            .map(|p| format!("{p}%"))
            .unwrap_or_else(|| "—".into())
    );
    if pushed {
        lines.push(back_line(app, rect, &title));
    } else {
        lines.push(Line::from(Span::styled(
            title,
            Style::new().add_modifier(Modifier::BOLD),
        )));
    }
    let mut caption: Vec<Span> = Vec::new();
    if let Some(reset) = &meter.reset_caption {
        caption.push(Span::styled(reset.clone(), crate::ui::style(DIM)));
    }
    if let Some(forecast) = &meter.forecast {
        if let Some(projected) = forecast.projected_at_reset {
            caption.push(Span::styled(
                format!("  proj. {projected}%"),
                crate::ui::style(line_color),
            ));
        }
        if let Some(text) = &forecast.caption {
            caption.push(Span::styled(
                format!("  {text}"),
                crate::ui::style(risk.unwrap_or(WARNING)),
            ));
        }
    }
    lines.push(Line::from(caption));
    let header_rows = lines.len() as u16;
    frame.render_widget(Paragraph::new(lines), rect);

    // Chart body: measured series in braille, the forecast's trajectory in
    // dots, over the meter's own window.
    let chart_area = Rect::new(
        rect.x,
        rect.y + header_rows,
        rect.width,
        rect.height.saturating_sub(header_rows + 2),
    );
    if chart_area.height < 3 || meter.series.is_empty() {
        return;
    }
    let base = meter.series.first().map(|p| p.t).unwrap_or(now);
    let minutes = |t: OffsetDateTime| (t - base).whole_seconds() as f64 / 60.0;
    let measured: Vec<(f64, f64)> =
        meter.series.iter().map(|p| (minutes(p.t), p.percent)).collect();
    let trajectory: Vec<(f64, f64)> = meter
        .forecast
        .iter()
        .flat_map(|f| f.curve.iter())
        .map(|p| (minutes(p.t), p.percent))
        .collect();
    let x_end = trajectory
        .last()
        .map(|p| p.0)
        .into_iter()
        .chain(measured.last().map(|p| p.0))
        .chain(meter.resets_at.map(minutes))
        .fold(1.0f64, f64::max);
    let now_x = minutes(now).clamp(0.0, x_end);
    let now_marker = vec![(now_x, 0.0), (now_x, 25.0), (now_x, 50.0), (now_x, 75.0), (now_x, 100.0)];

    let mut datasets = vec![Dataset::default()
        .marker(symbols::Marker::Braille)
        .graph_type(GraphType::Line)
        .style(crate::ui::style(line_color))
        .data(&measured)];
    if !trajectory.is_empty() {
        datasets.push(
            Dataset::default()
                .marker(symbols::Marker::Dot)
                .graph_type(GraphType::Scatter)
                .style(crate::ui::style(risk.unwrap_or(DIM)))
                .data(&trajectory),
        );
    }
    datasets.push(
        Dataset::default()
            .marker(symbols::Marker::Dot)
            .graph_type(GraphType::Scatter)
            .style(crate::ui::style(FAINT))
            .data(&now_marker),
    );
    // Axis labels arrive with size: a roomy pane earns time marks along
    // the bottom and a finer percent ladder; a tight one keeps every row
    // for the plot. ratatui spreads labels EVENLY across the bounds, so
    // honesty is arithmetic: the y top is 112.5 (overshoot headroom) and
    // ten 12.5-steps put real values under "50" and "100", blanks between.
    let x_labeled = chart_area.width >= 44 && chart_area.height >= 9;
    let mut x_axis = Axis::default().bounds([0.0, x_end]);
    if x_labeled {
        let marks: usize = if chart_area.width >= 76 { 5 } else { 3 };
        let format = if x_end <= 36.0 * 60.0 { AXIS_TIME } else { AXIS_DAY };
        let labels: Vec<Span> = (0..marks)
            .map(|mark| {
                let minutes_in = x_end * mark as f64 / (marks - 1) as f64;
                let at = base + time::Duration::seconds((minutes_in * 60.0) as i64);
                Span::styled(
                    at.to_offset(app.local_offset)
                        .format(format)
                        .unwrap_or_default(),
                    crate::ui::style(FAINT),
                )
            })
            .collect();
        x_axis = x_axis.labels(labels).style(crate::ui::style(FAINT));
    }
    let y_labels: Vec<&str> = if chart_area.height >= 14 {
        vec!["0", "", "25", "", "50", "", "75", "", "100", ""]
    } else {
        vec!["0", "", "", "", "50", "", "", "", "100", ""]
    };
    let chart = Chart::new(datasets)
        .x_axis(x_axis)
        .y_axis(
            Axis::default()
                .bounds([0.0, 112.5])
                .labels(y_labels)
                .labels_alignment(ratatui::layout::Alignment::Right)
                .style(crate::ui::style(FAINT)),
        );
    frame.render_widget(chart, chart_area);

    // The session-stretch track under the plot, exhausted tail in red.
    let track_y = chart_area.y + chart_area.height;
    if track_y < rect.y + rect.height {
        let width = chart_area.width.saturating_sub(4) as usize;
        let mut cells = vec![Span::styled(glyphs().nub_idle.repeat(width), crate::ui::style(FAINT))];
        if width > 0 && x_end > 0.0 {
            let mut painted = vec![None::<bool>; width];
            for stretch in &meter.stretches {
                let from = ((minutes(stretch.start) / x_end) * width as f64).floor() as usize;
                let to = ((minutes(stretch.end) / x_end) * width as f64).ceil() as usize;
                for cell in painted.iter_mut().take(to.min(width)).skip(from.min(width)) {
                    *cell = Some(stretch.exhausted);
                }
            }
            cells = painted
                .iter()
                .map(|cell| match cell {
                    Some(true) => Span::styled(glyphs().nub_active, crate::ui::style(CRITICAL)),
                    Some(false) => Span::styled(glyphs().nub_active, crate::ui::style(line_color)),
                    None => Span::styled(glyphs().nub_idle, crate::ui::style(FAINT)),
                })
                .collect();
        }
        frame.render_widget(
            Paragraph::new(Line::from(cells)),
            Rect::new(chart_area.x + 4, track_y, chart_area.width.saturating_sub(4), 1),
        );
    }

    // Fixed readout line: the scrub cursor's sample, else the freshest one.
    let readout_y = track_y + 1;
    if readout_y < rect.y + rect.height {
        let picked = app
            .scrub
            .and_then(|back| meter.series.iter().rev().nth(back))
            .or(meter.series.last());
        let text = picked
            .map(|point| {
                let local = point.t.to_offset(app.local_offset);
                format!(
                    "{:02}:{:02}{}{:.0}%{}",
                    local.hour(),
                    local.minute(),
                    glyphs().sep,
                    point.percent,
                    if app.scrub.is_some() { "  (arrows scrub, esc back)" } else { "" }
                )
            })
            .unwrap_or_default();
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(text, crate::ui::style(DIM)))),
            Rect::new(rect.x, readout_y, rect.width, 1),
        );
    }
}

// MARK: - Day surface

pub fn render_day(
    frame: &mut Frame,
    app: &mut App,
    digest: &LiveState,
    day_key: &str,
    rect: Rect,
    pushed: bool,
) {
    let day: Option<&DayRollup> = digest.activity.days.iter().find(|d| d.day_key == day_key);
    let accent = rgb(digest.engine.accent);
    let mut lines: Vec<Line> = Vec::new();
    let pretty = Date::parse(day_key, DAY_KEY)
        .map(|d| format!("{} {} {}", d.weekday(), d.day(), d.month()))
        .unwrap_or_else(|_| day_key.to_owned());
    let mut title = pretty;
    if let Some(day) = day {
        title.push_str(&format!("{}{} tok", glyphs().sep, compact(day.tokens)));
        if let Some(cost) = day.cost {
            title.push_str(&format!("{}{}", glyphs().sep, money(cost)));
        }
        if day.prompts > 0 {
            title.push_str(&format!("{}{} prompts", glyphs().sep, day.prompts));
        }
    }
    if pushed {
        lines.push(back_line(app, rect, &title));
    } else {
        lines.push(Line::from(Span::styled(
            title,
            Style::new().add_modifier(Modifier::BOLD),
        )));
    }
    lines.push(Line::default());

    // The app's non-ring day drill, terminal-idiomized: the day drawn as a
    // chart with real height, then the same breakdown grid underneath —
    // per-model composition plus the four token classes and the priced
    // rollup. (A donut is a GUI idiom; bars carry the same composition
    // where cells are the only ink.)
    let models: Vec<ModelTotal> = digest
        .activity
        .model_days
        .iter()
        .find(|entry| entry.day_key == day_key)
        .map(|entry| entry.models.iter().map(ModelTotal::from).collect())
        .unwrap_or_default();

    let wide = rect.width >= 46;
    let name_width = (rect.width as usize)
        .saturating_sub(if wide { 36 } else { 20 })
        .clamp(8, 22);
    // Rows the table and its chrome will claim, so the chart takes only
    // what is genuinely spare.
    let table_rows = if models.is_empty() {
        2
    } else {
        3 + models.len().min(6) + 1
    };
    let spare = (rect.height as usize)
        .saturating_sub(lines.len() + table_rows + 2)
        .min(8);

    let hours = digest
        .activity
        .hour_days
        .iter()
        .find(|entry| entry.day_key == day_key);
    match hours {
        Some(hours) => {
            let mut buckets = [0.0f64; 24];
            for bucket in &hours.hours {
                if (bucket.hour as usize) < 24 {
                    buckets[bucket.hour as usize] = match app.dimension {
                        Dimension::Tokens => bucket.tokens as f64,
                        Dimension::Cost => bucket.cost.unwrap_or(0.0),
                    };
                }
            }
            let max = buckets.iter().copied().fold(0.0_f64, f64::max);
            let cell = ((rect.width as usize) / 24).clamp(1, 3);
            if spare >= 2 && max > 0.0 {
                // A real plot: 24 hour columns, height carrying magnitude.
                for row in 0..spare {
                    let from_bottom = spare - 1 - row;
                    let mut spans: Vec<Span> = Vec::new();
                    for value in buckets {
                        let filled = if value > 0.0 {
                            (((value / max) * spare as f64).round() as usize).max(1)
                        } else {
                            0
                        };
                        spans.push(if from_bottom < filled {
                            Span::styled(glyphs().bar_fill.repeat(cell), crate::ui::style(accent))
                        } else {
                            Span::raw(" ".repeat(cell))
                        });
                    }
                    lines.push(Line::from(spans));
                }
            } else {
                // Too short for a plot — the one-line spark still speaks.
                let spark_glyphs = glyphs().spark;
                let mut spark: Vec<Span> = Vec::new();
                for value in buckets {
                    spark.push(if value <= 0.0 {
                        Span::styled(glyphs().dot.repeat(cell), crate::ui::style(FAINT))
                    } else {
                        let step = ((value / max.max(f64::MIN_POSITIVE) * 7.0).ceil() as usize)
                            .clamp(0, 7);
                        Span::styled(
                            spark_glyphs[step].to_string().repeat(cell),
                            crate::ui::style(accent),
                        )
                    });
                }
                lines.push(Line::from(spark));
            }
            lines.push(Line::from(Span::styled(
                format!("{:<width$}12{:>width$}", "0", "23", width = cell * 12 - 1),
                crate::ui::style(FAINT),
            )));
        }
        None if day.is_some() => {
            lines.push(Line::from(Span::styled(
                "hourly detail is kept ~8 days — totals only for this day",
                crate::ui::style(FAINT),
            )));
        }
        None => {
            lines.push(Line::from(Span::styled(
                "no recorded activity on this day",
                crate::ui::style(FAINT),
            )));
        }
    }
    lines.push(Line::default());

    // Per-model table inside the 35-day drill horizon; labeled beyond.
    if !models.is_empty() {
        lines.push(Line::from(Span::styled(
            "MODELS".to_owned(),
            crate::ui::style(DIM).add_modifier(Modifier::BOLD),
        )));
        lines.push(crate::ui::model_columns(name_width, wide));
        for model in models.iter().take(6) {
            lines.push(crate::ui::model_row(model, name_width, wide, false));
        }
        lines.push(crate::ui::cost_rollup(&models));
    } else if day.is_some() {
        lines.push(Line::from(Span::styled(
            "per-model detail is kept ~35 days — totals only",
            crate::ui::style(FAINT),
        )));
    }

    frame.render_widget(Paragraph::new(lines), rect);
    let _ = ramp; // shared palette helper reserved for the hover halo pass
}

/// The next/previous calendar day key — the drill's ←→ stepping.
pub fn neighbor_day(day_key: &str, step: i64) -> Option<String> {
    let date = Date::parse(day_key, DAY_KEY).ok()?;
    let moved = date.checked_add(time::Duration::days(step))?;
    moved.format(DAY_KEY).ok()
}

/// Landscape opens a surface beside the dashboard when the split leaves
/// both regions viable; anything narrower pushes (design §3).
pub fn split_viable(area: Rect) -> bool {
    area.width >= 84 && crate::layout::shape(area) == crate::layout::Shape::Landscape
}

pub fn meter_index_matching(meters: &[LiveMeter], digit: char) -> Option<usize> {
    let index = (digit as usize).checked_sub('1' as usize)?;
    (index < meters.len()).then_some(index)
}
