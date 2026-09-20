import AppKit
import UsageCore

/// The several-accounts half of the renderer (0.96.0): how a cell draws
/// in each `MenuBarForm`, the geometry of bars/rings/sentinels, the hit
/// rectangles the controller resolves a hover against, and the split into
/// one model per `NSStatusItem` for accounts that take their own. Split from
/// StatusItemRenderer.swift along the house rule (a file past ~600 lines
/// splits at a whole-type seam) — the drawing vocabulary and the single-cell
/// path stay there, this file only knows about cells.
extension StatusItemRenderer {
    // MARK: - Geometry

    /// Bars: three 14×3pt fills, 1.5pt apart — a fill, not a fine feature,
    /// so the risk ramp reads (the digits rule's other side).
    static let barWidth: CGFloat = 14
    static let barHeight: CGFloat = 3
    static let barGap: CGFloat = 1.5
    /// Rings: outer weekly r 6.75, inner session r 3.25, 2.5pt strokes.
    static let ringWidth: CGFloat = 16
    static let outerRingRadius: CGFloat = 6.75
    static let innerRingRadius: CGFloat = 3.25
    static let ringStroke: CGFloat = 2.5
    /// A sentinel is ⌀7 — a ring while it is quiet, solid once it alarms.
    static let sentinelWidth: CGFloat = 7
    static let sentinelRadius: CGFloat = 2.75
    static let sentinelStroke: CGFloat = 1.5
    /// Between one account's cell and the next.
    static let cellGap: CGFloat = 6
    /// Between one HARNESS's block and the next (0.101.0) — wider than any
    /// gap inside a block, so the bar reads as vendors first, accounts
    /// within them.
    static let harnessGap: CGFloat = 9
    /// Between a monogram and the shape it labels.
    static let monogramGap: CGFloat = 2
    /// After the glyph, before the first cell.
    static let glyphGap: CGFloat = 5
    /// After an expanded (digits) cell, before the next one — a touch wider
    /// than `cellGap`, since digits end flush against their `%`.
    static let expandedGap: CGFloat = 7
    /// Between two elements of one cell (0.98.0) — the meters and a
    /// countdown beside them: closer than another account, farther than a
    /// monogram from its shape.
    static let elementGap: CGFloat = 5
    /// Between two countdowns of one element (`.each`).
    static let countdownGap: CGFloat = 4
    static let trackColor = ink(white: 0.22, black: 0.18)
    static let staleTrackColor = ink(white: 0.14, black: 0.11)
    static let barFillColor = ink(white: 0.88, black: 0.8)
    static let sentinelQuiet = ink(white: 0.35, black: 0.35)

    // MARK: - Composition

    /// Every harness in turn, `harnessGap` between two of them. With ONE
    /// harness this is exactly the pre-0.101 composition — no leading gap,
    /// nothing else added — which is what keeps a Claude-only bar's pixels.
    static func composeGroups(_ model: Model) -> [Tagged] {
        var runs: [Tagged] = []
        for (index, group) in model.groups.enumerated() {
            // The gap BEFORE a harness belongs to its mark, so a pointer
            // between two vendors lands on the one it is moving toward.
            if index > 0 {
                runs.append(Tagged(run: .gap(harnessGap), harness: group.harnessID))
            }
            runs.append(contentsOf: groupRuns(group, in: model))
        }
        return runs
    }

    /// One harness's block: its mark, then a cell per account of that
    /// harness, each in its own form — the expanded one (focus, while focus
    /// expands) as today's unlabeled digits.
    static func groupRuns(_ group: Model.Group, in model: Model) -> [Tagged] {
        // A heading only where there are several harnesses to head: one
        // harness with several accounts is the pinned pre-0.101 bar.
        var runs = glyphRuns(group, stale: group.stale, heading: model.groups.count > 1)
        for (index, cell) in group.cells.enumerated() {
            let expanded = isExpanded(cell, in: model)
            // Digits end flush against their `%`, so a digits cell of
            // either kind wants the wider spacing around it.
            let wide = expanded || cell.form == .digits
            // The gap BEFORE a cell belongs to that cell, so the hit
            // regions stay contiguous with exactly one glyph region at the
            // left — a pointer in the space between two accounts lands on
            // the one it is moving toward, never back on the glyph.
            let gap: CGFloat = index == 0
                ? (expanded ? glyphSpaceWidth : glyphGap)
                : (wide ? expandedGap : cellGap)
            runs.append(Tagged(
                run: .gap(gap), harness: group.harnessID, cell: cell.profileID))
            runs.append(contentsOf: cellRuns(
                cell, harness: group.harnessID, expanded: expanded, now: model.now,
                ghosts: model.ghosts))
        }
        return runs
    }

