import Charts
import SwiftUI
import UsageCore

/// A past span drawn in the meter popover's Window-view vocabulary: the
/// percent line with reset cliffs, session nubs under the plot floor, and
/// the window ledger's verdict in the caption. Read-only audit — no now
/// rule, no projections, no dead-zone hatching; history doesn't move.
struct AuditWindowChart: View {
    let model: AuditWindowModel
    let domain: DateInterval
    /// The meter's limit window — how far back a hovered reset's own window
    /// reaches. Only used by the hover curtain.
    let window: TimeInterval
    let accent: Color
    /// Plot height; the caption row adds its fixed 14 below.
    var plotHeight: CGFloat = 114

    /// Continuous-hover crosshair position, nil while the cursor is away.
    @State private var hoverDate: Date?
    /// The reset line under the cursor — its whole ended window lights up,
    /// the meter popover's idiom.
    @State private var hoveredReset: Date?

    /// Strip space below the percent floor, the meter chart's idiom.
    private static let plotFloor = -10.0
    private static let stripY = -6.0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.percent.count >= 2 || !model.nubs.isEmpty {
                chart
                    .frame(height: plotHeight)
            } else {
                Text("Nothing recorded for this span")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: plotHeight)
            }
            caption
                .frame(height: 14)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(model.percent) { point in
                AreaMark(
                    x: .value("Time", point.t), yStart: .value("Floor", 0),
                    yEnd: .value("Percent", Double(point.percent)))
                    .foregroundStyle(accent.opacity(0.12))
                LineMark(
                    x: .value("Time", point.t), y: .value("Percent", Double(point.percent)))
                    .foregroundStyle(accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            // `Color.primary`, never the bare hierarchical `.primary`: inside
            // a Chart the hierarchical styles resolve against the plot's own
            // accent-derived foreground, which painted these dashes in the
            // system accent while the meter popover's identical marks stayed
            // white. Same lesson for `.secondary` below.
            ForEach(model.resets, id: \.self) { reset in
                RuleMark(
                    x: .value("Reset", reset), yStart: .value("Floor", 0),
                    yEnd: .value("Ceiling", 100))
                    .foregroundStyle(Color.primary.opacity(hoveredReset == reset ? 1 : 0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            // The strip: a faint full-width track with accent nubs where
            // sessions actually ran.
            RuleMark(
                xStart: .value("Start", domain.start), xEnd: .value("End", domain.end),
                y: .value("Track", Self.stripY))
                .foregroundStyle(Color.secondary.opacity(0.18))
                .lineStyle(StrokeStyle(lineWidth: 4, lineCap: .round))
            ForEach(model.nubs, id: \.self) { nub in
                RuleMark(
                    xStart: .value("Start", nub.start), xEnd: .value("End", nub.end),
                    y: .value("Nub", Self.stripY))
                    .foregroundStyle(accent)
                    .lineStyle(StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            // Reset hover: curtain-dim everything outside the limit window
            // that ended at this line — the undimmed stretch IS the window —
            // with a solid twin marking where that window began. Straight
            // from the meter popover, so the two charts answer a hovered
            // reset the same way.
            if let hoveredReset {
                let curtain = Color(nsColor: .windowBackgroundColor).opacity(0.5)
                let windowStart = max(domain.start, hoveredReset.addingTimeInterval(-window))
                RuleMark(
                    x: .value("Window start", windowStart),
                    yStart: .value("Floor", 0), yEnd: .value("Ceiling", 100))
                    .foregroundStyle(Color.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                if windowStart > domain.start {
                    RectangleMark(
                        xStart: .value("Time", domain.start),
                        xEnd: .value("Time", windowStart),
                        yStart: .value("Floor", Self.plotFloor),
                        yEnd: .value("Ceiling", 100))
                        .foregroundStyle(curtain)
                }
                if hoveredReset < domain.end {
                    RectangleMark(
                        xStart: .value("Time", hoveredReset),
                        xEnd: .value("Time", domain.end),
                        yStart: .value("Floor", Self.plotFloor),
                        yEnd: .value("Ceiling", 100))
                        .foregroundStyle(curtain)
                }
            } else if let hoverDate {
                RuleMark(
                    x: .value("Hover", hoverDate), yStart: .value("Floor", 0),
                    yEnd: .value("Ceiling", 100))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: domain.start...domain.end)
        .chartYScale(domain: Self.plotFloor...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text("\(Int(percent))%")
                            .font(.caption2.weight(.semibold))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: xTicks) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(xLabel(date))
                            .font(.caption2.weight(.semibold))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let plot = geo[proxy.plotFrame!]
                            let date: Date? = proxy.value(atX: location.x - plot.minX)
                            hoverDate = date
                            hoveredReset = date.flatMap {
                                nearestReset(to: $0, plotWidth: plot.width)
                            }
                        case .ended:
                            hoverDate = nil
                            hoveredReset = nil
                        }
                    }
            }
        }
    }

    /// The reset line within grabbing distance of the cursor (~4pt of track),
    /// measured against the live plot width rather than a fixed constant —
    /// this chart is sized by its container, not pinned like the popover's.
    private func nearestReset(to date: Date, plotWidth: CGFloat) -> Date? {
        guard plotWidth > 0 else { return nil }
        let tolerance = domain.duration * 4 / Double(plotWidth)
        return model.resets
            .min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
            .flatMap { abs($0.timeIntervalSince(date)) <= tolerance ? $0 : nil }
    }

    /// Whole-hour clock ticks for a day span, day boundaries for a week —
    /// the meter chart's tiering, without its date-label failure mode.
    private var xTicks: [Date] {
        let calendar = Calendar.current
        let span = domain.duration
        var ticks: [Date] = []
        if span <= 2 * 86400 {
            guard var tick = calendar.nextDate(
                after: domain.start, matching: DateComponents(minute: 0, second: 0),
                matchingPolicy: .nextTime)
            else { return [] }
            while tick <= domain.end {
                ticks.append(tick)
                guard let next = calendar.date(byAdding: .hour, value: 6, to: tick)
                else { break }
                tick = next
            }
        } else {
            var day = calendar.startOfDay(for: domain.start)
            if day < domain.start {
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? domain.end
            }
            while day <= domain.end {
                ticks.append(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day)
                else { break }
                day = next
            }
        }
        return ticks
    }

    private func xLabel(_ date: Date) -> String {
        domain.duration <= 2 * 86400
            ? UsageFormatting.clockTime(date)
            : Self.weekdayFormatter.string(from: date)
    }

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()

    /// Fixed-height caption: the hover readout while the cursor is on the
    /// plot, the ledger's verdict otherwise. Never reflows.
    @ViewBuilder private var caption: some View {
        HStack(spacing: 4) {
            if let hoveredReset {
                // The window the hovered line closed, named the same way the
                // meter popover names it.
                Text(
                    "\(UsageFormatting.clockTime(hoveredReset.addingTimeInterval(-window)))"
                    + " – \(UsageFormatting.clockTime(hoveredReset)) · window "
                    + UsageFormatting.duration(window))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let hoverDate {
                Text(hoverReadout(at: hoverDate))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let outcome = model.outcomes.last {
                Text(outcomeText(outcome))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if outcome.reachedLimit {
                    Text("· limit reached")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                }
            } else if let peak = model.peakPercent {
                Text("Peak \(peak)% · no window closed in this span")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if !model.nubs.isEmpty {
                Text("Sessions shown · percent history not retained this far back")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    private func hoverReadout(at date: Date) -> String {
        // Carry-forward: the percent standing at the hovered instant is the
        // last drawn point at or before it.
        let standing = model.percent.last { $0.t <= date }?.percent
        let active = model.nubs.contains { $0.contains(date) }
        var parts = [UsageFormatting.clockTime(date)]
        if let standing { parts.append("\(standing)%") }
        if active { parts.append("active") }
        return parts.joined(separator: " · ")
    }

    private func outcomeText(_ outcome: WindowOutcome) -> String {
        let closed = "Window closed \(UsageFormatting.clockTime(outcome.end))"
        if let peak = outcome.peakPercent ?? outcome.lastPercent {
            return "\(closed) at \(outcome.lastPercent.map(String.init) ?? "—")% · peak \(peak)%"
        }
        return closed
    }
}
