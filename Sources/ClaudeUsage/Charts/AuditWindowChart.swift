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
    /// Token moments behind the per-model overlay curves, and the palette
    /// they share with every other model surface. Empty timeline = no
    /// curves, and the chart is the percent trace alone.
    var timeline: [TokenSlot] = []
    var modelColors: [String: Color] = [:]
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

    /// The model curve the cursor is nearest, drawn last and named at its
    /// tip while its peers recede.
    @State private var focusedModel: String?

    /// Strip space below the percent floor, the meter chart's idiom.
    private static let plotFloor = -10.0
    private static let stripY = -6.0

    /// Per-model cumulative curves on this span's percent axis, anchored to
    /// the percent the span actually gained (drops excluded, so a sawtooth
    /// can't cancel itself). Capped only when the span IS one window — a day
    /// over a 5h meter holds about five, and that overshoot is the point.
    private var curves: [(model: String, color: Color, points: [ModelCurves.Point])] {
        guard !timeline.isEmpty else { return [] }
        let scoped = timeline.filter { domain.contains($0.t) }
        let models = Array(Set(scoped.map(\.model))).sorted()
        guard !models.isEmpty else { return [] }
        let anchor = ModelCurves.gainsPercentPerToken(
            percents: model.percent.map(\.percent),
            tokens: scoped.reduce(0) { $0 + $1.tally.total })
        return ModelCurves.build(
            models: models,
            moments: scoped.map {
                ModelCurves.Moment(model: $0.model, t: $0.t, amount: $0.tally.total)
            },
            start: domain.start, end: domain.end,
            percentPerToken: anchor,
            cap: domain.duration <= window * 1.01
        ).map { ($0.model, modelColors[$0.model] ?? .gray, $0.points) }
    }

    /// The focused curve is drawn last so it sits on top; its peers recede
    /// to 0.15, the popover's figure.
    private func curveOpacity(_ model: String) -> Double {
        guard let focusedModel else { return 0.85 }
        return model == focusedModel ? 1 : 0.15
    }

    private func drawOrder(
        _ curves: [(model: String, color: Color, points: [ModelCurves.Point])]
    ) -> [(model: String, color: Color, points: [ModelCurves.Point])] {
        guard let focusedModel else { return curves }
        return curves.filter { $0.model != focusedModel }
            + curves.filter { $0.model == focusedModel }
    }

    /// Rebuilds the drawn curves and asks which one the cursor is on.
    private func focusedCurve(
        at date: Date, value: Double, plotHeight: CGFloat
    ) -> String? {
        let shown = curves
        let ceiling = ModelCurves.ceiling(
            shown.map { ModelCurves.Curve(model: $0.model, points: $0.points) })
        return focus(
            at: date, value: value, in: shown,
            ceiling: ceiling, plotHeight: plotHeight)
    }

    /// The curve passing nearest the cursor, within ~8pt of plot height —
    /// the popover's grab distance. Curves are dense (180 buckets), so the
    /// nearest sample in time is close enough to compare heights against.
    private func focus(
        at date: Date, value: Double,
        in curves: [(model: String, color: Color, points: [ModelCurves.Point])],
        ceiling: Double, plotHeight: CGFloat
    ) -> String? {
        guard plotHeight > 0, ceiling > 0 else { return nil }
        let grab = Double(8) / Double(plotHeight) * ceiling
        var best: (model: String, distance: Double)?
        for curve in curves {
            // Nothing is drawn before a curve's first point (the model
            // wasn't in use yet), so nothing there can be grabbed.
            guard let first = curve.points.first, date >= first.t else { continue }
            guard let nearest = curve.points.min(by: {
                abs($0.t.timeIntervalSince(date)) < abs($1.t.timeIntervalSince(date))
            }) else { continue }
            let distance = abs(nearest.value - value)
            if distance <= grab, best.map({ distance < $0.distance }) ?? true {
                best = (curve.model, distance)
            }
        }
        return best?.model
    }

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
        let curves = self.curves
        // Uncapped curves over a multi-window span run well past 100; a
        // fixed 0…100 domain would clip them silently and read as a
        // rendering fault. The headroom band above the tallest is the
        // popover's 15%, so the tip labels never land on data.
        let ceiling = ModelCurves.ceiling(
            curves.map { ModelCurves.Curve(model: $0.model, points: $0.points) })
        return Chart {
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
            WindowPlot.resets(model.resets, hovered: hoveredReset, ceiling: ceiling)
            // Per-model overlay curves in the shared palette, focused one
            // last so it draws on top. No legend to sync here — the day
            // drill's grid has one, the week's audit has none — so the tip
            // label is what names the curve under the cursor.
            ForEach(drawOrder(curves), id: \.model) { curve in
                ForEach(curve.points, id: \.t) { point in
                    LineMark(
                        x: .value("Time", point.t),
                        y: .value("Tokens", point.value),
                        series: .value("Model", curve.model))
                        .foregroundStyle(curve.color.opacity(curveOpacity(curve.model)))
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                }
            }
            if let focusedModel, let curve = curves.first(where: { $0.model == focusedModel }),
               let tip = curve.points.last {
                PointMark(x: .value("Time", tip.t), y: .value("Tokens", tip.value))
                    .symbolSize(0)
                    .annotation(
                        position: .top, alignment: .center, spacing: 2,
                        overflowResolution: .init(x: .fit(to: .plot), y: .disabled)
                    ) {
                        Text(ModelNames.display(curve.model))
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(curve.color)
                    }
            }
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
        .chartYScale(domain: Self.plotFloor...(ceiling * 1.15))
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
        .chartBackground { proxy in
            GeometryReader { geo in
                // The same hatching the popover paints over a dead zone —
                // history that ran out has to read the way a forecast that
                // will run out reads.
                WindowPlot.unusableHatching(
                    model.exhausted, proxy: proxy, geometry: geo)
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
                                focusedModel = nil
                            } else {
                                hoveredNub = nil
                                // A reset line within reach outranks curve
                                // focus — its ended window lights instead.
                                let reset = date.flatMap {
                                    WindowPlot.nearestReset(
                                        to: $0, in: model.resets,
                                        span: domain.duration, trackWidth: plot.width)
                                }
                                hoveredReset = reset
                                if reset == nil, let date, let depth {
                                    focusedModel = focusedCurve(
                                        at: date, value: depth, plotHeight: plot.height)
                                } else {
                                    focusedModel = nil
                                }
                            }
                        case .ended:
                            hoverDate = nil
                            hoveredReset = nil
                            hoveredNub = nil
                            focusedModel = nil
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