    /// The width of today's separator space, so an expanded cell sits
    /// exactly where the single-account item's digits sit.
    static var glyphSpaceWidth: CGFloat {
        (" " as NSString).size(withAttributes: [.font: font]).width
    }

    /// One cell's runs: its letter (never on the expanded cell), then its
    /// elements in order. The expanded cell's meters are today's item,
    /// verbatim — the whole point of expanding focus is that the number you
    /// check most stays exact; a cell whose OWN form is digits carries its
    /// letter like every other form, since it is not "the" account.
    static func cellRuns(
        _ cell: Cell, harness: String = HarnessResolution.bundledProviderID, expanded: Bool,
        now: Date, ghosts: Bool
    ) -> [Tagged] {
        var runs: [Tagged] = []
        // A dot has never carried a letter (its color is the whole
        // reading); every other form does. The letter belongs to the
        // meters for hit-testing: grabbing it in the preview moves the
        // account, not an element.
        if !expanded, cell.form != .dot {
            runs.append(contentsOf: monogramRuns(cell).map {
                Tagged(run: $0, harness: harness, cell: cell.profileID, element: .meters)
            })
        }
        runs.append(contentsOf: elementRuns(
            cell, harness: harness, expanded: expanded, now: now, ghosts: ghosts))
        return runs
    }

    /// The cell's elements in their order, `elementGap` between two that
    /// draw; an element with nothing to say contributes nothing — not even
    /// its gap — unless the preview asked for ghosts.
    static func elementRuns(
        _ cell: Cell, harness: String = HarnessResolution.bundledProviderID, expanded: Bool,
        now: Date, ghosts: Bool
    ) -> [Tagged] {
        var runs: [Tagged] = []
        var drawn = false
        for element in MenuBarLayout.normalized(cell.elements) {
            let body: [Run] = switch element {
            case .meters: expanded ? segmentRuns(cell.segments, stale: cell.stale) : metersRuns(cell)
            case .runsOut(let scope): runsOutRuns(cell, scope: scope, now: now, ghosts: ghosts)
            }
            guard !body.isEmpty else { continue }
            if drawn {
                runs.append(Tagged(
                    run: .gap(elementGap), harness: harness, cell: cell.profileID,
                    element: element))
            }
            drawn = true
            runs.append(contentsOf: body.map {
                Tagged(run: $0, harness: harness, cell: cell.profileID, element: element)
            })
        }
        return runs
    }

    /// The meters in the cell's form.
    static func metersRuns(_ cell: Cell) -> [Run] {
        switch cell.form {
        case .digits:
            return segmentRuns(cell.segments, stale: cell.stale)
        case .dot:
            return [.sentinel(
                sentinelColor(cell), filled: (worstSeverity(cell) ?? 0) >= badgeSeverity)]
        case .rings:
            // An account with ONE limit wears it as the outer ring: a lone
            // inner ring reads as a gauge with its big half missing.
            let lone = cell.segments?.count == 1
            return [.rings(
                outer: slot(cell.segments, rank: lone ? 0 : 1, stale: cell.stale),
                inner: lone ? nil : slot(cell.segments, rank: 0, stale: cell.stale),
                stale: cell.stale)]
        case .compactDigits:
            return compactRuns(cell)
        case .bars:
            guard cell.segments != nil else { return [.text("–", quiet(cell), font)] }
            // A LONE limit sits centred instead of top-aligned over two
            // empty rows. Two limits keep the historical three-row frame:
            // that is every pre-0.101 account without a scoped limit, and
            // its pixels are pinned (`statusitem-form-bars.png`).
            let rows = cell.segments?.count == 1 ? 1 : 3
            return [.bars(
                (0..<rows).map { slot(cell.segments, rank: $0, stale: cell.stale) }, stale: cell.stale)]
        }
    }

