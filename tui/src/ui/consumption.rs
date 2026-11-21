//! The consumption sections' renderers — TODAY and MODELS (one account's
//! flat rows, or the All agents outline: agent rows, their models
//! indented). A child of `ui`, so it shares the dashboard's helpers.

use super::*;

pub(super) fn today<'a>(
    digest: &'a LiveState,
    all: Option<&AllAgentsState>,
    accent: Color,
    rect: Rect,
) -> Paragraph<'a> {
    let activity = match all {
        Some(all) => match &all.activity {
            Some(activity) => activity,
            // Every member still scanning: there is no total to show, and
            // zeros would read as one.
            None => {
                return Paragraph::new(vec![
                    section_title(&format!(
                        "TODAY{sep}{}{sep}scanning{}",
                        all.count_label,
                        glyphs().ellipsis,
                        sep = glyphs().sep
                    )),
                    Line::from(Span::styled("no total until a scan lands", style(FAINT))),
                ]);
            }
        },
        None => &digest.activity,
    };
    let mut lines = vec![section_title(&today_title(
        activity.today_tokens,
        activity.today_cost,
        activity.today_prompts,
        all.map(|all| all.count_label.as_str()),
        rect.width as usize,
    ))];
    // Agents share the spark: no one vendor's accent owns it.
    let accent = if all.is_some_and(crate::state::spans_agents) {
        rgb(NEUTRAL)
    } else {
        accent
    };

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
        format!(
            "{:<width$}12{:>width$}",
            "0",
            "23",
            width = cell_width * 12 - 1
        ),
        style(FAINT),
    )));
    Paragraph::new(lines)
}

/// "TODAY · 3 agents · 2.1B tok · $815 · 696 prompts", fitted to the
/// section: the prompt count gives way first, then the agent count (MODELS
/// and the ACTIVITY readout still name the scope). Tokens and cost never
/// do — they are the reading.
fn today_title(
    tokens: i64,
    cost: Option<f64>,
    prompts: i64,
    count_label: Option<&str>,
    width: usize,
) -> String {
    let sep = glyphs().sep;
    let figures = format!(
        "{} tok{}",
        compact(tokens),
        cost.map(|c| format!("{sep}{}", money(c)))
            .unwrap_or_default()
    );
    let prompts = format!("{sep}{prompts} prompts");
    let label = count_label.map(|l| format!("{sep}{l}")).unwrap_or_default();
    let candidates = [
        format!("TODAY{label}{sep}{figures}{prompts}"),
        format!("TODAY{label}{sep}{figures}"),
        format!("TODAY{sep}{figures}"),
    ];
    candidates
        .iter()
        .find(|title| title.chars().count() <= width)
        .unwrap_or(&candidates[2])
        .clone()
}

/// The MODELS section: the app's breakdown grid, terminal-fitted. Rows
/// follow the active period (not just today), and where the pane affords
/// it they carry the same four columns the app separates — fresh input
/// apart from the cache re-reads an agentic loop dwarfs it with.
pub(super) fn models<'a>(
    app: &App,
    data: &'a Dash,
    shown: &[usize],
    hidden: usize,
    rect: Rect,
) -> Paragraph<'a> {
    let wide = rect.width >= 46;
    let name_width = (rect.width as usize)
        .saturating_sub(if wide { 36 } else { 20 })
        .clamp(8, 22);
    let mut lines = vec![models_title(app, data, name_width, wide, rect.width)];

    if data.rows.is_empty() {
        lines.push(Line::from(Span::styled(
            format!("no usage in this {}", app.period.label()),
            style(FAINT),
        )));
        return Paragraph::new(lines);
    }
    // Model rows sit one step in under their agent; a pane too narrow to
    // spare two cells spares one.
    let indent = if !data.outlined {
        0
    } else if rect.width < 30 {
        1
    } else {
        2
    };
    let filter = data.filter(app);
    for &index in shown {
        let row = &data.rows[index];
        let dim = filter
            .as_ref()
            .is_some_and(|filter| !row.keys.iter().any(|key| filter.covers(key)));
        lines.push(match &row.kind {
            Kind::Agent { .. } => agent_row(row, name_width, wide, dim),
            Kind::Model(_) => model_row_at(&row.total, name_width, wide, dim, indent),
        });
    }
    // No total yet (every agent still scanning): no rollup to price.
    let no_total = app
        .digest
        .as_ref()
        .is_some_and(|digest| app.no_total_yet(digest));
    lines.push(if no_total {
        Line::from(Span::styled("no total until a scan lands", style(FAINT)))
    } else {
        cost_rollup_hiding(&data.models, hidden)
    });
    Paragraph::new(lines)
}

/// An agent's mark: its glyph, or — in the ASCII alphabet, where a data
/// glyph may not render — its short name's first letter.
fn glyph_or<'a>(glyph: &'a str, short_name: &'a str) -> String {
    if glyph.is_empty() || crate::state::look().ascii {
        short_name
            .chars()
            .next()
            .map(String::from)
            .unwrap_or_default()
    } else {
        glyph.to_owned()
    }
}

