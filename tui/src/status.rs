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
    if color {
        out.push_str(&format!("#[fg={}]", hex(state.engine.accent)));
        out.push_str(&state.engine.glyph);
        out.push_str("#[default] ");
    } else {
        out.push_str(&state.engine.glyph);
        out.push(' ');
    }
    for (index, segment) in state.menu_bar.iter().enumerate() {
        if index > 0 {
            out.push_str("·");
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
    if state.engine.stale {
        out.push_str(if color { " #[dim]stale#[default]" } else { " stale" });
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

#[cfg(test)]
mod tests {
    use super::*;

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
