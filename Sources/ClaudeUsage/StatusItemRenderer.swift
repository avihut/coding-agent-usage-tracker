import AppKit
import UsageCore

/// Pure state → NSAttributedString for the status button's attributedTitle.
/// The button draws the title itself inside its own appearance and vibrancy
/// context — the same pipeline system menu bar items use — so the dynamic
/// colors resolve against the actual menu bar (wallpaper tinting included)
/// at every draw. A custom NSImage lost that: status buttons rasterize
/// non-template images outside the appearance pass, which produced
/// dark-on-dark text, and non-template images get no vibrancy treatment.
enum StatusItemRenderer {
    struct Model: Equatable {
        let segments: [MenuBarSegment]?
        let worstLevel: DisplayLevel
        let stale: Bool
    }

    static func model(for state: DisplayState) -> Model {
        guard let snapshot = state.snapshot else {
            return Model(segments: nil, worstLevel: .normal, stale: true)
        }
        return Model(
            segments: UsageFormatting.menuBarSegments(from: snapshot.meters),
            worstLevel: snapshot.summary.worstLevel,
            stale: state.isStale
        )
    }

    static func attributedText(for model: Model) -> NSAttributedString {
        // Monospaced digits so the width doesn't jitter every refresh (§8).
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let result = NSMutableAttributedString()

        func append(_ string: String, _ color: NSColor) {
            result.append(NSAttributedString(
                string: string, attributes: [.font: font, .foregroundColor: color]))
        }

        append("✳︎ ", model.stale ? .secondaryLabelColor : color(for: model.worstLevel))

        guard let segments = model.segments, !segments.isEmpty else {
            append("—", .secondaryLabelColor)
            return result
        }

        for (index, segment) in segments.enumerated() {
            if index > 0 { append("·", .tertiaryLabelColor) }
            if let percent = segment.percent {
                append("\(percent)", model.stale ? .secondaryLabelColor : color(for: segment.level))
            } else {
                append("–", .tertiaryLabelColor)
            }
        }
        append("%", .secondaryLabelColor)
        return result
    }

    static func color(for level: DisplayLevel) -> NSColor {
        switch level {
        case .normal: .labelColor
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }
}
