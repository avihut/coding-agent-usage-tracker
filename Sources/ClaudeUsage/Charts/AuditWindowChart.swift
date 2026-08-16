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
    /// The activity nub under the cursor; the graph above it stays lit while
    /// everything else curtains.
    @State private var hoveredNub: WindowPlot.Nub?

    /// The ledger's plain intervals in the strip's shared shape, re-cut
    /// against the spans the limit was already spent through so those
    /// stretches read red.
    private var nubs: [WindowPlot.Nub] {
        WindowPlot.marking(
            model.nubs.map { WindowPlot.Nub(start: $0.start, end: $0.end) },
            exhausted: model.exhausted)
    }

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
            WindowPlot.exhaustedRegions(model.exhausted, ceiling: 100)
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
            WindowPlot.resets(model.resets, hovered: hoveredReset, ceiling: 100)
            // The strip: a faint full-width track with accent nubs where
            // sessions actually ran. Geometry is this chart's own — a single
            // round-capped rule rather than the popover's band — but the
            // colouring and the hover dimming come from WindowPlot.
            RuleMark(
                xStart: .value("Start", domain.start), xEnd: .value("End", domain.end),
                y: .value("Track", Self.stripY))
                .foregroundStyle(Color.secondary.opacity(0.18))
                .lineStyle(StrokeStyle(lineWidth: 4, lineCap: .round))
            ForEach(nubs, id: \.start) { nub in
                RuleMark(
                    xStart: .value("Start", nub.start), xEnd: .value("End", nub.end),
                    y: .value("Nub", Self.stripY))
                    .foregroundStyle(
                        WindowPlot.nubColor(nub.kind, accent: accent)
                            .opacity(WindowPlot.nubOpacity(nub, hovered: hoveredNub)))
                    .lineStyle(StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            if let hoveredNub {
                WindowPlot.nubCurtain(
                    hoveredNub, start: domain.start, end: domain.end, ceiling: 100)
            } else if let hoveredReset {
                WindowPlot.resetCurtain(
                    hoveredReset, window: window,
                    start: domain.start, end: domain.end, ceiling: 100)
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
                            let depth: Double? = proxy.value(atY: location.y - plot.minY)
                            hoverDate = date
                            // Below the plot floor the cursor is on the
                            // activity strip: nubs take the hover there and
                            // the reset lines let go — the popover's
                            // precedence, so both charts read the same.
                            if let depth, depth < 0 {
                                hoveredNub = date.flatMap { moment in
                                    nubs.first { $0.contains(moment) }
                                }
                                hoveredReset = nil
                            } else {
                                hoveredNub = nil
                                hoveredReset = date.flatMap {
                                    WindowPlot.nearestReset(
                                        to: $0, in: model.resets,
                                        span: domain.duration, trackWidth: plot.width)
                                }
                            }
                        case .ended:
                            hoverDate = nil
                            hoveredReset = nil
                            hoveredNub = nil
                        }
                    }
            }
        }
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
            if let hoveredNub {
                // The hovered session's range and length — the popover's
                // phrasing, and the reason its curtain has words.
                Text(
                    "\(UsageFormatting.clockTime(hoveredNub.sessionStart))"
                    + " – \(UsageFormatting.clockTime(hoveredNub.end)) · "
                    + (hoveredNub.kind == .exhausted ? "unreachable " : "active ")
                    + UsageFormatting.duration(
                        hoveredNub.end.timeIntervalSince(hoveredNub.sessionStart)))
                    .font(.caption2)
                    .foregroundStyle(hoveredNub.kind == .exhausted ? .red : .secondary)
            } else if let hoveredReset {
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
