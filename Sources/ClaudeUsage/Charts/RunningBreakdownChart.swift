import Charts
import SwiftUI
import UsageCore

/// The app's standard running-breakdown chart — any surface that plots a
/// cumulative series over an event list renders THIS view so the synchronized
/// behaviors (repo CLAUDE.md, "CHART BEHAVIOR CONTRACT") arrive by
/// construction rather than by reimplementation:
///
/// - a Cost/Tokens measure picker in the header, with the series total beside
///   it in the picked measure;
/// - vertical marker lines at every prompt; hovering within grabbing distance
///   of one (or hovering that prompt's row in the list) lights the whole
///   prompt-to-prompt section — meter-popover style, by curtaining everything
///   outside it — with the section's subtotal annotated on top;
/// - plain hover reads out the main series' value at the nearest event and
///   mirrors onto the event list through the shared `hoveredRow` binding;
/// - per-model overlay curves keyed to the same palette as the breakdown grid,
///   with grid-row hover and curve-proximity hover meeting in the shared
///   `hoveredModel` binding (focused curve on top, peers dimmed, name at tip);
/// - a click jumps the event list to the clicked event via `onSelectRow`.
///
/// The interaction idioms — continuous hover with plot-frame math, a
/// fixed-height readout line that never reflows, ~4pt marker snap tolerance,
/// window-background curtains, focus grab distance, hover cleared on exit —
/// are lifted from the meter popover chart and must stay consistent with it.
struct RunningBreakdownChart: View {
    let model: SessionChartModel
    let rows: [SessionEvent]
    let colors: [String: Color]
    @Binding var measure: SessionChartMeasure
    @Binding var hoveredRow: Int?
    @Binding var hoveredModel: String?
    /// Overlays the context-size curve (each call's window share) when on.
    /// The toggle only renders when the model carries context data at all.
    @Binding var showContext: Bool
    var onSelectRow: (Int) -> Void

    /// The row this chart's own hover last claimed. Leaving the chart clears
    /// the shared hover only while it still holds this value — a list row the
    /// cursor already moved onto keeps its highlight regardless of event
    /// order.
    @State private var chartHoverRow: Int?
    /// X-only zoom: the visible span in event units while pinched in; nil =
    /// the whole session. The Y scale never zooms — the vertical range IS
    /// the story. Zoomed, two-finger scrolls pan (the pan catcher feeds
    /// scrollX) and the minimap above tracks where the viewport sits.
    @State private var visibleLength: Double?
    /// Leading edge of the visible span, in event units — fed by the pan
    /// catcher, the pinch anchor math, and minimap scrubbing; the X domain
    /// derives from it.
    @State private var scrollX: Double = 0
    /// Captured at pinch start so the event under the fingers stays put
    /// while the span stretches around it.
    @State private var pinchBase: (length: Double, anchorData: Double, anchorFraction: Double)?

    private var fullLength: Double { Double(max(count - 1, 1)) }
    private static let minVisible: Double = 8

    private var accent: Color { ProviderStyle.accentColor }
    private var totals: [Double] { model.running(measure) }
    private var count: Int { model.runningTokens.count }

    /// Models drawable under the current measure — unpriced models have no
    /// cost curve to draw.
    private var visibleModels: [SessionChartModel.ModelSeries] {
        model.models.filter { $0.values(measure) != nil }
    }

    private var hoveredSection: SessionChartModel.Section? {
        guard let hoveredRow, rows.indices.contains(hoveredRow),
              case .prompt = rows[hoveredRow].kind
        else { return nil }
        return model.sections.first { $0.promptRow == hoveredRow }
    }

    var body: some View {
        if count >= 2, (model.runningTokens.last ?? 0) > 0 {
            VStack(alignment: .leading, spacing: 4) {
                header
                if let length = visibleLength {
                    ChartMinimap(
                        values: minimapValues,
                        viewportStart: scrollX / fullLength,
                        viewportWidth: length / fullLength,
                        accent: accent
                    ) { startFraction in
                        scrollX = min(
                            max(startFraction * fullLength, 0), fullLength - length)
                    }
                    .frame(height: 20)
                    .transition(.opacity)
                }
                chart
                    .frame(height: 140)
            }
            // Scoped to the zoom-presence flip: the minimap fades while the
            // layout grows/shrinks its slot — continuous pinching inside a
            // zoom doesn't animate, only entering and leaving one.
            .animation(.snappy(duration: 0.22), value: visibleLength == nil)
        }
    }

