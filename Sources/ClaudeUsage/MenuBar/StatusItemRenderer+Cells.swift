import AppKit
import UsageCore

/// The several-accounts half of the renderer (0.96.0): how a cell draws
/// under each `MenuBarStyle`, the geometry of bars/rings/sentinels, the hit
/// rectangles the controller resolves a hover against, and the one image
/// per account the `itemPerProfile` style needs. Split from
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
    /// Between a monogram and the shape it labels.
    static let monogramGap: CGFloat = 2
    /// After the glyph, before the first cell.
    static let glyphGap: CGFloat = 5
    /// After an expanded (digits) cell, before the next one — a touch wider
    /// than `cellGap`, since digits end flush against their `%`.
    static let expandedGap: CGFloat = 7
    static let trackColor = NSColor.white.withAlphaComponent(0.22)
    static let staleTrackColor = NSColor.white.withAlphaComponent(0.14)
    static let barFillColor = NSColor.white.withAlphaComponent(0.88)
    static let sentinelQuiet = NSColor.white.withAlphaComponent(0.35)

    // MARK: - Composition

    /// Several cells under one glyph. Every style lays out the same way —
    /// glyph, then a cell per account — and differs only in what a cell
    /// draws. `itemPerProfile` composes here too (as `bars`) but is never
    /// drawn: the controller asks for `itemImages` instead.
    static func composeCells(_ model: Model) -> [Tagged] {
        var runs = glyphRuns(model, stale: model.stale)
        for (index, cell) in model.cells.enumerated() {
            let expanded = model.style == .barsExpandedFocus && cell.focused
                || model.style == .focusedSentinels && cell.focused
            // The gap BEFORE a cell belongs to that cell, so the hit
            // regions stay contiguous with exactly one glyph region at the
            // left — a pointer in the space between two accounts lands on
            // the one it is moving toward, never back on the glyph.
            let gap: CGFloat = index == 0
                ? (expanded ? glyphSpaceWidth : glyphGap)
                : (expanded ? expandedGap : cellGap)
            runs.append(Tagged(run: .gap(gap), cell: cell.profileID))
            runs.append(contentsOf: cellRuns(cell, model: model, expanded: expanded))
        }
        return runs
    }

    /// The width of today's separator space, so an expanded cell sits
    /// exactly where the single-account item's digits sit.
    static var glyphSpaceWidth: CGFloat {
        (" " as NSString).size(withAttributes: [.font: font]).width
    }

    private static func cellRuns(_ cell: Cell, model: Model, expanded: Bool) -> [Tagged] {
        func tag(_ runs: [Run]) -> [Tagged] {
            runs.map { Tagged(run: $0, cell: cell.profileID) }
        }
        // The expanded cell is today's item, verbatim — the whole point of
        // the default style is that the number you check most stays exact.
        if expanded { return tag(segmentRuns(cell.segments, stale: cell.stale)) }
        switch model.style {
        case .focusedSentinels:
            return tag([.sentinel(
                sentinelColor(cell), filled: (worstSeverity(cell) ?? 0) >= badgeSeverity)])
        case .rings:
            return tag(monogramRuns(cell) + [.rings(
                outer: slot(cell.segments, rank: 1, stale: cell.stale),
                inner: slot(cell.segments, rank: 0, stale: cell.stale),
                stale: cell.stale)])
        case .compactDigits:
            return tag(monogramRuns(cell) + compactRuns(cell))
        case .bars, .barsExpandedFocus, .itemPerProfile:
            guard cell.segments != nil else { return tag(monogramRuns(cell) + [.text("–", quiet(cell), font)]) }
            return tag(monogramRuns(cell) + [.bars(
                (0...2).map { slot(cell.segments, rank: $0, stale: cell.stale) }, stale: cell.stale)])
        }
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
        return riskYellow.blended(withFraction: severity, of: criticalColor) ?? criticalColor
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
        let profileID: String?
        let rect: NSRect
    }

    static func cellRects(for model: Model, height: CGFloat) -> [CellRect] {
        let placed = layout(model)
        guard !placed.isEmpty else { return [] }
        let width = placed.reduce(0) { $0 + $1.width }
        var starts: [(id: String?, x: CGFloat)] = []
        for item in placed {
            if let last = starts.last, last.id == item.cell { continue }
            starts.append((item.cell, item.x))
        }
        return starts.enumerated().map { index, group in
            let end = index + 1 < starts.count ? starts[index + 1].x : width
            return CellRect(
                profileID: group.id,
                rect: NSRect(x: group.x, y: 0, width: max(0, end - group.x), height: height))
        }
    }

    /// The `itemPerProfile` style: one image per account, each today's
    /// item. Only the FIRST carries the provider-level dressing (the
    /// incident capsule, the pending-notice dot) — an alarm repeated once
    /// per account would read as several outages.
    static func itemImages(for model: Model, height: CGFloat) -> [(profileID: String, image: NSImage)] {
        model.cells.enumerated().map { index, cell in
            let single = Model(
                glyph: model.glyph,
                incident: index == 0 ? model.incident : nil,
                indicator: index == 0 ? model.indicator : false,
                cells: [cell], style: model.style)
            return (cell.profileID, image(for: single, height: height))
        }
    }
}
