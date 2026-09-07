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
///
/// Several accounts (0.96.0, decision D5): the item is a row of CELLS under
/// ONE provider glyph — the glyph keeps every provider-level fact (the
/// incident capsule, the pending-notice dot). Each cell draws in its
/// account's own `MenuBarForm` (0.97.0, user-directed: per account, with
/// one control for all), except that the FOCUSED cell expands to today's
/// digits while `expandsFocus` is on. Identity is a letter (the monogram,
/// in the tags' dim ink), never a color: color already means risk. The
/// invariance guard: a lone expanded cell composes exactly today's runs,
/// so a single-account bar is byte-identical to the pre-0.96 one
/// (`--snapshot`'s statusitem-*.png, `cmp`-ed across the change).
enum StatusItemRenderer {
    /// One account's cell.
    struct Cell: Equatable {
        let profileID: String
        /// Empty when the bar holds one account — a letter would label
        /// nothing.
        let monogram: String
        /// The S/W/scoped triple; nil when nothing has been fetched yet.
        let segments: [MenuBarSegment]?
        let stale: Bool
        let focused: Bool
        /// How the cell draws when it is not the expanded one.
        var form: MenuBarForm = .standard
        /// Drawn in its own `NSStatusItem` rather than the shared one.
        var ownItem = false
        /// What the cell holds, in order (0.98.0): the meters in `form`,
        /// plus whatever was dragged in beside them. The standard list is
        /// the meters alone — the pre-0.98 cell exactly.
        var elements: [MenuBarElement] = MenuBarLayout.standard
    }

    struct Model: Equatable {
        /// The provider's mark ahead of the cells.
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
        let cells: [Cell]
        /// The focused cell draws as today's digits whatever its form.
        let expandsFocus: Bool
        /// The clock a countdown is phrased against, FLOORED TO THE MINUTE
        /// (0.98.0): the text changes once a minute, so the model — which
        /// the controller compares to skip a redraw — changes once a minute
        /// too, on the tick that redraws it.
        var now: Date = Model.minute(Date())
        /// Preview only: an element that would compose nothing right now
        /// (a runs-out element while every forecast is clean) draws as a
        /// dashed placeholder, so a drop never looks like it failed. The
        /// bar itself NEVER sets this.
        var ghosts = false

        init(
            glyph: String, incident: ServiceStatusCard.Indicator? = nil, indicator: Bool = false,
            cells: [Cell], expandsFocus: Bool = true, now: Date = Model.minute(Date()),
            ghosts: Bool = false
        ) {
            self.glyph = glyph
            self.incident = incident
            self.indicator = indicator
            self.cells = cells
            self.expandsFocus = expandsFocus
            self.now = Model.minute(now)
            self.ghosts = ghosts
        }

        static func minute(_ date: Date) -> Date {
            Date(timeIntervalSinceReferenceDate: floor(date.timeIntervalSinceReferenceDate / 60) * 60)
        }

        /// The one-account shape — today's model, unchanged for every
        /// caller that meters one thing. A form other than the standard
        /// one, or focus not expanded, is the person's own choice for
        /// their one account and draws as such.
        init(
            segments: [MenuBarSegment]?, stale: Bool, glyph: String,
            incident: ServiceStatusCard.Indicator? = nil, indicator: Bool = false,
            form: MenuBarForm = .standard, expandsFocus: Bool = true,
            elements: [MenuBarElement] = MenuBarLayout.standard, now: Date = Model.minute(Date())
        ) {
            self.init(
                glyph: glyph, incident: incident, indicator: indicator,
                cells: [Cell(
                    profileID: Profile.defaultID, monogram: "", segments: segments, stale: stale,
                    focused: true, form: form, elements: elements)],
                expandsFocus: expandsFocus, now: now)
        }

        /// The first cell's triple — the one-account reading.
        var segments: [MenuBarSegment]? { cells.first?.segments }
        /// Every cell stale (or no cell at all): the glyph greys too.
        var stale: Bool { cells.allSatisfy(\.stale) }
    }

