import AppKit
import UsageCore

/// Pure state → NSImage for the status button.
///
/// The ink follows the GROUND (v0.100.1, user-reported: white digits over
/// a bright wallpaper were unreadable). The menu bar is transparent, and
/// the system picks its own items' ink from the wallpaper behind it — not
/// from the app's appearance, and not from the system's Dark Mode switch
/// (measured: a Dark Mode Mac over a cream wallpaper hands its status
/// buttons `vibrantLight` and draws the clock black). So the palette comes
/// in two grounds, `Ground`, chosen from the status button's own effective
/// appearance: whatever ink the system gives the clock, this item wears
/// too. The image is still literal pixels (isTemplate = false — a template
/// can't carry the risk colors), drawn under the ground's appearance so
/// every palette color resolves for it; the 0.2.1 palette — bright white,
/// a faint dark shadow — is the `.dark` ground, pixel for pixel.
///
/// Format: `✳︎ S15·W19·F25%`. Digits stay neutral — thin glyph strokes
/// can't carry color legibly over Liquid Glass (HIG: keep fine features
/// neutral, let fills carry color) — so exhaustion risk arrives as solid
/// geometry: a ramp-colored dot ahead of a number under watch, escalating
/// to a filled capsule carrying the segment's tag and digits in bold white
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

    /// How one account draws: its form, its elements, and whether it takes
    /// its own item.
    struct CellStyle: Equatable {
        var form: MenuBarForm = .standard
        var ownItem = false
        var elements: [MenuBarElement] = MenuBarLayout.standard
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

    /// What the item is drawn over: a bar the system inks in white, or one
    /// it inks in black.
    enum Ground: Equatable, Sendable {
        case dark
        case light

        /// The ground an appearance stands for — the status button's, in
        /// the bar: the system sets it from the wallpaper under the item.
        init(_ appearance: NSAppearance) {
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
            self = match == .darkAqua || match == .vibrantDark ? .dark : .light
        }

        /// The appearance the image draws under, so the palette resolves
        /// for this ground whatever context the image lands in.
        var appearance: NSAppearance {
            NSAppearance(named: self == .dark ? .darkAqua : .aqua) ?? .currentDrawing()
        }
    }

    /// One palette color in both grounds, resolved when it is DRAWN — the
    /// runs carry it as they always carried an NSColor, and composition
    /// never learns which bar it is headed for.
    static func ink(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { Ground($0) == .dark ? dark : light }
    }

    static func ink(white: CGFloat, black: CGFloat) -> NSColor {
        ink(dark: NSColor.white.withAlphaComponent(white), light: NSColor.black.withAlphaComponent(black))
    }

    /// The glyph's tint: the harness's accent, deepened over a bright bar —
    /// the vendors' accents are mid-tones picked for dark grounds (terracotta
    /// on cream is under 3:1).
    static func glyphInk(_ accent: UsageCore.RGBColor) -> NSColor {
        let base = NSColor(srgbRed: accent.red, green: accent.green, blue: accent.blue, alpha: 1)
        return ink(dark: base, light: base.blended(withFraction: 0.3, of: .black) ?? base)
    }

    // Over a bright bar the neutrals are the system's own near-black, and
    // every hue steps deeper: the dark ground's yellow and orange are
    // picked to glow on black and wash out on white.
    static let bright = ink(white: 1, black: 0.85)
    static let dim = ink(white: 0.55, black: 0.58)
    static let staleColor = ink(white: 0.45, black: 0.4)
    static let warningColor = ink(
        dark: NSColor(srgbRed: 1.0, green: 0.624, blue: 0.039, alpha: 1),
        light: NSColor(srgbRed: 0.85, green: 0.42, blue: 0.0, alpha: 1))
    /// Dots are solid fills, so unlike digit strokes they can afford a
    /// deep red; the ramp blends from yellow toward this.
    private static let rampRed = (
        dark: NSColor(srgbRed: 1.0, green: 0.271, blue: 0.227, alpha: 1),
        light: NSColor(srgbRed: 0.80, green: 0.13, blue: 0.11, alpha: 1))
    private static let rampYellow = (
        dark: NSColor(srgbRed: 1.0, green: 0.839, blue: 0.039, alpha: 1),
        light: NSColor(srgbRed: 0.74, green: 0.51, blue: 0.0, alpha: 1))
    /// The badge's fill — a step deeper than the ramp's red so bold white
    /// digits sit on it at real contrast (Apple-badge convention). White
    /// on a fill reads over any bar, so this one is the same on both.
    static let badgeRed = NSColor(srgbRed: 0.92, green: 0.216, blue: 0.18, alpha: 1)

    /// The yellow→red ramp at a severity, blended WITHIN a ground — a
    /// blend of two resolved-late colors would resolve at blend time, under
    /// whatever appearance happened to be current.
    static func rampColor(_ severity: Double) -> NSColor {
        ink(
            dark: rampYellow.dark.blended(withFraction: severity, of: rampRed.dark) ?? rampRed.dark,
            light: rampYellow.light.blended(withFraction: severity, of: rampRed.light) ?? rampRed.light)
    }

    /// Exhaustion risk decides the dressing; with no prediction, the
    /// discrete percent-threshold levels stand in. Stale data never
    /// alarms — it's grey and quiet like the rest of the stale title.
    static func ornament(for segment: MenuBarSegment, stale: Bool) -> Ornament {
        if stale { return .plain(staleColor) }
        if let severity = segment.severity {
            guard severity > 0 else { return .plain(bright) }
            if severity >= badgeSeverity { return .badge }
            return .dot(rampColor(severity))
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
        /// A harness's mark at a size of its own (0.101.0): centred on its
        /// INK, not its line box — a scaled ⬡ sat visibly low — and drawn
        /// with a stroke in its own colour, because an outline glyph's hair
        /// stays a hair however large the font. The bundled mark at the
        /// digits' size stays a plain `.text` run: those pixels are pinned.
        case mark(String, NSColor, NSFont)
        case dot(NSColor)
        case badge(String)
        /// The provider glyph on an incident-colored capsule, drawn white —
        /// same geometry as `badge`, its own fill, and the glyph's font so
        /// the mark keeps its shape (surface S3).
        case glyphBadge(String, NSColor)
        /// The pending-notice dot over the run drawn just before it: the
        /// digits' ink, at the glyph's top-right, knocked out of whatever sits under it
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

    /// A run tagged with the harness it belongs to, the cell within it
    /// (nil = that harness's mark) and the element within the cell (nil = the
    /// mark, or the space after it).
    struct Tagged: Equatable {
        let run: Run
        let harness: String
        var cell: String? = nil
        var element: MenuBarElement? = nil
    }

    /// A run at its laid-out x — the prefix-sum walk, kept so hit rects
    /// and the image agree by construction.
    struct Placed {
        let run: Run
        let x: CGFloat
        let width: CGFloat
        let harness: String
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
                run: tagged.run, x: x, width: width, harness: tagged.harness,
                cell: tagged.cell, element: tagged.element))
            x += width
        }
        return placed
    }

    /// `ground` defaults to the dark bar every preview swatch and snapshot
    /// paints for itself; only the status item asks the real bar.
    static func image(for model: Model, height: CGFloat, ground: Ground = .dark) -> NSImage {
        image(runs: compose(model), height: height, ground: ground)
    }

    /// The drawing proper, over any run list — the item's, or one cell's.
    static func image(runs: [Tagged], height: CGFloat, ground: Ground = .dark) -> NSImage {
        let placed = place(runs)
        let width = placed.reduce(0) { $0 + $1.width }
        let image = NSImage(
            size: NSSize(width: ceil(width), height: height), flipped: false
        ) { _ in
            ground.appearance.performAsCurrentDrawingAppearance {
                draw(placed, height: height, ground: ground)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(_ placed: [Placed], height: CGFloat, ground: Ground) {
        // The faint dark halo lifts white ink off a busy dark wallpaper;
        // under black ink it is only a smudge.
        var shadow: NSShadow?
        if ground == .dark {
            let halo = NSShadow()
            halo.shadowColor = NSColor.black.withAlphaComponent(0.5)
            halo.shadowBlurRadius = 1.5
            halo.shadowOffset = .zero
            shadow = halo
        }

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
                bright.setFill()
                NSBezierPath(ovalIn: ring.insetBy(dx: indicatorRing, dy: indicatorRing)).fill()
            case .mark(let string, let color, let markFont):
                drawMark(
                    string, color: color, font: markFont, shadow: shadow, x: x,
                    in: NSRect(x: 0, y: 0, width: 0, height: height))
            case .text(let string, let color, let font):
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: color,
                ]
                if let shadow { attributes[.shadow] = shadow }
                let size = (string as NSString).size(withAttributes: attributes)
                (string as NSString).draw(
                    at: NSPoint(x: x, y: (height - size.height) / 2),
                    withAttributes: attributes)
            case .dot(let color):
                NSGraphicsContext.current?.saveGraphicsState()
                shadow?.set()
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
                shadow?.set()
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
                shadow?.set()
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
    }

    /// The invariance guard: a lone cell of a lone HARNESS drawn as unlabeled
    /// digits IS today's item — the one-account Mac's bar, and an expanded
    /// account in an item of its own. A lone cell in any other dress (rings
    /// for one's only account; an own item beside the shared one) composes
    /// like a row of one. The guard reads the GROUP's cells, never the
    /// model's total: two harnesses with one account each must draw two
    /// marks, and a total of two cells would have sent them down this path.
    static func compose(_ model: Model) -> [Tagged] {
        guard model.groups.count == 1, let only = model.groups.first else {
            return composeGroups(model)
        }
        guard only.cells.count > 1 else {
            guard let cell = only.cells.first else {
                return composeSingle(model, group: only, cell: nil)
            }
            if isExpanded(cell, in: model) || cell.form == .digits && cell.monogram.isEmpty {
                return composeSingle(model, group: only, cell: cell)
            }
            return composeGroups(model)
        }
        return composeGroups(model)
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
    static func composeSingle(_ model: Model, group: Model.Group, cell: Cell?) -> [Tagged] {
        let stale = cell?.stale ?? true
        var runs = glyphRuns(group, stale: stale)
        runs.append(Tagged(run: .text(" ", dim, font), harness: group.harnessID))
        guard let cell else {
            runs.append(contentsOf: segmentRuns(nil, stale: stale).map {
                Tagged(run: $0, harness: group.harnessID)
            })
            return runs
        }
        runs.append(contentsOf: elementRuns(
            cell, harness: group.harnessID, expanded: true, now: model.now, ghosts: model.ghosts))
        return runs
    }

    /// An incident dresses the provider's own mark — the agent indicator
    /// itself goes colored, which is what makes it readable at a glance
    /// without stealing the digits' meaning. Staleness never suppresses
    /// it: a stale usage number says nothing about the service's health.
    /// The dot rides the glyph (or its capsule) — declared right after the
    /// run it hugs, before any spacer, so it never adds width.
    static func glyphRuns(_ group: Model.Group, stale: Bool, heading: Bool = false) -> [Tagged] {
        var runs: [Tagged] = [Tagged(
            run: group.incident.map { .glyphBadge(group.glyph, incidentFill($0)) }
                ?? markRun(
                    group.glyph, stale ? staleColor : glyphInk(group.accent),
                    glyphFont(for: group.glyph, heading: heading)),
            harness: group.harnessID)]
        if group.indicator {
            runs.append(Tagged(run: .indicator, harness: group.harnessID))
        }
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
        if case .mark(let string, _, let markFont) = run {
            return (string as NSString).size(withAttributes: [.font: markFont]).width
        }
        return runWidth(run)
    }

    /// The run's top edge in image coordinates.
    private static func inkTop(_ run: Run, height: CGFloat) -> CGFloat {
        switch run {
        case .text(let string, _, let font):
            return (height + (string as NSString).size(withAttributes: [.font: font]).height) / 2
        case .mark(let string, _, let markFont):
            let ink = NSAttributedString(string: string, attributes: [.font: markFont])
                .boundingRect(with: .zero, options: [.usesDeviceMetrics])
            return (height + ink.height) / 2
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
        case .text(let string, _, let font), .mark(let string, _, let font):
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