    /// The "Runs out" element (0.98.0): a red capsule per countdown to a
    /// forecast crossing — the tag and the time, the digits' own alarm
    /// idiom — or, once a limit is spent, its tag with ↺ and the time to
    /// its reset, quiet. NOTHING while every forecast is clean: the
    /// element exists to say when, and has nothing to say otherwise. A
    /// stale cell says nothing either (stale never alarms). The preview's
    /// ghost stands in for the nothing.
    static func runsOutRuns(_ cell: Cell, scope: RunsOutScope, now: Date, ghosts: Bool) -> [Run] {
        let countdowns = cell.stale
            ? [] : UsageFormatting.menuBarCountdowns(cell.segments ?? [], scope: scope, now: now)
        guard !countdowns.isEmpty else { return ghosts ? [.ghost("runs out")] : [] }
        var runs: [Run] = []
        for (index, countdown) in countdowns.enumerated() {
            if index > 0 { runs.append(.gap(countdownGap)) }
            if countdown.spent {
                runs.append(.text("\(countdown.tag)↺", dim, font))
                runs.append(.gap(monogramGap))
                runs.append(.text(countdown.text, bright, font))
            } else {
                runs.append(.badge("\(countdown.tag) \(countdown.text)"))
            }
        }
        return runs
    }

    /// Whether any cell shows a countdown — the controller's cue to tick
    /// once a minute.
    static func hasCountdown(_ model: Model) -> Bool {
        model.cells.contains { cell in
            guard !cell.stale, let scope = MenuBarLayout.runsOutScope(in: cell.elements) else { return false }
            return !UsageFormatting.menuBarCountdowns(cell.segments ?? [], scope: scope, now: model.now).isEmpty
        }
    }

    /// One cell alone, no glyph — the Settings thumbnails: an account's
    /// own numbers in a candidate form.
    static func cellImage(
        _ cell: Cell, height: CGFloat, now: Date = Date(), ghosts: Bool = false, ground: Ground = .dark
    ) -> NSImage {
        image(
            runs: cellRuns(cell, expanded: false, now: Model.minute(now), ghosts: ghosts),
            height: height, ground: ground)
    }

    /// One element alone — the palette's tile: what the element itself
    /// would draw, with the cell's numbers, and nothing of the cell's
    /// meters around it.
    static func elementImage(_ element: MenuBarElement, in cell: Cell, height: CGFloat, now: Date = Date()) -> NSImage {
        let runs: [Run] = switch element {
        case .meters: metersRuns(cell)
        case .runsOut(let scope): runsOutRuns(cell, scope: scope, now: Model.minute(now), ghosts: true)
        }
        return image(
            runs: runs.map {
                Tagged(
                    run: $0, harness: HarnessResolution.bundledProviderID,
                    cell: cell.profileID, element: element)
            },
            height: height)
    }

    /// Identity is a letter, in the tags' own dim ink — never a color,
    /// which already means risk. It rides the badge capsule when the
    /// account alarms, exactly as a tag joins its digits in the pill.
    private static func monogramRuns(_ cell: Cell) -> [Run] {
        guard !cell.monogram.isEmpty else { return [] }
        if !cell.stale, (worstSeverity(cell) ?? 0) >= badgeSeverity {
            return [.badge(cell.monogram), .gap(monogramGap)]
        }
        return [.text(cell.monogram, quiet(cell), font), .gap(monogramGap)]
    }

    /// Session and weekly percents, no tags and no scoped number — the
    /// monogram already says whose they are.
    private static func compactRuns(_ cell: Cell) -> [Run] {
        guard let segments = cell.segments, !segments.isEmpty else {
            return [.text("–", quiet(cell), font)]
        }
        var runs: [Run] = []
        for (index, segment) in segments.prefix(2).enumerated() {
            if index > 0 { runs.append(.text("·", quiet(cell), font)) }
            guard let percent = segment.percent else {
                runs.append(.text("–", quiet(cell), font))
                continue
            }
            switch ornament(for: segment, stale: cell.stale) {
            case .plain(let color): runs.append(.text("\(percent)", color, font))
            case .dot(let color):
                runs.append(.dot(color))
                runs.append(.text("\(percent)", bright, font))
            case .badge: runs.append(.badge("\(percent)"))
            }
        }
        return runs
    }

    private static func quiet(_ cell: Cell) -> NSColor { cell.stale ? staleColor : dim }

