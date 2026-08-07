import AppKit
import UsageCore

/// Pure state → NSImage. No networking, no store access — independently
/// verifiable. The image uses dynamic system colors in a drawing-handler
/// image, so it must be drawn inside the status button's appearance context
/// (see StatusItemController) for them to resolve against the menu bar.
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

    static func image(for model: Model) -> NSImage {
        let text = attributedText(for: model)
        let textSize = text.size()
        // Height from the actual status bar, never hardcoded (spec §8).
        let size = NSSize(width: ceil(textSize.width), height: NSStatusBar.system.thickness)
        // Drawing-handler images re-execute per draw, so the dynamic system
        // colors below resolve against the menu bar's current appearance.
        return NSImage(size: size, flipped: false) { rect in
            text.draw(at: NSPoint(x: 0, y: (rect.height - textSize.height) / 2))
            return true
        }
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
