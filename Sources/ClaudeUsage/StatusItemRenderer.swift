import AppKit
import UsageCore

/// Pure state → NSImage for the status button.
///
/// Colors are FIXED and bright, not dynamic: over a tinted wallpaper the
/// menu bar reports a "light" effective appearance while looking dark, so
/// every dynamic-color strategy (custom template, dynamic labelColor)
/// resolved illegibly dark. The image is literal pixels (isTemplate =
/// false) — bright fixed colors plus a faint dark shadow read on dark and
/// tinted bars alike.
///
/// Format: `✳︎ S15·W19·F25%`. Digits stay white — thin glyph strokes can't
/// carry color legibly over Liquid Glass (HIG: keep fine features neutral,
/// let fills carry color) — so exhaustion risk arrives as solid geometry:
/// a ramp-colored dot ahead of a number under watch, escalating to a
/// filled capsule carrying the segment's tag and digits in bold white
/// once the forecast firmly spends the limit.
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

    /// How a segment's number wears its risk.
    enum Ornament: Equatable {
        case plain(NSColor)
        case dot(NSColor)
        case badge
    }

    /// The ramp's final quarter (projection ≥ ~96% at reset, or exhaustion
    /// predicted outright) escalates the dot to the badge.
    static let badgeSeverity = 0.75

    /// Anthropic terracotta (#D97757) — the app's identity mark.
    static let claudeOrange = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)

    private static let bright = NSColor.white
    private static let dim = NSColor.white.withAlphaComponent(0.55)
    private static let staleColor = NSColor.white.withAlphaComponent(0.45)
    private static let warningColor = NSColor(srgbRed: 1.0, green: 0.624, blue: 0.039, alpha: 1)
    /// Dots are solid fills, so unlike digit strokes they can afford a
    /// deep red; the ramp blends from yellow toward this.
    private static let criticalColor = NSColor(srgbRed: 1.0, green: 0.271, blue: 0.227, alpha: 1)
    private static let riskYellow = NSColor(srgbRed: 1.0, green: 0.839, blue: 0.039, alpha: 1)
    /// The badge's fill — a step deeper than the ramp's red so bold white
    /// digits sit on it at real contrast (Apple-badge convention).
    private static let badgeRed = NSColor(srgbRed: 0.92, green: 0.216, blue: 0.18, alpha: 1)

    /// Exhaustion risk decides the dressing; with no prediction, the
    /// discrete percent-threshold levels stand in. Stale data never
    /// alarms — it's grey and quiet like the rest of the stale title.
    static func ornament(for segment: MenuBarSegment, stale: Bool) -> Ornament {
        if stale { return .plain(staleColor) }
        if let severity = segment.severity {
            guard severity > 0 else { return .plain(bright) }
            if severity >= badgeSeverity { return .badge }
            return .dot(riskYellow.blended(withFraction: severity, of: criticalColor) ?? criticalColor)
        }
        switch segment.level {
        case .normal: return .plain(bright)
        case .warning: return .dot(warningColor)
        case .critical: return .badge
        }
    }

    // MARK: - Drawing

    private enum Run {
        case text(String, NSColor, NSFont)
        case dot(NSColor)
        case badge(String)
    }

    // Computed, not stored: NSFont isn't Sendable, and a stored static on a
    // non-isolated type trips strict concurrency.
    private static var font: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .semibold) }
    private static var badgeFont: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .bold) }
    private static let dotDiameter: CGFloat = 5
    private static let dotGap: CGFloat = 2
    private static let badgePaddingX: CGFloat = 3.5
    private static let badgeHeight: CGFloat = 15

    static func image(for model: Model, height: CGFloat) -> NSImage {
        let runs = compose(model)
        let width = runs.reduce(0) { $0 + runWidth($1) }
        let image = NSImage(
            size: NSSize(width: ceil(width), height: height), flipped: false
        ) { _ in
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 1.5
            shadow.shadowOffset = .zero

            var x: CGFloat = 0
            for run in runs {
                switch run {
                case .text(let string, let color, let font):
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: font, .foregroundColor: color, .shadow: shadow,
                    ]
                    let size = (string as NSString).size(withAttributes: attributes)
                    (string as NSString).draw(
                        at: NSPoint(x: x, y: (height - size.height) / 2),
                        withAttributes: attributes)
                case .dot(let color):
                    NSGraphicsContext.current?.saveGraphicsState()
                    shadow.set()
                    color.setFill()
                    NSBezierPath(ovalIn: NSRect(
                        x: x + dotGap, y: (height - dotDiameter) / 2,
                        width: dotDiameter, height: dotDiameter)).fill()
                    NSGraphicsContext.current?.restoreGraphicsState()
                case .badge(let string):
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: badgeFont, .foregroundColor: NSColor.white,
                    ]
                    let size = (string as NSString).size(withAttributes: attributes)
                    let rect = NSRect(
                        x: x, y: (height - badgeHeight) / 2,
                        width: size.width + 2 * badgePaddingX, height: badgeHeight)
                    NSGraphicsContext.current?.saveGraphicsState()
                    shadow.set()
                    badgeRed.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2)
                        .fill()
                    NSGraphicsContext.current?.restoreGraphicsState()
                    (string as NSString).draw(
                        at: NSPoint(x: x + badgePaddingX, y: (height - size.height) / 2),
                        withAttributes: attributes)
                }
                x += runWidth(run)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func compose(_ model: Model) -> [Run] {
        var runs: [Run] = [.text("✳︎ ", model.stale ? staleColor : claudeOrange, font)]
        guard let segments = model.segments, !segments.isEmpty else {
            runs.append(.text("—", dim, font))
            return runs
        }
        let quiet = model.stale ? staleColor : dim
        for (index, segment) in segments.enumerated() {
            if index > 0 { runs.append(.text("·", quiet, font)) }
            guard let percent = segment.percent else {
                runs.append(.text(segment.tag, quiet, font))
                runs.append(.text("–", quiet, font))
                continue
            }
            switch ornament(for: segment, stale: model.stale) {
            case .plain(let color):
                runs.append(.text(segment.tag, quiet, font))
                runs.append(.text("\(percent)", color, font))
            case .dot(let color):
                runs.append(.text(segment.tag, quiet, font))
                runs.append(.dot(color))
                runs.append(.text("\(percent)", bright, font))
            case .badge:
                // Tag and number share the pill — the alarm names its
                // limit instead of leaving a dim orphan letter beside it.
                runs.append(.badge("\(segment.tag)\(percent)"))
            }
        }
        runs.append(.text("%", quiet, font))
        return runs
    }

    private static func runWidth(_ run: Run) -> CGFloat {
        switch run {
        case .text(let string, _, let font):
            return (string as NSString).size(withAttributes: [.font: font]).width
        case .dot:
            return dotDiameter + 2 * dotGap
        case .badge(let string):
            let text = (string as NSString).size(withAttributes: [.font: badgeFont]).width
            return text + 2 * badgePaddingX
        }
    }
}
