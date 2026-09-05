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
        /// The provider's mark ahead of the digits.
        let glyph: String
        /// The service's own health, when an incident is running: the glyph
        /// then rides a capsule in this color instead of standing alone.
        /// Nil whenever the service is fine, unknown, or under maintenance —
        /// the menu bar alarms for incidents only (decision D2).
        var incident: ServiceStatusCard.Indicator?
        /// A pending notice with no menu bar surface of its own: a white
        /// dot at the glyph's corner, no count (the panel counts). An
        /// active outage alone lights nothing — the capsule already says
        /// it — and the digest decides that (`NoticesCard.indicator`), so
        /// the TUI's header dot and this one can't disagree.
        var indicator = false
    }

    static func model(
        for state: DisplayState, predictions: [String: UsagePrediction] = [:],
        glyph: String = "✳︎", serviceStatus: ServiceStatusCard? = nil,
        notices: NoticesCard? = nil
    ) -> Model {
        // Which impacts are loud enough to badge is decision D2, and it lives
        // on the card so the TUI's rungs and this badge can't drift apart.
        let alarming = serviceStatus?.alarmingImpact
        let indicator = notices?.indicator ?? false
        guard let snapshot = state.snapshot else {
            return Model(
                segments: nil, stale: true, glyph: glyph, incident: alarming,
                indicator: indicator)
        }
        return Model(
            segments: UsageFormatting.menuBarSegments(
                from: snapshot.meters, predictions: predictions),
            stale: state.isStale,
            glyph: glyph,
            incident: alarming,
            indicator: indicator
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

    /// The active provider's brand accent (Anthropic terracotta #D97757
    /// while Claude is metered) — tints the glyph; charts derive from it.
    static var accent: NSColor { ProviderStyle.accent }

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
        /// The provider glyph on an incident-colored capsule, drawn white —
        /// same geometry as `badge`, its own fill, and the glyph's font so
        /// the mark keeps its shape (surface S3).
        case glyphBadge(String, NSColor)
        /// The pending-notice dot over the run drawn just before it: white,
        /// at the glyph's top-right, knocked out of whatever sits under it
        /// by a clear ring so it separates from the ✳︎ strokes and from a
        /// capsule fill alike. Zero width — it rides the previous run.
        case indicator
    }

    /// Incident fills, a step deeper than the ramp's colors for the same
    /// reason `badgeRed` is: white sits on these at real contrast, where
    /// white on a bright system yellow would be unreadable.
    private static func incidentFill(_ indicator: ServiceStatusCard.Indicator) -> NSColor {
        switch indicator {
        case .critical: NSColor(srgbRed: 0.85, green: 0.16, blue: 0.14, alpha: 1)
        case .major: NSColor(srgbRed: 0.90, green: 0.49, blue: 0.05, alpha: 1)
        default: NSColor(srgbRed: 0.78, green: 0.58, blue: 0.02, alpha: 1)
        }
    }

    // Computed, not stored: NSFont isn't Sendable, and a stored static on a
    // non-isolated type trips strict concurrency.
    private static var font: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .semibold) }
    private static var badgeFont: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .bold) }
    private static let dotDiameter: CGFloat = 5
    private static let dotGap: CGFloat = 2
    private static let badgePaddingX: CGFloat = 3.5
    private static let badgeHeight: CGFloat = 15
    private static let indicatorDiameter: CGFloat = 6
    private static let indicatorRing: CGFloat = 1.5

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
            // The run the indicator hugs: its right edge and top.
            var previousRun: (x: CGFloat, width: CGFloat, top: CGFloat)?
            for run in runs {
                switch run {
                case .indicator:
                    guard let previousRun else { break }
                    // Hug the glyph's top-right: the dot's center sits on
                    // the run's corner, pulled a hair inward so the ring
                    // never clips at the image's own top edge.
                    let center = NSPoint(
                        x: previousRun.x + previousRun.width - indicatorDiameter / 2 + 0.5,
                        y: min(previousRun.top, height - indicatorDiameter / 2 - indicatorRing)
                            - indicatorDiameter / 4)
                    let ring = NSRect(
                        x: center.x - indicatorDiameter / 2 - indicatorRing,
                        y: center.y - indicatorDiameter / 2 - indicatorRing,
                        width: indicatorDiameter + 2 * indicatorRing,
                        height: indicatorDiameter + 2 * indicatorRing)
                    NSGraphicsContext.current?.saveGraphicsState()
                    NSGraphicsContext.current?.compositingOperation = .destinationOut
                    NSColor.black.setFill()
                    NSBezierPath(ovalIn: ring).fill()
                    NSGraphicsContext.current?.restoreGraphicsState()
                    NSColor.white.setFill()
                    NSBezierPath(ovalIn: ring.insetBy(dx: indicatorRing, dy: indicatorRing)).fill()
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
                case .glyphBadge(let string, let fill):
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: font, .foregroundColor: NSColor.white,
                    ]
                    let size = (string as NSString).size(withAttributes: attributes)
                    let rect = NSRect(
                        x: x, y: (height - badgeHeight) / 2,
                        width: size.width + 2 * badgePaddingX, height: badgeHeight)
                    NSGraphicsContext.current?.saveGraphicsState()
                    shadow.set()
                    fill.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2)
                        .fill()
                    NSGraphicsContext.current?.restoreGraphicsState()
                    (string as NSString).draw(
                        at: NSPoint(x: x + badgePaddingX, y: (height - size.height) / 2),
                        withAttributes: attributes)
                }
                if case .indicator = run { continue }
                previousRun = (x, inkWidth(run), inkTop(run, height: height))
                x += runWidth(run)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func compose(_ model: Model) -> [Run] {
        // An incident dresses the provider's own mark — the agent indicator
        // itself goes colored, which is what makes it readable at a glance
        // without stealing the digits' meaning. Staleness never suppresses
        // it: a stale usage number says nothing about the service's health.
        var runs: [Run] = model.incident.map {
            [.glyphBadge(model.glyph, incidentFill($0))]
        } ?? [.text(model.glyph, model.stale ? staleColor : accent, font)]
        // The dot rides the glyph (or its capsule) — declared right after
        // the run it hugs, before the spacer, so it never adds width.
        if model.indicator { runs.append(.indicator) }
        runs.append(.text(" ", dim, font))
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

    /// The run's visible ink (a text run's trailing space excluded) — what
    /// the indicator dot hugs.
    private static func inkWidth(_ run: Run) -> CGFloat {
        if case .text(let string, _, let font) = run {
            return (string.trimmingCharacters(in: .whitespaces) as NSString)
                .size(withAttributes: [.font: font]).width
        }
        return runWidth(run)
    }

    /// The run's top edge in image coordinates.
    private static func inkTop(_ run: Run, height: CGFloat) -> CGFloat {
        switch run {
        case .text(let string, _, let font):
            return (height + (string as NSString).size(withAttributes: [.font: font]).height) / 2
        case .badge, .glyphBadge:
            return (height + badgeHeight) / 2
        case .dot, .indicator:
            return height
        }
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
        case .glyphBadge(let string, _):
            let text = (string as NSString).size(withAttributes: [.font: font]).width
            return text + 2 * badgePaddingX
        case .indicator:
            return 0
        }
    }
}