/// An outline's agent row: its mark in its accent, its name, and the sum of
/// its models' columns — or, for an agent the total leaves out, why.
fn agent_row(row: &outline::Row, name_width: usize, wide: bool, dim: bool) -> Line<'static> {
    let Kind::Agent {
        glyph,
        short_name,
        accent,
        note,
        ..
    } = &row.kind
    else {
        return Line::default();
    };
    let (total, accent, note) = (&row.total, *accent, *note);
    let mark = glyph_or(glyph, short_name);
    // An agent the total leaves out reads quieter than one it counts.
    let dim = dim || note.is_some();
    let name_style = if dim {
        style(DIM)
    } else {
        Style::new().add_modifier(Modifier::BOLD)
    };
    let mut spans = vec![
        Span::styled(
            format!("{mark} "),
            style(if dim { ramp(accent, 0.45) } else { rgb(accent) }),
        ),
        Span::styled(
            // The short name ("Agent") reads better than a clipped full one
            // ("Agent Na…") where the whole name won't fit.
            format!(
                "{:<name_width$}",
                truncate(
                    if total.display_name.chars().count() > name_width {
                        short_name
                    } else {
                        &total.display_name
                    },
                    name_width
                )
            ),
            name_style,
        ),
    ];
    if let Some(note) = note {
        let text = match note {
            Note::Scanning => format!("scanning{}", glyphs().ellipsis),
            Note::NotCounted => "not in the totals".to_owned(),
        };
        let room = if wide { 34 } else { 18 };
        spans.push(Span::styled(format!("{text:>room$}"), style(FAINT)));
        return Line::from(spans);
    }
    spans.extend(row_figures(total, wide, dim, name_style));
    Line::from(spans)
}

/// One breakdown row: the model's dot and name, then either the four
/// token classes the app separates or a single total, and its cost — "—"
/// when unpriced, never $0. `dim` is the legend-filter treatment.
pub fn model_row(model: &ModelTotal, name_width: usize, wide: bool, dim: bool) -> Line<'static> {
    model_row_at(model, name_width, wide, dim, 0)
}

/// `model_row`, `indent` cells in — an outline's model under its agent. The
/// name column gives up the cells, so the figures stay in their columns.
pub fn model_row_at(
    model: &ModelTotal,
    name_width: usize,
    wide: bool,
    dim: bool,
    indent: usize,
) -> Line<'static> {
    let name_width = name_width.saturating_sub(indent).max(4);
    let name_style = if dim { style(DIM) } else { Style::new() };
    let mut spans = vec![
        Span::raw(" ".repeat(indent)),
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
            name_style,
        ),
    ];
    spans.extend(row_figures(model, wide, dim, name_style));
    Line::from(spans)
}

/// A breakdown row's columns: the token classes (or one total) and the
/// cost, "—" when unpriced — never $0.
fn row_figures(model: &ModelTotal, wide: bool, dim: bool, cost_style: Style) -> Vec<Span<'static>> {
    let mut spans = Vec::new();
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
        if dim { style(DIM) } else { cost_style },
    ));
    spans
}

/// The breakdown table's column labels, for surfaces that seat them on
/// their own row rather than folding them into a section title.
pub fn model_columns(name_width: usize, wide: bool) -> Line<'static> {
    let labels = if wide {
        format!(
            "{:>8}{:>8}{:>8}{:>10}",
            "input", "cached", "output", "est. cost"
        )
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
fn models_title(
    app: &App,
    data: &Dash,
    name_width: usize,
    wide: bool,
    width: u16,
) -> Line<'static> {
    let titled = |head: &str| {
        let mut title = format!("{head}{}{}", glyphs().sep, app.period.label());
        if data.models_truncated {
            // No silent caps: per-model rows exist for ~35 days only.
            title.push_str(&format!("{}last ~35d", glyphs().sep));
        }
        title
    };
    // The outline names its scope: "ALL AGENTS" where the column labels
    // still seat beside it, else "AGENTS" — as long as "MODELS", so the
    // labels come and go exactly as they do for one account.
    let head_room = 2 + name_width;
    let title = if !data.outlined {
        titled("MODELS")
    } else if titled("ALL AGENTS").chars().count() < head_room || !wide {
        titled("ALL AGENTS")
    } else {
        titled("AGENTS")
    };
    let labels = if wide {
        format!(
            "{:>8}{:>8}{:>8}{:>10}",
            "input", "cached", "output", "est. cost"
        )
    } else {
        String::new()
    };
    // Labels ride the title line only when they fit over their own
    // columns without crowding the title.
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
    cost_rollup_hiding(rows, rows.len().saturating_sub(shown))
}

/// `cost_rollup` with the count of rows left unseated given directly — an
/// outline seats rows, not a prefix of the models.
pub fn cost_rollup_hiding(rows: &[ModelTotal], hidden: usize) -> Line<'static> {
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
    if hidden > 0 {
        text.push_str(&format!("{}+{hidden} more", glyphs().sep));
    }
    Line::from(Span::styled(text, style(FAINT)))
}