    /// The whole-session total curve compressed for the minimap strip.
    private var minimapValues: [Double] {
        thinned(150).map { totals[$0] }
    }

    // MARK: - Header

    private var hasContext: Bool { !model.contextFraction.isEmpty }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            SegmentedPicker(
                title: "Measure", selection: $measure,
                options: [("Cost", SessionChartMeasure.cost), ("Tokens", .tokens)])
            if hasContext {
                Toggle("CTX", isOn: $showContext)
                    .toggleStyle(.button)
                    .controlSize(.mini)
                    .font(.caption2.weight(.semibold))
                    .help("Overlay each call's context size as a share of its model's window")
            }
            Text(readoutText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(
                    hoveredRow == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(format(totals.last ?? 0))
                .font(.caption.weight(.bold))
                .foregroundStyle(accent)
                .monospacedDigit()
        }
        .frame(height: 18)
    }

    /// The fixed-height readout: section subtitle while a prompt is lit, the
    /// point value under plain hover, a quiet hint otherwise. Same
    /// never-reflows rule as the meter popover's readout line.
    private var readoutText: String {
        if let section = hoveredSection {
            if case .prompt(let preview) = rows[section.promptRow].kind {
                return "❯ \(preview)"
            }
        }
        if let row = hoveredRow, rows.indices.contains(row), totals.indices.contains(row) {
            let stamp = UsageFormatting.clockTime(rows[row].t)
            if let hoveredModel,
               let series = visibleModels.first(where: { $0.model == hoveredModel }),
               let values = series.values(measure) {
                return "\(ModelNames.display(hoveredModel)) · \(stamp) · \(format(values[row]))"
            }
            var line = "\(stamp) · \(format(totals[row]))"
            if showContext, model.contextFraction.indices.contains(row),
               model.contextFraction[row] > 0 {
                line += " · ctx \(Int((model.contextFraction[row] * 100).rounded()))%"
            }
            return line
        }
        return "Hover the graph — click to jump to a message"
    }

    private func format(_ value: Double) -> String {
        measure == .cost
            ? UsageFormatting.money(value)
            : "\(TokenFormat.compact(Int(value))) tok"
    }

    // MARK: - Chart

    /// The zoom shell: pinch drives the visible span (X only), panning
    /// slides it. The zoom IS the X domain — Charts' own scrollable-axes
    /// machinery never responded to trackpad scrolls here, so the pan
    /// catcher converts scroll deltas to data units directly and the scale
    /// re-derives; the Y range never changes.
    private var chart: some View {
        chartCore
            // Marks beyond the zoom window must not bleed past the plot.
            .chartPlotStyle { $0.clipped() }
            .background(HorizontalPanCatcher(enabled: visibleLength != nil) { deltaX, width in
                guard let length = visibleLength, width > 0 else { return }
                // Fingers left (negative delta, natural scrolling) slide
                // the window toward later events.
                let shift = -Double(deltaX) / Double(width) * length
                scrollX = min(max(scrollX + shift, 0), fullLength - length)
            })
            .gesture(magnify)
    }