    /// One meter's fill: how full, in the ornament's own color. Nil when
    /// the account has no such meter — absent draws nothing, never a zero
    /// bar (this Mac's personal account has no scoped meter).
    static func slot(_ segments: [MenuBarSegment]?, rank: Int, stale: Bool) -> BarSlot? {
        guard let segments, segments.indices.contains(rank),
              let percent = segments[rank].percent
        else { return nil }
        let fill: NSColor = switch ornament(for: segments[rank], stale: stale) {
        case .plain(let color): stale ? color : barFillColor
        case .dot(let color): color
        case .badge: badgeRed
        }
        return BarSlot(fraction: min(1, max(0, CGFloat(percent) / 100)), fill: fill)
    }

    /// The account's loudest meter — what a sentinel and a monogram badge
    /// read off. Nil when nothing is predicted; a discrete critical level
    /// counts as the badge threshold, exactly as `ornament` treats it.
    static func worstSeverity(_ cell: Cell) -> Double? {
        guard !cell.stale, let segments = cell.segments else { return nil }
        let severities = segments.map { segment -> Double? in
            if let severity = segment.severity { return severity }
            return switch segment.level {
            case .critical: badgeSeverity
            case .warning: 0.5
            case .normal: nil
            }
        }
        return severities.compactMap { $0 }.max()
    }

    private static func sentinelColor(_ cell: Cell) -> NSColor {
        if cell.stale { return staleColor }
        guard let severity = worstSeverity(cell), severity > 0 else { return sentinelQuiet }
        if severity >= badgeSeverity { return badgeRed }
        return rampColor(severity)
    }

    // MARK: - Drawing

