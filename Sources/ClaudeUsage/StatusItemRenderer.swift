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

    static func model(
        for state: DisplayState, predictions: [String: UsagePrediction] = [:]
    ) -> Model {
        guard let snapshot = state.snapshot else {
            return Model(segments: nil, stale: true)
        }
        return Model(
            segments: UsageFormatting.menuBarSegments(
                from: snapshot.meters, predictions: predictions),
            stale: state.isStale
        )
    }

    /// Anthropic terracotta (#D97757) — the app's identity mark.
    static let claudeOrange = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)

    private static let bright = NSColor.white
    private static let dim = NSColor.white.withAlphaComponent(0.55)
    private static let staleColor = NSColor.white.withAlphaComponent(0.45)
    private static let warningColor = NSColor(srgbRed: 1.0, green: 0.624, blue: 0.039, alpha: 1)
    /// Text-legibility red, not UI-element red: system red (#FF453A) is
    /// tuned for filled shapes and sinks illegibly into dark tinted bars
    /// at 12pt — this one keeps the hue but lifts luminance enough for
    /// tiny semibold digits to read.
    private static let criticalColor = NSColor(srgbRed: 1.0, green: 0.42, blue: 0.36, alpha: 1)
    /// The bright end of the exhaustion-risk ramp; severity blends it
    /// toward `criticalColor`, so warning shades never hard-cut to red.
    private static let riskYellow = NSColor(srgbRed: 1.0, green: 0.839, blue: 0.039, alpha: 1)

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
                append("\(percent)", model.stale ? staleColor : numberColor(segment))
            } else {
                append("–", model.stale ? staleColor : dim)
            }
        }
        append("%", model.stale ? staleColor : dim)
        return result
    }

    /// Exhaustion risk first: with a prediction the number rides the
    /// yellow→red ramp (regular white while the forecast is clean). The
    /// discrete percent-threshold palette covers meters without one.
    private static func numberColor(_ segment: MenuBarSegment) -> NSColor {
        if let severity = segment.severity {
            guard severity > 0 else { return bright }
            return riskYellow.blended(withFraction: severity, of: criticalColor) ?? criticalColor
        }
        switch segment.level {
        case .normal: return bright
        case .warning: return warningColor
        case .critical: return criticalColor
        }
    }
}