    /// The visible X window: everything unzoomed, the panned span zoomed.
    private var xDomain: ClosedRange<Double> {
        guard let length = visibleLength else { return 0...fullLength }
        let lo = min(max(scrollX, 0), max(fullLength - length, 0))
        return lo...(lo + length)
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let current = visibleLength ?? fullLength
                if pinchBase == nil {
                    let anchorFraction = min(max(Double(value.startAnchor.x), 0), 1)
                    let start = visibleLength == nil ? 0 : scrollX
                    pinchBase = (current, start + anchorFraction * current, anchorFraction)
                }
                guard let base = pinchBase else { return }
                let magnification = max(Double(value.magnification), 0.01)
                let proposed = base.length / magnification
                // Zooming out to (almost) everything snaps cleanly back to
                // the unzoomed chart instead of leaving a 2% crumb.
                if proposed >= fullLength * 0.98 {
                    visibleLength = nil
                    scrollX = 0
                    return
                }
                let length = max(proposed, Self.minVisible)
                visibleLength = length
                scrollX = min(max(base.anchorData - base.anchorFraction * length, 0),
                              fullLength - length)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private var chartCore: some View {
        let ceiling = max(totals.last ?? 0, measure == .cost ? 0.01 : 1)
        let totalIndices = thinned(240)
        let modelIndices = thinned(120)
        let section = hoveredSection
        let focused = hoveredModel.flatMap { name in
            visibleModels.first { $0.model == name }
        }
        return Chart {
            // Model curves under the total; the focused one drawn last so it
            // rides on top of its dimmed peers.
            ForEach(drawOrder(visibleModels)) { series in
                if let values = series.values(measure) {
                    let color = colors[series.model] ?? .gray
                    if hoveredModel == series.model {
                        ForEach(modelIndices, id: \.self) { index in
                            AreaMark(
                                x: .value("Message", Double(index)),
                                yStart: .value("Value", 0),
                                yEnd: .value("Value", values[index]))
                            .foregroundStyle(color.opacity(0.15))
                            .interpolationMethod(.monotone)
                        }
                    }
                    ForEach(modelIndices, id: \.self) { index in
                        LineMark(
                            x: .value("Message", Double(index)),
                            y: .value("Value", values[index]),
                            series: .value("Series", series.model))
                        .foregroundStyle(color.opacity(lineOpacity(series.model)))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .interpolationMethod(.monotone)
                    }
                }
            }
            if hoveredModel == nil {
                ForEach(totalIndices, id: \.self) { index in
                    AreaMark(
                        x: .value("Message", Double(index)),
                        yStart: .value("Value", 0),
                        yEnd: .value("Value", totals[index]))
                    .foregroundStyle(
                        .linearGradient(
                            colors: [accent.opacity(0.28), accent.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                }
            }
            ForEach(totalIndices, id: \.self) { index in
                LineMark(
                    x: .value("Message", Double(index)),
                    y: .value("Value", totals[index]),
                    series: .value("Series", "total"))
                .foregroundStyle(accent.opacity(hoveredModel == nil ? 1 : 0.3))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
            }
            // The context overlay: each call's window share, scaled to the
            // plot ceiling (full context = data ceiling) so it reads in both
            // measures. A sawtooth by nature — it climbs within a stretch
            // and falls where the context reset. Dashed neutral, never a
            // model color: it's a gauge, not a spend series.
            if showContext, hasContext {
                ForEach(totalIndices, id: \.self) { index in
                    LineMark(
                        x: .value("Message", Double(index)),
                        y: .value("Value", model.contextFraction[index] * ceiling),
                        series: .value("Series", "context"))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .interpolationMethod(.monotone)
                }
                if let tip = model.contextFraction.last {
                    PointMark(
                        x: .value("Message", Double(count - 1)),
                        y: .value("Value", tip * ceiling))
                    .symbolSize(0)
                    .annotation(
                        position: .top, alignment: .center, spacing: 2,
                        overflowResolution: .init(x: .fit(to: .plot), y: .disabled)
                    ) {
                        Text("context \(Int((tip * 100).rounded()))%")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // Every prompt stands as a vertical line — where the user steered.
            // Dense sessions fade them toward texture instead of clutter.
            ForEach(model.promptRows, id: \.self) { prompt in
                RuleMark(
                    x: .value("Message", Double(prompt)),
                    yStart: .value("Value", 0), yEnd: .value("Value", ceiling))
                .foregroundStyle(accent.opacity(promptLineOpacity))
                .lineStyle(StrokeStyle(lineWidth: 1))
            }
            // Compactions in the meter chart's reset idiom — dashed primary,
            // the same semantic (a context window reset), never accent.
            ForEach(model.compactionRows, id: \.self) { compaction in
                RuleMark(
                    x: .value("Message", Double(compaction)),
                    yStart: .value("Value", 0), yEnd: .value("Value", ceiling))
                .foregroundStyle(Color.primary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            // Section hover: curtains dim everything outside the prompt's
            // stretch — the undimmed span IS the highlight (meter idiom) —
            // while the prompt's own line goes full strength and the
            // section's subtotal rides the headroom band.
            if let section {
                let curtain = Color(nsColor: .windowBackgroundColor).opacity(0.5)
                let endX = Double(min(section.endRow, count - 1))
                if section.promptRow > 0 {
                    RectangleMark(
                        xStart: .value("Message", 0.0),
                        xEnd: .value("Message", Double(section.promptRow)),
                        yStart: .value("Value", 0), yEnd: .value("Value", ceiling))
                    .foregroundStyle(curtain)
                }
                if endX < Double(count - 1) {
                    RectangleMark(
                        xStart: .value("Message", endX),
                        xEnd: .value("Message", Double(count - 1)),
                        yStart: .value("Value", 0), yEnd: .value("Value", ceiling))
                    .foregroundStyle(curtain)
                }
                RuleMark(
                    x: .value("Message", Double(section.promptRow)),
                    yStart: .value("Value", 0), yEnd: .value("Value", ceiling))
                .foregroundStyle(accent)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                PointMark(
                    x: .value("Message", (Double(section.promptRow) + endX) / 2),
                    y: .value("Value", ceiling))
                .symbolSize(0)
                .annotation(
                    position: .top, alignment: .center, spacing: 2,
                    overflowResolution: .init(x: .fit(to: .plot), y: .disabled)
                ) {
                    Text("+\(format(section.value(measure)))")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(accent)
                        .monospacedDigit()
                }
            }
            // The focused model's name at its curve tip — the chart-side echo
            // of the breakdown grid's row highlight.
            if let focused, let values = focused.values(measure), let tip = values.last {
                PointMark(
                    x: .value("Message", Double(count - 1)),
                    y: .value("Value", tip))
                .symbolSize(0)
                .annotation(
                    position: .top, alignment: .center, spacing: 2,
                    overflowResolution: .init(x: .fit(to: .plot), y: .disabled)
                ) {
                    Text(ModelNames.display(focused.model))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(colors[focused.model] ?? .gray)
                }
            }
            // Plain hover: crosshair + a dot on the read series at that row —
            // the focused model's curve when one is lit, the total otherwise.
            if section == nil, let row = hoveredRow, totals.indices.contains(row) {
                RuleMark(
                    x: .value("Message", Double(row)),
                    yStart: .value("Value", 0), yEnd: .value("Value", ceiling))
                .foregroundStyle(.quaternary)
                if let focused, let values = focused.values(measure) {
                    PointMark(
                        x: .value("Message", Double(row)),
                        y: .value("Value", values[row]))
                    .foregroundStyle(colors[focused.model] ?? .gray)
                    .symbolSize(30)
                } else {
                    PointMark(
                        x: .value("Message", Double(row)),
                        y: .value("Value", totals[row]))
                    .foregroundStyle(accent)
                    .symbolSize(30)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...ceiling * 1.15)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, ceiling / 2, ceiling]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let raw = value.as(Double.self), raw > 0 {
                        // One fixed label width in both measures — a measure
                        // flip must never resize the plot (meter-chart rule).
                        Text(axisLabel(raw))
                            .font(.caption2)
                            .lineLimit(1)
                            .frame(width: 44, alignment: .leading)
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
                            hover(at: location, proxy: proxy, geo: geo)
                        case .ended:
                            if hoveredRow == chartHoverRow { hoveredRow = nil }
                            chartHoverRow = nil
                            hoveredModel = nil
                        }
                    }
                    .onTapGesture { location in
                        if let row = rowAt(location, proxy: proxy, geo: geo) {
                            onSelectRow(row)
                        }
                    }
            }
        }
    }

    private var promptLineOpacity: Double {
        let count = model.promptRows.count
        return count > 60 ? 0.15 : count > 20 ? 0.25 : 0.35
    }

    private func axisLabel(_ value: Double) -> String {
        measure == .cost ? UsageFormatting.money(value) : TokenFormat.compact(Int(value))
    }

    /// Unfocused curves first, the focused one last (drawn on top).
    private func drawOrder(
        _ series: [SessionChartModel.ModelSeries]
    ) -> [SessionChartModel.ModelSeries] {
        guard let hoveredModel else { return series }
        return series.filter { $0.model != hoveredModel }
            + series.filter { $0.model == hoveredModel }
    }

    private func lineOpacity(_ model: String) -> Double {
        guard let hoveredModel else { return 0.55 }
        return model == hoveredModel ? 1 : 0.15
    }

    /// Mark indices for one series: every row up to `target`, strided beyond
    /// it, always ending on the last row. Hover reads the FULL arrays, so
    /// thinning only shapes the drawing.
    private func thinned(_ target: Int) -> [Int] {
        guard count > target else { return Array(0..<count) }
        let stride = Double(count - 1) / Double(target - 1)
        var indices: [Int] = []
        for step in 0..<target {
            let index = Int((Double(step) * stride).rounded())
            if indices.last != index { indices.append(index) }
        }
        if indices.last != count - 1 { indices.append(count - 1) }
        return indices
    }

    // MARK: - Hover

    private func hover(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let plot = geo[plotFrame]
        guard let xValue = proxy.value(atX: location.x - plot.origin.x, as: Double.self)
        else { return }
        let row = max(0, min(count - 1, Int(xValue.rounded())))
        // A prompt line within grabbing distance (~4pt of track) takes the
        // hover; its section lights instead of the point readout.
        if let prompt = nearestPrompt(to: xValue, plotWidth: plot.width) {
            if hoveredRow != prompt { hoveredRow = prompt }
            chartHoverRow = prompt
            if hoveredModel != nil { hoveredModel = nil }
            return
        }
        if hoveredRow != row { hoveredRow = row }
        chartHoverRow = row
        updateModelFocus(at: row, locationY: location.y - plot.origin.y, proxy: proxy)
    }

    private func nearestPrompt(to xValue: Double, plotWidth: CGFloat) -> Int? {
        guard !model.promptRows.isEmpty, plotWidth > 0 else { return nil }
        let tolerance = max(0.5, Double(count - 1) * 4 / Double(plotWidth))
        return model.promptRows
            .min { abs(Double($0) - xValue) < abs(Double($1) - xValue) }
            .flatMap { abs(Double($0) - xValue) <= tolerance ? $0 : nil }
    }

    /// Curve focus by pixel proximity: the model curve whose value at this row
    /// sits nearest the cursor's height wins within a grab distance — shared
    /// through `hoveredModel`, so the breakdown grid's row lights with it.
    private func updateModelFocus(at row: Int, locationY: CGFloat, proxy: ChartProxy) {
        var best: (model: String, distance: CGFloat)?
        for series in visibleModels {
            guard let values = series.values(measure), values.indices.contains(row),
                  let y = proxy.position(forY: values[row])
            else { continue }
            let distance = abs(y - locationY)
            if best == nil || distance < best!.distance {
                best = (series.model, distance)
            }
        }
        let hit = (best?.distance ?? .infinity) <= 8 ? best?.model : nil
        if hoveredModel != hit { hoveredModel = hit }
    }

    private func rowAt(_ location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> Int? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let plot = geo[plotFrame]
        guard let xValue = proxy.value(atX: location.x - plot.origin.x, as: Double.self)
        else { return nil }
        if let prompt = nearestPrompt(to: xValue, plotWidth: plot.width) { return prompt }
        return max(0, min(count - 1, Int(xValue.rounded())))
    }
}

/// The whole session compressed into a strip above the zoomed chart: the
/// total curve as a hairline and a viewport box marking how much is visible
/// and where. Grab semantics, like a scrollbar thumb: pressing anywhere
/// GRABS the viewport where it currently sits and dragging scrubs it
/// relatively — it never teleports to the pointer, and a plain click moves
/// nothing. Hover lights the strip and shows the open hand; scrubbing, the
/// closed one.
private struct ChartMinimap: View {
    let values: [Double]
    /// Viewport geometry as fractions of the whole session.
    let viewportStart: Double
    let viewportWidth: Double
    let accent: Color
    /// Reports the dragged viewport START fraction (unclamped); the chart
    /// clamps against its own length and applies.
    var onScrub: (Double) -> Void

    @State private var hovering = false
    /// The viewport's start fraction captured at grab; non-nil while
    /// scrubbing — it anchors the relative drag and closes the hand cursor.
    @State private var grabbedStart: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let lit = hovering || grabbedStart != nil
            let boxWidth = max(viewportWidth * width, 14)
            let boxX = min(max(viewportStart * width, 0), max(width - boxWidth, 0))
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    guard values.count > 1, let peak = values.max(), peak > 0
                    else { return }
                    var path = Path()
                    for (index, value) in values.enumerated() {
                        let x = size.width * Double(index) / Double(values.count - 1)
                        let y = size.height - (value / peak) * (size.height - 3) - 1.5
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    context.stroke(
                        path, with: .color(accent.opacity(0.5)), lineWidth: 1)
                }
                // The highlight lives on the GRABBER alone — hovering
                // anywhere on the strip lights the box you'd be grabbing
                // (its frame goes full primary: white in dark mode), while
                // the track and hairline hold still.
                RoundedRectangle(cornerRadius: 3)
                    .fill(accent.opacity(lit ? 0.22 : 0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(
                                lit ? AnyShapeStyle(.primary)
                                    : AnyShapeStyle(accent.opacity(0.6)),
                                lineWidth: 1))
                    .frame(width: boxWidth)
                    .offset(x: boxX)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard width > 0 else { return }
                        let anchor = grabbedStart ?? viewportStart
                        if grabbedStart == nil { grabbedStart = viewportStart }
                        onScrub(anchor + drag.translation.width / width)
                    }
                    .onEnded { _ in grabbedStart = nil })
        }
        .pointerStyle(grabbedStart != nil ? .grabActive : .grabIdle)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 3))
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