    static func model(
        for state: DisplayState, predictions: [String: UsagePrediction] = [:],
        glyph: String = "✳︎", serviceStatus: ServiceStatusCard? = nil,
        notices: NoticesCard? = nil, form: MenuBarForm = .standard, expandsFocus: Bool = true,
        elements: [MenuBarElement] = MenuBarLayout.standard, now: Date = Date()
    ) -> Model {
        // Which impacts are loud enough to badge is decision D2, and it lives
        // on the card so the TUI's rungs and this badge can't drift apart.
        let alarming = serviceStatus?.alarmingImpact
        let indicator = notices?.indicator ?? false
        guard let snapshot = state.snapshot else {
            return Model(
                segments: nil, stale: true, glyph: glyph, incident: alarming,
                indicator: indicator, form: form, expandsFocus: expandsFocus,
                elements: elements, now: now)
        }
        return Model(
            segments: UsageFormatting.menuBarSegments(
                from: snapshot.meters, predictions: predictions),
            stale: state.isStale,
            glyph: glyph,
            incident: alarming,
            indicator: indicator,
            form: form,
            expandsFocus: expandsFocus,
            elements: elements,
            now: now
        )
    }

    /// How one account draws: its form, its elements, and whether it takes
    /// its own item.
    struct CellStyle: Equatable {
        var form: MenuBarForm = .standard
        var ownItem = false
        var elements: [MenuBarElement] = MenuBarLayout.standard
    }