    static func drawBars(_ slots: [BarSlot?], stale: Bool, x: CGFloat, height: CGFloat) {
        let count = CGFloat(slots.count)
        let total = count * barHeight + (count - 1) * barGap
        let top = (height + total) / 2
        for (index, slot) in slots.enumerated() {
            guard let slot else { continue }
            let y = top - CGFloat(index + 1) * barHeight - CGFloat(index) * barGap
            let track = NSRect(x: x, y: y, width: barWidth, height: barHeight)
            (stale ? staleTrackColor : trackColor).setFill()
            NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
            // A hair of fill always shows, so 1% reads as "started", not
            // as "absent" — absence is the missing bar above.
            let filled = NSRect(
                x: x, y: y, width: max(barHeight / 2 + 0.5, barWidth * slot.fraction), height: barHeight)
            slot.fill.setFill()
            NSBezierPath(roundedRect: filled, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
        }
    }

    static func drawRings(outer: BarSlot?, inner: BarSlot?, stale: Bool, x: CGFloat, height: CGFloat) {
        let center = NSPoint(x: x + ringWidth / 2, y: height / 2)
        for (radius, slot) in [(outerRingRadius, outer), (innerRingRadius, inner)] {
            guard let slot else { continue }
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = ringStroke
            (stale ? staleTrackColor : trackColor).setStroke()
            track.stroke()
            guard slot.fraction > 0 else { continue }
            let arc = NSBezierPath()
            // Clockwise from twelve o'clock, the way a gauge fills.
            arc.appendArc(
                withCenter: center, radius: radius, startAngle: 90,
                endAngle: 90 - 360 * Double(slot.fraction), clockwise: true)
            arc.lineWidth = ringStroke
            arc.lineCapStyle = .round
            slot.fill.setStroke()
            arc.stroke()
        }
    }

    static func drawSentinel(_ color: NSColor, filled: Bool, x: CGFloat, height: CGFloat) {
        let center = NSPoint(x: x + sentinelWidth / 2, y: height / 2)
        color.setFill()
        color.setStroke()
        if filled {
            let disc = NSRect(
                x: center.x - sentinelWidth / 2, y: center.y - sentinelWidth / 2,
                width: sentinelWidth, height: sentinelWidth)
            NSBezierPath(ovalIn: disc).fill()
            return
        }
        let ring = NSBezierPath()
        ring.appendArc(withCenter: center, radius: sentinelRadius, startAngle: 0, endAngle: 360)
        ring.lineWidth = sentinelStroke
        ring.stroke()
    }

    // MARK: - Hit testing and per-profile items

    /// One rect per hit target, left to right and CONTIGUOUS: each group
    /// runs to where the next begins, so a pointer anywhere in the item
    /// resolves to something (the glyph's own rect carries a nil id). The
    /// controller offsets these by the image's rect inside the button.
    struct CellRect: Equatable {
        /// Nil = that harness's own mark, whose click and hover answer for
        /// the harness's focused account (0.101.0 — with one harness it was
        /// simply "the glyph").
        let profileID: String?
        /// Which harness the region belongs to; a mark region is the only
        /// way to name a harness with no cell under the pointer.
        var harnessID: String = HarnessResolution.bundledProviderID
        let rect: NSRect
    }

    static func cellRects(for model: Model, height: CGFloat) -> [CellRect] {
        let placed = layout(model)
        guard !placed.isEmpty else { return [] }
        let width = placed.reduce(0) { $0 + $1.width }
        var starts: [(id: String?, harness: String, x: CGFloat)] = []
        for item in placed {
            if let last = starts.last, last.id == item.cell, last.harness == item.harness {
                continue
            }
            starts.append((item.cell, item.harness, item.x))
        }
        return starts.enumerated().map { index, group in
            let end = index + 1 < starts.count ? starts[index + 1].x : width
            return CellRect(
                profileID: group.id, harnessID: group.harness,
                rect: NSRect(x: group.x, y: 0, width: max(0, end - group.x), height: height))
        }
    }

    /// One rect per (cell, element) group, contiguous like `cellRects` —
    /// what the preview resolves a grab or a drop against. The glyph and
    /// the space after it carry nil for both.
    struct ElementRect: Equatable {
        let profileID: String?
        let element: MenuBarElement?
        var harnessID: String = HarnessResolution.bundledProviderID
        let rect: NSRect
    }

    static func elementRects(for model: Model, height: CGFloat) -> [ElementRect] {
        let placed = layout(model)
        guard !placed.isEmpty else { return [] }
        let width = placed.reduce(0) { $0 + $1.width }
        var starts: [(id: String?, element: MenuBarElement?, harness: String, x: CGFloat)] = []
        for item in placed {
            if let last = starts.last, last.id == item.cell, last.element == item.element,
               last.harness == item.harness { continue }
            starts.append((item.cell, item.element, item.harness, item.x))
        }
        return starts.enumerated().map { index, group in
            let end = index + 1 < starts.count ? starts[index + 1].x : width
            return ElementRect(
                profileID: group.id, element: group.element, harnessID: group.harness,
                rect: NSRect(x: group.x, y: 0, width: max(0, end - group.x), height: height))
        }
    }

    /// One model per `NSStatusItem`: the shared item (nil id) holding every
    /// cell that has not asked for its own, then an item per account that
    /// has — in the accounts' order, so the bar reads left to right the way
    /// the strip reads top to bottom. Only the FIRST item carries the
    /// provider-level dressing (the incident capsule, the pending-notice
    /// dot) — an alarm repeated once per account would read as several
    /// outages.
    struct ItemModel: Equatable {
        /// Nil = the shared item.
        let profileID: String?
        let model: Model
    }

    static func itemModels(for model: Model) -> [ItemModel] {
        var items: [ItemModel] = []
        // A harness's alarm belongs to the FIRST item that carries it; once
        // placed it is stripped from the rest, or one incident would read as
        // several outages.
        var dressed: Set<String> = []
        let shared = model.groups.compactMap { group -> Model.Group? in
            let cells = group.cells.filter { !$0.ownItem }
            guard !cells.isEmpty else { return nil }
            dressed.insert(group.harnessID)
            return group.replacingCells(cells)
        }
        if !shared.isEmpty {
            items.append(ItemModel(profileID: nil, model: model.replacingGroups(shared)))
        } else if model.cells.isEmpty {
            // Nothing fetched anywhere yet: the marks and a dash, exactly as
            // the one-harness item has always rendered an empty state.
            items.append(ItemModel(profileID: nil, model: model))
            for group in model.groups { dressed.insert(group.harnessID) }
        }
        for group in model.groups {
            for cell in group.cells where cell.ownItem {
                let placed = dressed.contains(group.harnessID)
                dressed.insert(group.harnessID)
                items.append(ItemModel(
                    profileID: cell.profileID,
                    model: model.replacingGroups([
                        (placed ? group.quieted : group).replacingCells([cell])
                    ])))
            }
        }
        return items
    }
}
