import AppKit
import UsageCore

/// Pure state → NSAttributedString for the status button's attributedTitle.
///
/// Colors are FIXED and bright, not dynamic: over a tinted wallpaper the
/// menu bar reports a "light" effective appearance while looking dark, so
/// every dynamic-color strategy (custom image, dynamic labelColor in the
/// title) resolved illegibly dark. Bright fixed colors plus a faint dark
/// shadow read on dark and tinted bars alike.
///
/// Format: `✳︎ S15·W19·F25%` — a dim single-letter tag identifies each stat,
/// the number carries the severity color (white / orange / red).
enum StatusItemRenderer {
    struct Model: Equatable {
        let segments: [MenuBarSegment]?
        let stale: Bool
    }

    static func model(for state: DisplayState) -> Model {
        guard let snapshot = state.snapshot else {
            return Model(segments: nil, stale: true)
        }
        return Model(
            segments: UsageFormatting.menuBarSegments(from: snapshot.meters),
            stale: state.isStale
        )
    }

    /// Anthropic terracotta (#D97757) — the app's identity mark.
    static let claudeOrange = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)

    private static let bright = NSColor.white
    private static let dim = NSColor.white.withAlphaComponent(0.55)
    private static let staleColor = NSColor.white.withAlphaComponent(0.45)
    private static let warningColor = NSColor(srgbRed: 1.0, green: 0.624, blue: 0.039, alpha: 1)
    private static let criticalColor = NSColor(srgbRed: 1.0, green: 0.271, blue: 0.227, alpha: 1)

    static func attributedText(for model: Model) -> NSAttributedString {
        // Monospaced digits so the width doesn't jitter every refresh (§8).
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = .zero

        let result = NSMutableAttributedString()
        func append(_ string: String, _ color: NSColor) {
            result.append(NSAttributedString(string: string, attributes: [
                .font: font,
                .foregroundColor: color,
                .shadow: shadow,
            ]))
        }

        append("✳︎ ", model.stale ? staleColor : claudeOrange)

        guard let segments = model.segments, !segments.isEmpty else {
            append("—", dim)
            return result
        }

        for (index, segment) in segments.enumerated() {
            if index > 0 { append("·", model.stale ? staleColor : dim) }
            append(segment.tag, model.stale ? staleColor : dim)
            if let percent = segment.percent {
                append("\(percent)", model.stale ? staleColor : numberColor(segment.level))
            } else {
                append("–", model.stale ? staleColor : dim)
            }
        }
        append("%", model.stale ? staleColor : dim)
        return result
    }

    private static func numberColor(_ level: DisplayLevel) -> NSColor {
        switch level {
        case .normal: bright
        case .warning: warningColor
        case .critical: criticalColor
        }
    }
}