    /// The several-accounts shape, from the digest's own cells (the WRITER
    /// decides which accounts show and with which digits — so the app's
    /// bar and the TUI's header can't disagree) in the order given, dressed
    /// by each account's own style (the app's record, not the digest's).
    static func model(
        cells: [MenuBarCell], focusedID: String?, styles: [String: CellStyle], glyph: String,
        expandsFocus: Bool, serviceStatus: ServiceStatusCard? = nil, notices: NoticesCard? = nil,
        now: Date = Date()
    ) -> Model {
        Model(
            glyph: glyph, incident: serviceStatus?.alarmingImpact,
            indicator: notices?.indicator ?? false,
            cells: cells.map { cell in
                let style = styles[cell.profile] ?? CellStyle()
                return Cell(
                    profileID: cell.profile, monogram: cell.monogram,
                    segments: cell.segments.isEmpty ? nil : cell.segments.map(MenuBarSegment.init),
                    stale: cell.stale, focused: cell.profile == focusedID,
                    form: style.form, ownItem: style.ownItem, elements: style.elements)
            },
            expandsFocus: expandsFocus, now: now)
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

    static let bright = NSColor.white
    static let dim = NSColor.white.withAlphaComponent(0.55)
    static let staleColor = NSColor.white.withAlphaComponent(0.45)
    static let warningColor = NSColor(srgbRed: 1.0, green: 0.624, blue: 0.039, alpha: 1)
    /// Dots are solid fills, so unlike digit strokes they can afford a
    /// deep red; the ramp blends from yellow toward this.
    static let criticalColor = NSColor(srgbRed: 1.0, green: 0.271, blue: 0.227, alpha: 1)
    static let riskYellow = NSColor(srgbRed: 1.0, green: 0.839, blue: 0.039, alpha: 1)
    /// The badge's fill — a step deeper than the ramp's red so bold white
    /// digits sit on it at real contrast (Apple-badge convention).
    static let badgeRed = NSColor(srgbRed: 0.92, green: 0.216, blue: 0.18, alpha: 1)

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

    enum Run: Equatable {
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
        /// Empty width between cells (0.96.0).
        case gap(CGFloat)
        /// Three stacked bars, top to bottom S / W / scoped; a nil slot
        /// draws nothing — absent, not zero.
        case bars([BarSlot?], stale: Bool)
        /// Two rings, outer weekly and inner session; a nil ring is absent.
        case rings(outer: BarSlot?, inner: BarSlot?, stale: Bool)
        /// A 7pt sentinel painted by an account's worst risk.
        case sentinel(NSColor, filled: Bool)
        /// The preview's placeholder for an element with nothing to say
        /// right now: a dashed capsule of the badge's geometry, dim label.
        case ghost(String)
    }

    /// One bar's or ring's fill: how full, in what color.
    struct BarSlot: Equatable {
        let fraction: CGFloat
        let fill: NSColor
    }

    /// A run tagged with the cell it belongs to (nil = the glyph's) and
    /// the element within it (nil = the glyph's, or the space after it).
    struct Tagged: Equatable {
        let run: Run
        let cell: String?
        var element: MenuBarElement? = nil
    }

    /// A run at its laid-out x — the prefix-sum walk, kept so hit rects
    /// and the image agree by construction.
    struct Placed {
        let run: Run
        let x: CGFloat
        let width: CGFloat
        let cell: String?
        let element: MenuBarElement?
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
    static var font: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .semibold) }
    static var badgeFont: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .bold) }
    static let dotDiameter: CGFloat = 5
    static let dotGap: CGFloat = 2
    static let badgePaddingX: CGFloat = 3.5
    static let badgeHeight: CGFloat = 15
    static let indicatorDiameter: CGFloat = 6
    static let indicatorRing: CGFloat = 1.5

    /// The runs at their x positions, tagged by cell.
    static func layout(_ model: Model) -> [Placed] {
        place(compose(model))
    }

    static func place(_ runs: [Tagged]) -> [Placed] {
        var x: CGFloat = 0
        var placed: [Placed] = []
        for tagged in runs {
            let width = runWidth(tagged.run)
            placed.append(Placed(
                run: tagged.run, x: x, width: width, cell: tagged.cell, element: tagged.element))
            x += width
        }
        return placed
    }

    static func image(for model: Model, height: CGFloat) -> NSImage {
        image(runs: compose(model), height: height)
    }

    /// The drawing proper, over any run list — the item's, or one cell's.
    static func image(runs: [Tagged], height: CGFloat) -> NSImage {
        let placed = place(runs)
        let width = placed.reduce(0) { $0 + $1.width }
        let image = NSImage(
            size: NSSize(width: ceil(width), height: height), flipped: false
        ) { _ in
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 1.5
            shadow.shadowOffset = .zero

            // The run the indicator hugs: its right edge and top.
            var previousRun: (x: CGFloat, width: CGFloat, top: CGFloat)?
            for item in placed {
                let run = item.run
                let x = item.x
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
                case .gap:
                    break
                case .bars(let slots, let stale):
                    drawBars(slots, stale: stale, x: x, height: height)
                case .rings(let outer, let inner, let stale):
                    drawRings(outer: outer, inner: inner, stale: stale, x: x, height: height)
                case .sentinel(let color, let filled):
                    drawSentinel(color, filled: filled, x: x, height: height)
                case .ghost(let string):
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: badgeFont, .foregroundColor: dim,
                    ]
                    let size = (string as NSString).size(withAttributes: attributes)
                    let rect = NSRect(
                        x: x + 0.5, y: (height - badgeHeight) / 2 + 0.5,
                        width: size.width + 2 * badgePaddingX - 1, height: badgeHeight - 1)
                    let outline = NSBezierPath(
                        roundedRect: rect, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2)
                    outline.lineWidth = 1
                    outline.setLineDash([3, 2], count: 2, phase: 0)
                    dim.setStroke()
                    outline.stroke()
                    (string as NSString).draw(
                        at: NSPoint(x: x + badgePaddingX, y: (height - size.height) / 2),
                        withAttributes: attributes)
                }
                if case .indicator = run { continue }
                previousRun = (x, inkWidth(run), inkTop(run, height: height))
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The invariance guard: a lone cell drawn as unlabeled digits IS
    /// today's item — the one-account Mac's bar, and an expanded account in
    /// an item of its own. A lone cell in any other dress (rings for one's
    /// only account; an own item beside the shared one) composes like a
    /// row of one.
    static func compose(_ model: Model) -> [Tagged] {
        guard model.cells.count > 1 else {
            guard let cell = model.cells.first else { return composeSingle(model, cell: nil) }
            if isExpanded(cell, in: model) || cell.form == .digits && cell.monogram.isEmpty {
                return composeSingle(model, cell: cell)
            }
            return composeCells(model)
        }
        return composeCells(model)
    }

    /// The focused cell, while focus is expanded: today's digits, no letter.
    static func isExpanded(_ cell: Cell, in model: Model) -> Bool {
        model.expandsFocus && cell.focused
    }

    /// The pre-0.96 item: the glyph, a space, the cell's triple — and, since
    /// 0.98.0, the cell's other elements around the triple in their order,
    /// each composing nothing while it has nothing to say, so a bar that
    /// holds the meters alone (or a quiet runs-out element) is byte-
    /// identical to the pre-0.98 one.
    static func composeSingle(_ model: Model, cell: Cell?) -> [Tagged] {
        let stale = cell?.stale ?? true
        var runs = glyphRuns(model, stale: stale)
        runs.append(Tagged(run: .text(" ", dim, font), cell: nil))
        guard let cell else {
            runs.append(contentsOf: segmentRuns(nil, stale: stale).map { Tagged(run: $0, cell: nil) })
            return runs
        }
        runs.append(contentsOf: elementRuns(cell, expanded: true, now: model.now, ghosts: model.ghosts))
        return runs
    }

    /// An incident dresses the provider's own mark — the agent indicator
    /// itself goes colored, which is what makes it readable at a glance
    /// without stealing the digits' meaning. Staleness never suppresses
    /// it: a stale usage number says nothing about the service's health.
    /// The dot rides the glyph (or its capsule) — declared right after the
    /// run it hugs, before any spacer, so it never adds width.
    static func glyphRuns(_ model: Model, stale: Bool) -> [Tagged] {
        var runs: [Tagged] = [Tagged(
            run: model.incident.map { .glyphBadge(model.glyph, incidentFill($0)) }
                ?? .text(model.glyph, stale ? staleColor : accent, font),
            cell: nil)]
        if model.indicator { runs.append(Tagged(run: .indicator, cell: nil)) }
        return runs
    }

    /// Today's `S15·W19·F25%` — or `—` with nothing fetched.
    static func segmentRuns(_ segments: [MenuBarSegment]?, stale: Bool) -> [Run] {
        guard let segments, !segments.isEmpty else {
            return [.text("—", dim, font)]
        }
        var runs: [Run] = []
        let quiet = stale ? staleColor : dim
        for (index, segment) in segments.enumerated() {
            if index > 0 { runs.append(.text("·", quiet, font)) }
            guard let percent = segment.percent else {
                runs.append(.text(segment.tag, quiet, font))
                runs.append(.text("–", quiet, font))
                continue
            }
            switch ornament(for: segment, stale: stale) {
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
        case .ghost:
            return (height + badgeHeight) / 2
        case .dot, .indicator, .gap, .bars, .rings, .sentinel:
            return height
        }
    }

    static func runWidth(_ run: Run) -> CGFloat {
        switch run {
        case .text(let string, _, let font):
            return (string as NSString).size(withAttributes: [.font: font]).width
        case .dot:
            return dotDiameter + 2 * dotGap
        case .badge(let string), .ghost(let string):
            let text = (string as NSString).size(withAttributes: [.font: badgeFont]).width
            return text + 2 * badgePaddingX
        case .glyphBadge(let string, _):
            let text = (string as NSString).size(withAttributes: [.font: font]).width
            return text + 2 * badgePaddingX
        case .indicator:
            return 0
        case .gap(let width):
            return width
        case .bars:
            return barWidth
        case .rings:
            return ringWidth
        case .sentinel:
            return sentinelWidth
        }
    }
}
