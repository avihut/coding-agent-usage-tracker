//! `usage-tui --status`: one tmux-format line from the digest's menu bar
//! segments — drop it into `status-right` and the meters ride tmux's own
//! chrome. Prints nothing but the line; exit 0 even when the engine is
//! offline (a status bar must never flash an error).

use crate::digest::{LiveState, Rgb};
use crate::state::look;
use std::path::Path;

fn hex(color: Rgb) -> String {
    format!(
        "#{:02x}{:02x}{:02x}",
        (color.red * 255.0).round() as u8,
        (color.green * 255.0).round() as u8,
        (color.blue * 255.0).round() as u8
    )
}

/// Risk markers when color can't carry it (NO_COLOR): `!` from halfway
/// severity, `!!` at red verdicts (design §5's monochrome dialect).
fn marker(severity: Option<f64>, level: &str) -> &'static str {
    match (severity, level) {
        (_, "critical") => "!!",
        (Some(s), _) if s >= 0.75 => "!!",
        (Some(s), _) if s >= 0.35 => "!",
        (_, "warning") => "!",
        _ => "",
    }
}

pub fn render(digest_path: &Path) -> String {
    let Ok(bytes) = std::fs::read(digest_path) else {
        return "usage: engine offline".into();
    };
    let Ok(state) = LiveState::parse(&bytes) else {
        return "usage: digest unreadable".into();
    };
    let color = !look().no_color;
    let mut out = String::new();
    // One block per SHOWN harness, each led by its own mark in its own
    // colour (0.101.0) — the same reading as the app's bar. A writer that
    // meters one publishes no roster, and then this is exactly the line it
    // always was: the top level's mark and its own segments.
    let blocks = blocks(&state);
    for (index, block) in blocks.iter().enumerate() {
        if index > 0 {
            out.push_str("  ");
        }
        if color {
            out.push_str(&format!("#[fg={}]", hex(block.accent)));
            out.push_str(&block.glyph);
            out.push_str("#[default] ");
        } else {
            // No colour to tell vendors apart, so the name does it.
            out.push_str(&block.short_name);
            out.push(' ');
        }
        for (index, segment) in block.segments.iter().enumerate() {
            if index > 0 {
                out.push('·');
            }
            out.push_str(&segment.tag);
            let text = segment
                .percent
                .map(|p| p.to_string())
                .unwrap_or_else(|| "—".into());
            if color {
                let paint = segment.risk.map(hex).or(match segment.level.as_str() {
                    "warning" => Some("#ff9f0a".into()),
                    "critical" => Some("#ff453a".into()),
                    _ => None,
                });
                match paint {
                    Some(paint) => out.push_str(&format!("#[fg={paint}]{text}#[default]")),
                    None => out.push_str(&text),
                }
            } else {
                out.push_str(&text);
                out.push_str(marker(segment.severity, &segment.level));
            }
        }
    }
    if state.engine.stale {
        out.push_str(if color {
            " #[dim]stale#[default]"
        } else {
            " stale"
        });
    }
    // Pending notices: one dot cell and the count, only while the digest's
    // indicator is lit (a lone ongoing outage lights nothing here either).
    if let Some(card) = state.notices.as_ref().filter(|card| card.indicator) {
        let dot = if look().ascii { "*" } else { "●" };
        let count = card
            .items
            .iter()
            .filter(|item| !item.owns_menu_bar_surface)
            .count();
        out.push_str(&format!(" {dot}{count}"));
    }
    out
}

/// One harness's piece of the line: its mark, its colour, the name a
/// colourless terminal prints instead, and its accounts' segments in bar
/// order.
struct Block {
    glyph: String,
    short_name: String,
    accent: Rgb,
    segments: Vec<crate::digest::SegmentStatus>,
}

/// The shown harnesses and their cells. A writer before harnesses (or one
/// that publishes no cells) gives exactly one block — the top level's — so
/// a one-harness line is unchanged.
fn blocks(state: &LiveState) -> Vec<Block> {
    let single = || {
        vec![Block {
            glyph: state.engine.glyph.clone(),
            short_name: state.engine.service_name.clone(),
            accent: state.engine.accent,
            segments: state.menu_bar.clone(),
        }]
    };
    let (Some(harnesses), Some(cells)) = (state.harnesses.as_ref(), state.menu_bar_cells.as_ref())
    else {
        return single();
    };
    let mut blocks: Vec<Block> = Vec::new();
    for harness in harnesses.iter().filter(|harness| harness.shown) {
        let segments: Vec<_> = cells
            .iter()
            .filter(|cell| cell.provider_id == harness.id)
            .flat_map(|cell| cell.segments.clone())
            .collect();
        if segments.is_empty() {
            continue;
        }
        blocks.push(Block {
            glyph: harness.glyph.clone(),
            short_name: harness.short_name.clone(),
            accent: harness.accent,
            segments,
        });
    }
    if blocks.is_empty() {
        return single();
    }
    blocks
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The line spans harnesses (0.101.0), and a writer that meters one
    /// still produces exactly the line it always did.
    #[test]
    fn blocks_span_shown_harnesses() {
        let bytes = std::fs::read(
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../Tests/UsageCoreTests/Fixtures/digest/live-state-v1-harnesses.json"),
        )
        .expect("harness golden");
        let state = LiveState::parse(&bytes).expect("decodes");
        let spanning = blocks(&state);
        assert!(spanning.len() >= 2, "the golden's bar spans harnesses");
        assert!(spanning.iter().all(|block| !block.segments.is_empty()));
        // A hidden harness contributes no block — hiding is display, and
        // this line is display.
        let hidden: Vec<_> = state
            .harnesses
            .as_ref()
            .expect("roster")
            .iter()
            .filter(|harness| !harness.shown)
            .map(|harness| harness.glyph.clone())
            .collect();
        for glyph in hidden {
            assert!(spanning.iter().all(|block| block.glyph != glyph));
        }

        let one = std::fs::read(
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../Tests/UsageCoreTests/Fixtures/digest/live-state-v1.json"),
        )
        .expect("golden");
        let one = LiveState::parse(&one).expect("decodes");
        let single = blocks(&one);
        assert_eq!(single.len(), 1);
        assert_eq!(single[0].glyph, one.engine.glyph);
        assert_eq!(single[0].segments.len(), one.menu_bar.len());
    }

    #[test]
    fn markers_speak_risk_without_color() {
        assert_eq!(marker(Some(0.9), "normal"), "!!");
        assert_eq!(marker(Some(0.5), "normal"), "!");
        assert_eq!(marker(None, "critical"), "!!");
        assert_eq!(marker(None, "warning"), "!");
        assert_eq!(marker(Some(0.1), "normal"), "");
        assert_eq!(marker(None, "normal"), "");
    }
}
