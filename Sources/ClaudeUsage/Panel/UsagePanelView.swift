import Charts
import SwiftUI
import UsageCore

struct UsagePanelView: View {
    var store: UsageStore
    /// Wired by StatusItemController: closes the panel, opens the window.
    let onOpenSettings: () -> Void
    /// Coordinate space the row-frame preferences are measured in — the same
    /// view the shared popover attaches to, so its anchor rects line up.
    static let panelSpace = "usage-panel"

    /// The one meter (by id) whose popover is up. A single popover(item:)
    /// hosted here presents it: per-row popover modifiers raced each other
    /// on switches — dismissing A while presenting B — and when the new
    /// presentation lost, SwiftUI wrote false back through the binding and
    /// nothing stayed open.
    @State private var openMeter: String?
    /// The meter (by id) the cursor is currently over, if any.
    @State private var hoveredMeter: String?
    @State private var hoveringPopover = false
    @State private var meterFrames: [String: CGRect] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            errorBlock
            content
            statusRow
            Divider()
            HeatmapView(activity: store.activity, pricing: store.pricing)
            footer
        }
        .padding(14)
        // Wide enough that the breakdown grid never truncates model names.
        .frame(width: 360)
        .coordinateSpace(name: Self.panelSpace)
        .onPreferenceChange(MeterFramePreference.self) { meterFrames = $0 }
        .popover(
            item: openSelection, attachmentAnchor: openAnchor, arrowEdge: .trailing
        ) { meter in
            MeterHistoryView(
                meter: meter, samples: store.samples,
                timeline: store.tokenTimeline, pricing: store.pricing,
                prediction: store.predictions[meter.label])
                .onHover { inside in
                    hoveringPopover = inside
                    if !inside { scheduleHideIfLeft() }
                }
        }
        .onAppear { store.scanActivity() }
    }

    /// The shared popover's item. Resolving through the live snapshot keeps
    /// the content current across refreshes (Meter.id is positional and
    /// stable), and a meter vanishing from the API dismisses cleanly.
    private var openSelection: Binding<Meter?> {
        Binding(
            get: {
                guard let openMeter else { return nil }
                return store.state.snapshot?.meters.first { $0.id == openMeter }
            },
            set: { openMeter = $0?.id })
    }

    private var openAnchor: PopoverAttachmentAnchor {
        if let openMeter, let frame = meterFrames[openMeter] {
            return .rect(.rect(frame))
        }
        return .rect(.bounds)
    }

    /// The leave grace: close only once the cursor has settled on neither a
    /// meter row nor the popover — travelling between them never drops it.
    private func scheduleHideIfLeft() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            if hoveredMeter == nil && !hoveringPopover { openMeter = nil }
        }
    }

    /// Failures lead the panel: with no title row above them anymore, an
    /// error and its hint are the first thing the eye lands on.
    @ViewBuilder private var errorBlock: some View {
        if let error = store.state.error {
            VStack(alignment: .leading, spacing: 2) {
                Text(error.shortText)
                    .font(.caption)
                    .foregroundStyle(store.state.snapshot == nil ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                if let hint = error.hint {
                    Text(hint).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Pipeline state right under the meters it describes — fetch time,
    /// next-poll countdown, budget gauge — with the plan label flushed to
    /// the opposite end of the same line.
    @ViewBuilder private var statusRow: some View {
        if store.state.snapshot != nil || store.nextRefreshAt != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    statusLine(now: context.date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let plan = store.state.snapshot?.plan?.displayLabel {
                    Text(plan)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch store.state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.callout).foregroundStyle(.secondary)
            }
        case .live(let snapshot), .cached(let snapshot, _):
            ForEach(snapshot.meters) { meter in
                MeterRow(
                    meter: meter,
                    stale: store.state.isStale,
                    prediction: store.predictions[meter.label],
                    openMeter: $openMeter,
                    hoveredMeter: $hoveredMeter,
                    onLeave: scheduleHideIfLeft)
            }
            if snapshot.meters.isEmpty {
                Text("No limits reported").font(.callout).foregroundStyle(.secondary)
            }
            if let spend = snapshot.spendLine {
                Divider()
                HStack {
                    Text("Credits").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(spend.formatted).font(.caption.monospacedDigit())
                }
            }
        case .unavailable:
            EmptyView() // the error block up top already shows the error + hint
        }
    }

    @ViewBuilder private var footer: some View {
        Divider()
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Claude Usage")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("v\(AppIdentity.version)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                store.refresh(.manual)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(refreshPressureStyle)
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .help(refreshHelp)

            Link(destination: URL(string: "https://claude.ai/settings/usage")!) {
                Image(systemName: "arrow.up.right.square")
            }
            .help("Open claude.ai usage settings")

            Menu {
                Picker("Refresh when active", selection: SettingsBindings.interval(store)) {
                    ForEach(
                        SettingsBindings.menuIntervalChoices(current: store.activeInterval),
                        id: \.self
                    ) { seconds in
                        Text(UsageFormatting.duration(seconds)).tag(seconds)
                    }
                }
                Toggle("Launch at login", isOn: SettingsBindings.launchAtLogin())
                Divider()
                Button("Settings…") { onOpenSettings() }
                Button("Quit Claude Usage") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            // .button + borderless renders the bare icon; the default menu
            // style wraps it in a bordered pull-down pill.
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func statusLine(now: Date) -> Text {
        var parts: [Text] = []
        if let fetchedAt = store.state.snapshot?.fetchedAt {
            let stamp = UsageFormatting.clockTime(fetchedAt)
            // The stale badge lives here now that there's no header for it.
            parts.append(
                store.state.isStale
                    ? Text("cached \(stamp)").foregroundStyle(.orange)
                    : Text("Updated \(stamp)"))
        }
        if let next = store.nextRefreshAt {
            parts.append(Text(UsageFormatting.countdownText(to: next, now: now)))
        }
        // Why "next in 20m" instead of 5: quiet decayed the cadence. Activity
        // (or usage moving) snaps it back — worth a word of transparency.
        let pace = store.paceMultiplier(now: now)
        if pace > 1 { parts.append(Text("idle ×\(pace)")) }
        // Surface the API budget only once it's half spent — quiet otherwise.
        let budget = store.apiBudget(now: now)
        if budget.fraction >= 0.5 { parts.append(Text("API \(budget.used)/\(budget.ceiling)h")) }
        guard var line = parts.first else { return Text("") }
        for part in parts.dropFirst() { line = line + Text(" · ") + part }
        return line
    }

    /// Orange once the hour's requests reach 80% of the estimated budget,
    /// red at or past it — the warning lives on the button that spends it.
    private var refreshPressureStyle: AnyShapeStyle {
        let fraction = store.apiBudget(now: Date()).fraction
        if fraction >= 1 { return AnyShapeStyle(.red) }
        if fraction >= 0.8 { return AnyShapeStyle(.orange) }
        return AnyShapeStyle(.tint)
    }

    private var refreshHelp: String {
        let budget = store.apiBudget(now: Date())
        var text = "Refresh now (at most once per 3 minutes)"
        if budget.fraction >= 0.8 {
            text += " — \(budget.used) of ~\(budget.ceiling) hourly requests used; more may trip the API's rate limit"
        }
        return text
    }

}

/// Rows report their frames (in UsagePanelView.panelSpace) so the shared
/// popover can anchor to whichever row is open.
private struct MeterFramePreference: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct MeterRow: View {
    let meter: Meter
    let stale: Bool
    let prediction: UsagePrediction?

    /// Panel-wide single-popover authority and hover tracker, owned by
    /// UsagePanelView — which also hosts the one shared popover.
    @Binding var openMeter: String?
    @Binding var hoveredMeter: String?
    /// Panel-owned leave grace (cursor on neither a row nor the popover).
    let onLeave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.label).font(.callout)
                Spacer()
                Text(meter.percent.map { "\($0)%" } ?? "—")
                    .font(.callout.monospacedDigit().bold())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    if let percent = meter.percent, percent > 0 {
                        Capsule()
                            .fill(barColor)
                            .frame(width: max(4, geo.size.width * CGFloat(percent) / 100))
                    }
                }
            }
            .frame(height: 5)
            captionLine.font(.caption2)
        }
        // The highlight bleeds a little past the content into the panel
        // padding, menu-item style; the negative padding hands the space
        // back so the panel layout doesn't shift.
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(lit ? 0.07 : 0)))
        .background(GeometryReader { geo in
            Color.clear.preference(
                key: MeterFramePreference.self,
                value: [meter.id: geo.frame(in: .named(UsagePanelView.panelSpace))])
        })
        .padding(.vertical, -5)
        .padding(.horizontal, -7)
        // Menu-style lifecycle: the first open waits out a brief dwell so a
        // cursor merely passing through never pops anything (a click skips
        // the dwell), but while any popover is up, hovering a sibling row
        // switches to it instantly. Hiding is the panel's leave grace.
        .onHover { inside in
            if inside {
                hoveredMeter = meter.id
                if openMeter != nil {
                    openMeter = meter.id
                } else {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(120))
                        if hoveredMeter == meter.id && openMeter == nil {
                            openMeter = meter.id
                        }
                    }
                }
            } else {
                if hoveredMeter == meter.id { hoveredMeter = nil }
                onLeave()
            }
        }
        .onTapGesture { openMeter = meter.id }
    }

    /// Hover indicator — also stays lit while this row's popover is up, so
    /// the open popover visibly belongs to its row.
    private var lit: Bool {
        hoveredMeter == meter.id || openMeter == meter.id
    }

    /// "resets in 3h 20m · on track — proj. 35% at reset", burn part colored
    /// by its verdict (green / yellow / red). Before enough samples exist
    /// (two readings ≥5 min apart) the burn slot says it's measuring.
    private var captionLine: Text {
        var parts: [Text] = []
        if let resetsAt = meter.resetsAt {
            parts.append(
                Text(UsageFormatting.resetText(resetsAt, now: Date()))
                    .foregroundStyle(.secondary))
        }
        if let prediction {
            parts.append(Text(prediction.text).foregroundStyle(burnColor(prediction.verdict)))
        } else if meter.percent != nil && !stale {
            parts.append(Text("measuring rate…").foregroundStyle(.tertiary))
        }
        guard var line = parts.first else { return Text("") }
        for part in parts.dropFirst() {
            line = line + Text(" · ").foregroundStyle(.secondary) + part
        }
        return line
    }

    private func burnColor(_ verdict: UsagePrediction.Verdict) -> Color {
        switch verdict {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        }
    }

    private var barColor: Color {
        if stale { return Color(nsColor: .secondaryLabelColor) }
        switch meter.level {
        case .normal: return Color(nsColor: .controlAccentColor)
        case .warning: return .orange
        case .critical: return .red
        }
    }
}


/// Per-limit history and forecast: the meter's sampled percent overlaid with
/// every model's cumulative token curve (normalized to the plot height), in
/// either a sliding trailing window or the limit window start-to-reset — the
/// latter with a now-notch separating measured from predicted, and the
/// prediction engine's dashed trajectory to the reset. The breakdown table
/// doubles as a legend: hovering a curve or its row focuses the pair and
/// dims the rest — one `focusedModel` drives both surfaces, so they can
/// never disagree.
struct MeterHistoryView: View {
    let meter: Meter
    let samples: [UsageSample]
    let timeline: [TokenSlot]
    let pricing: PricingTable
    let prediction: UsagePrediction?

    /// One-word span choices: a trailing window ending now, or the limit
    /// window itself, start to reset.
    enum Span: String, CaseIterable {
        case sliding = "Sliding"
        case window = "Window"
    }

    /// The span choice, remembered per meter across popover dismissals and
    /// relaunches — the single shared popover would otherwise leak one
    /// meter's choice onto the next while sweeping rows.
    @AppStorage private var span: Span
    @State private var hoverDate: Date?
    /// The focused model — set by hovering its curve or its legend row.
    @State private var focusedModel: String?
    /// The activity-strip nub under the cursor, if any.
    @State private var hoveredSegment: ActivitySegment?

    init(
        meter: Meter, samples: [UsageSample], timeline: [TokenSlot],
        pricing: PricingTable, prediction: UsagePrediction?
    ) {
        self.meter = meter
        self.samples = samples
        self.timeline = timeline
        self.pricing = pricing
        self.prediction = prediction
        _span = AppStorage(wrappedValue: .sliding, "meterPopoverSpan-\(meter.id)")
    }

    private static let chartWidth: CGFloat = 300
    private static let chartHeight: CGFloat = 110
    private static let weekdayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()

    private var window: TimeInterval { meter.rank == 0 ? 5 * 3600 : 7 * 86400 }
    private var orange: Color { Color(nsColor: StatusItemRenderer.claudeOrange) }

    /// A live future reset unlocks the Window span; without one (stale data,
    /// missing reset) the picker hides and the view stays sliding.
    private var liveReset: Date? {
        meter.resetsAt.flatMap { $0 > Date() ? $0 : nil }
    }

    private var effectiveSpan: Span { liveReset == nil ? .sliding : span }

    private var domain: (start: Date, end: Date) {
        if effectiveSpan == .window, let reset = liveReset {
            return (reset.addingTimeInterval(-window), reset)
        }
        let now = Date()
        return (now.addingTimeInterval(-window), now)
    }

    private var spanLabel: String {
        switch effectiveSpan {
        case .window: meter.rank == 0 ? "this session" : "this week"
        case .sliding: meter.rank == 0 ? "last 5h" : "last 7 days"
        }
    }

    private struct Point: Identifiable {
        let id: TimeInterval
        let t: Date
        let percent: Int
    }

    private var points: [Point] {
        let (start, end) = domain
        let measuredEnd = min(end, Date())
        return samples
            .filter { $0.t >= start && $0.t <= measuredEnd }
            .compactMap { sample in
                sample.percents[meter.label].map {
                    Point(id: sample.t.timeIntervalSince1970, t: sample.t, percent: $0)
                }
            }
    }

    /// This window's per-model usage, scoped for scoped meters — the rows of
    /// the shared table and the curves the chart overlays.
    private var windowRows: [ModelTokenUsage] {
        let all = WindowTokens.breakdown(timeline: timeline, from: domain.start, to: Date())
        return scopeName.map { WindowTokens.scoped(all, name: $0) } ?? all
    }

    /// One model's cumulative curve, normalized so the busiest model's total
    /// spans the plot — magnitudes stay comparable between models while
    /// sharing the percent chart's 0...100 canvas.
    private struct ModelCurve {
        let model: String
        let color: Color
        let points: [(t: Date, normalized: Double)]
    }

    var body: some View {
        let rows = windowRows
        let colors = ModelPalette.assignment(for: rows.map(\.model))
        let curves = modelCurves(rows: rows, colors: colors)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.label).font(.caption.bold())
                Spacer()
                if liveReset != nil {
                    Picker("Span", selection: $span) {
                        ForEach(Span.allCases, id: \.self) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Text(spanLabel).font(.caption2).foregroundStyle(.secondary)
                }
            }
            // Fixed-height stats line: window totals normally, the focused
            // model's share while a curve/row pair is lit. Never reflows.
            HStack(spacing: 5) {
                if let focusedModel {
                    Circle()
                        .fill(colors[focusedModel] ?? .gray)
                        .frame(width: 6, height: 6)
                }
                Text(statsText(rows: rows))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 14)
            if points.count < 2 && curves.isEmpty {
                Text("Collecting samples — this fills in as refreshes accumulate.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.chartWidth, height: Self.chartHeight)
            } else {
                // The 30s tick keeps the now-notch sliding and the sliding
                // domain honest while the popover stays open.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    chart(curves: curves, now: context.date)
                }
            }
            domainLabels
            Text(segmentReadout ?? readout.map(readoutText) ?? hoverHint)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(readout == nil && segmentReadout == nil
                    ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .frame(height: 14, alignment: .leading)
            Divider()
            if rows.isEmpty {
                Text("No local token data in this window.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ModelBreakdownGrid(
                    rows: rows, colors: colors, pricing: pricing,
                    hoveredModel: $focusedModel)
            }
            Text("Local Claude Code sessions on this Mac only.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        // Meter switches reuse this view (single shared popover) — hover
        // state must not leak across.
        .onChange(of: meter.id) {
            hoverDate = nil
            focusedModel = nil
            hoveredSegment = nil
        }
    }

    // MARK: - Chart

    private func chart(curves: [ModelCurve], now: Date) -> some View {
        let (start, end) = domain
        let measuredEnd = min(end, now)
        let segments = activitySegments(now: now)
        return Chart {
            // Activity strip, iStat-style: a band under the plot floor —
            // orange where transcripts logged tokens, a faint track where
            // they didn't. Future (right of now) stays empty.
            RectangleMark(
                xStart: .value("Time", start), xEnd: .value("Time", measuredEnd),
                yStart: .value("Usage", Self.stripBottom),
                yEnd: .value("Usage", Self.stripTop))
            .foregroundStyle(Color.primary.opacity(0.08))
            ForEach(segments, id: \.start) { segment in
                RectangleMark(
                    xStart: .value("Time", segment.start), xEnd: .value("Time", segment.end),
                    yStart: .value("Usage", Self.stripBottom),
                    yEnd: .value("Usage", Self.stripTop))
                .foregroundStyle(orange.opacity(hoveredSegment == segment ? 1 : 0.7))
            }
            // Hovering a nub lifts its whole time slice out of the graph.
            if let hoveredSegment {
                RectangleMark(
                    xStart: .value("Time", hoveredSegment.start),
                    xEnd: .value("Time", hoveredSegment.end),
                    yStart: .value("Usage", 0), yEnd: .value("Usage", 100))
                .foregroundStyle(orange.opacity(0.08))
            }
            // Model curves underlay the percent line; the focused one draws
            // last so its full-opacity line sits on top of its dimmed peers.
            ForEach(drawOrder(curves), id: \.model) { curve in
                if focusedModel == curve.model {
                    ForEach(curve.points, id: \.t) { point in
                        AreaMark(
                            x: .value("Time", point.t),
                            yStart: .value("Usage", 0),
                            yEnd: .value("Usage", point.normalized))
                        .foregroundStyle(curve.color.opacity(0.15))
                        .interpolationMethod(.monotone)
                    }
                }
                ForEach(curve.points, id: \.t) { point in
                    LineMark(
                        x: .value("Time", point.t),
                        y: .value("Usage", point.normalized),
                        series: .value("Series", curve.model))
                    .foregroundStyle(curve.color.opacity(lineOpacity(curve.model)))
                    .interpolationMethod(.monotone)
                }
            }
            if focusedModel == nil {
                ForEach(points) { point in
                    AreaMark(
                        x: .value("Time", point.t),
                        yStart: .value("Usage", 0),
                        yEnd: .value("Usage", Double(point.percent)))
                    .foregroundStyle(orange.opacity(0.18))
                    .interpolationMethod(.monotone)
                }
            }
            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.t),
                    y: .value("Usage", Double(point.percent)),
                    series: .value("Series", "percent"))
                .foregroundStyle(orange.opacity(focusedModel == nil ? 1 : 0.3))
                .interpolationMethod(.monotone)
            }
            if effectiveSpan == .window {
                // The prediction engine's trajectory: dashed, measured side
                // of the notch left alone.
                if let prediction, prediction.curve.count >= 2 {
                    ForEach(prediction.curve, id: \.t) { point in
                        LineMark(
                            x: .value("Time", point.t),
                            y: .value("Usage", point.percent),
                            series: .value("Series", "prediction"))
                        .foregroundStyle(orange.opacity(focusedModel == nil ? 0.8 : 0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
                // The now-notch: everything left is measured, right is ahead.
                RuleMark(x: .value("Now", now))
                    .foregroundStyle(.tertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .center) {
                        Text("now").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                // Where the current pace hits the limit: a red mark with the
                // time it happens; the hatched region beyond it is unusable.
                if let exhaust = exhaustDate {
                    RuleMark(x: .value("Exhausted", exhaust))
                        .foregroundStyle(.red.opacity(0.75))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(
                            position: .bottom, alignment: .center, spacing: 1,
                            overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))
                        ) {
                            // Only while exploring the dead zone — always-on
                            // it crowded the axis labels below the plot.
                            if hoverDate.map({ $0 >= exhaust }) == true {
                                Text(timeLabel(exhaust))
                                    .font(.system(size: 8))
                                    .foregroundStyle(.red)
                            }
                        }
                }
            }
            if let readout {
                RuleMark(x: .value("Time", readout.t))
                    .foregroundStyle(.quaternary)
                PointMark(
                    x: .value("Time", readout.t),
                    y: .value("Usage", Double(readout.percent)))
                .foregroundStyle(orange.opacity(readout.predicted ? 0.8 : 1))
                .symbolSize(30)
            }
        }
        .chartYScale(domain: Self.stripBottom - 1...100)
        .chartYAxis { AxisMarks(values: [0, 50, 100]) }
        .chartXScale(domain: start...end)
        // Diagonal hatching over the unreachable region — the limit is spent
        // before the window ends, so everything past the crossing is dead
        // time. Drawn behind the marks so curves stay crisp over it.
        .chartBackground { proxy in
            GeometryReader { geo in
                if let exhaust = exhaustDate,
                   let plotFrame = proxy.plotFrame,
                   let xStart = proxy.position(forX: exhaust),
                   let yTop = proxy.position(forY: 100),
                   let yBottom = proxy.position(forY: 0) {
                    let plot = geo[plotFrame]
                    let region = CGRect(
                        x: plot.minX + xStart, y: plot.minY + yTop,
                        width: max(0, plot.width - xStart), height: yBottom - yTop)
                    Canvas { context, _ in
                        context.clip(to: Path(region))
                        context.fill(Path(region), with: .color(.red.opacity(0.05)))
                        var x = region.minX - region.height
                        while x < region.maxX {
                            var stripe = Path()
                            stripe.move(to: CGPoint(x: x, y: region.maxY))
                            stripe.addLine(to: CGPoint(x: x + region.height, y: region.minY))
                            context.stroke(stripe, with: .color(.red.opacity(0.13)), lineWidth: 1)
                            x += 6
                        }
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
                            guard let plotFrame = proxy.plotFrame else { return }
                            let origin = geo[plotFrame].origin
                            let date = proxy.value(atX: location.x - origin.x, as: Date.self)
                            let yValue = proxy.value(atY: location.y - origin.y, as: Double.self)
                            hoverDate = date
                            // Below the plot floor the cursor is on the
                            // activity strip: nubs take the hover there,
                            // curves let go.
                            if let yValue, yValue < 0 {
                                let hit = date.flatMap { d in
                                    segments.first { $0.start <= d && d <= $0.end }
                                }
                                if hoveredSegment != hit { hoveredSegment = hit }
                                if focusedModel != nil { focusedModel = nil }
                            } else {
                                if hoveredSegment != nil { hoveredSegment = nil }
                                updateFocus(at: date, yValue: yValue, curves: curves)
                            }
                        case .ended:
                            hoverDate = nil
                            focusedModel = nil
                            hoveredSegment = nil
                        }
                    }
            }
        }
        .frame(width: Self.chartWidth, height: Self.chartHeight)
    }

    /// The activity strip's band, in chart-Y units below the plot floor.
    private static let stripBottom: Double = -7
    private static let stripTop: Double = -2

    /// The projected limit-crossing inside the Window span, if the current
    /// pace spends the meter before the window resets.
    private var exhaustDate: Date? {
        guard effectiveSpan == .window,
              let exhaust = prediction?.exhaustsAt,
              exhaust > domain.start, exhaust < domain.end
        else { return nil }
        return exhaust
    }

    private struct ActivitySegment: Equatable {
        let start: Date
        let end: Date
    }

    /// "Wed 09:15 – Wed 11:30 · active 2 hr 15 min" while a nub is hovered.
    private var segmentReadout: String? {
        hoveredSegment.map { segment in
            "\(timeLabel(segment.start)) – \(timeLabel(segment.end)) · active "
                + UsageFormatting.duration(segment.end.timeIntervalSince(segment.start))
        }
    }

    /// Contiguous stretches of the measured domain where transcripts logged
    /// tokens (scoped meters count only their own model), bucketed so a week
    /// of minute slots collapses to a handful of marks.
    private func activitySegments(now: Date) -> [ActivitySegment] {
        let start = domain.start
        let end = min(domain.end, now)
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return [] }
        let bucket = max(60, span / 120)
        let needle = scopeName?.lowercased()
        var active = Array(repeating: false, count: Int(span / bucket) + 1)
        for slot in timeline where slot.t >= start && slot.t <= end {
            if let needle, !slot.model.lowercased().contains(needle) { continue }
            let index = Int(slot.t.timeIntervalSince(start) / bucket)
            if active.indices.contains(index) { active[index] = true }
        }
        var segments: [ActivitySegment] = []
        var runStart: Int?
        for (index, isActive) in active.enumerated() {
            if isActive, runStart == nil { runStart = index }
            if !isActive, let run = runStart {
                segments.append(ActivitySegment(
                    start: start.addingTimeInterval(Double(run) * bucket),
                    end: start.addingTimeInterval(Double(index) * bucket)))
                runStart = nil
            }
        }
        if let run = runStart {
            segments.append(ActivitySegment(
                start: start.addingTimeInterval(Double(run) * bucket), end: end))
        }
        return segments
    }

    /// Unfocused curves first, the focused one last (drawn on top).
    private func drawOrder(_ curves: [ModelCurve]) -> [ModelCurve] {
        guard let focusedModel else { return curves }
        return curves.filter { $0.model != focusedModel }
            + curves.filter { $0.model == focusedModel }
    }

    private func lineOpacity(_ model: String) -> Double {
        guard let focusedModel else { return 0.55 }
        return model == focusedModel ? 1 : 0.15
    }

    /// Graph-side focus: the curve whose value at the cursor's time sits
    /// nearest the cursor's height wins, within a grab distance — otherwise
    /// the hover is about the percent line/whitespace and nothing focuses.
    private func updateFocus(at date: Date?, yValue: Double?, curves: [ModelCurve]) {
        guard let date, let yValue else { return }
        var best: (model: String, distance: Double)?
        for curve in curves {
            guard let value = interpolate(curve.points, at: date) else { continue }
            let distance = abs(value - yValue)
            if best == nil || distance < best!.distance {
                best = (curve.model, distance)
            }
        }
        let hit = (best?.distance ?? .infinity) <= 8 ? best?.model : nil
        if focusedModel != hit { focusedModel = hit }
    }

    private func interpolate(
        _ pts: [(t: Date, normalized: Double)], at date: Date
    ) -> Double? {
        guard let first = pts.first, let last = pts.last else { return nil }
        if date <= first.t { return first.normalized }
        if date >= last.t { return last.normalized }
        for (p0, p1) in zip(pts, pts.dropFirst()) where date <= p1.t {
            let span = p1.t.timeIntervalSince(p0.t)
            guard span > 0 else { return p1.normalized }
            let fraction = date.timeIntervalSince(p0.t) / span
            return p0.normalized + fraction * (p1.normalized - p0.normalized)
        }
        return last.normalized
    }

    private func modelCurves(
        rows: [ModelTokenUsage], colors: [String: Color]
    ) -> [ModelCurve] {
        let raw = rows.map { row in (model: row.model, curve: cumulativeCurve(model: row.model)) }
        let maxTotal = raw.compactMap { $0.curve.last?.total }.max() ?? 0
        guard maxTotal > 0 else { return [] }
        let norm = 100.0 / Double(maxTotal)
        return raw.map { entry in
            ModelCurve(
                model: entry.model,
                color: colors[entry.model] ?? .gray,
                points: entry.curve.map { ($0.t, Double($0.total) * norm) })
        }
    }

    /// Running total per ~180 buckets so a busy week doesn't hand Charts
    /// thousands of minute slots. Covers the measured part of the domain.
    private func cumulativeCurve(model: String) -> [(t: Date, total: Int)] {
        let start = domain.start
        let end = min(domain.end, Date())
        let bucket = max(60, end.timeIntervalSince(start) / 180)
        var curve: [(t: Date, total: Int)] = [(start, 0)]
        var total = 0
        var nextBoundary = start.addingTimeInterval(bucket)
        for slot in timeline where slot.model == model && slot.t >= start && slot.t <= end {
            if slot.t > nextBoundary {
                curve.append((nextBoundary, total))
                while nextBoundary < slot.t { nextBoundary.addTimeInterval(bucket) }
            }
            total += slot.tally.total
        }
        curve.append((end, total))
        return curve
    }

    // MARK: - Text lines

    /// "89.2M tokens this session", or the focused model's slice of it.
    private func statsText(rows: [ModelTokenUsage]) -> String {
        if let focusedModel, let row = rows.first(where: { $0.model == focusedModel }) {
            return "\(row.displayName) · \(TokenFormat.compact(row.tally.total)) tokens \(spanLabel)"
        }
        return "\(TokenFormat.compact(WindowTokens.total(rows).total)) tokens \(spanLabel)"
    }

    private var hoverHint: String {
        focusedModel.map { "\(ModelNames.display($0)) focused — others dimmed" }
            ?? "Hover the graph for point details"
    }

    /// Start and end of the visible domain under the chart — in Window span
    /// the end is the reset itself.
    private var domainLabels: some View {
        let (start, end) = domain
        return HStack {
            Text(timeLabel(start))
            Spacer()
            Text(effectiveSpan == .window ? "resets \(timeLabel(end))" : "now")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(width: Self.chartWidth)
    }

    private func timeLabel(_ date: Date) -> String {
        meter.rank == 0 ? UsageFormatting.clockTime(date) : Self.weekdayTime.string(from: date)
    }

    // MARK: - Hover readout

    /// A continuously-hoverable reading: measured percent is interpolated
    /// between the surrounding samples; right of the now-notch the value
    /// comes off the prediction curve and says so. Tokens attribute to the
    /// enclosing poll interval (measured side only).
    private struct Readout {
        let t: Date
        let percent: Int
        let from: Date?
        let to: Date?
        let predicted: Bool
    }

    private var readout: Readout? {
        // Point readouts belong to the percent/prediction lines; in focus
        // mode the stats line carries the numbers, and on the activity
        // strip the segment readout does.
        guard focusedModel == nil, hoveredSegment == nil, let hoverDate else { return nil }
        let now = Date()
        let (domainStart, domainEnd) = domain
        let t = min(max(hoverDate, domainStart), domainEnd)
        if effectiveSpan == .window, t > now {
            guard let prediction,
                  let projected = PredictionEngine.percent(onCurve: prediction.curve, at: t)
            else { return nil }
            return Readout(
                t: t, percent: Int(projected.rounded()), from: nil, to: nil, predicted: true)
        }
        let all = points
        guard let first = all.first, let last = all.last else { return nil }
        if t <= first.t {
            return Readout(t: t, percent: first.percent, from: nil, to: nil, predicted: false)
        }
        if t >= last.t {
            return Readout(t: t, percent: last.percent, from: last.t, to: t, predicted: false)
        }
        let index = all.lastIndex { $0.t <= t } ?? 0
        let p0 = all[index]
        let p1 = all[index + 1]
        let span = p1.t.timeIntervalSince(p0.t)
        let fraction = span > 0 ? t.timeIntervalSince(p0.t) / span : 0
        let percent = Double(p0.percent) + fraction * Double(p1.percent - p0.percent)
        return Readout(
            t: t, percent: Int(percent.rounded()), from: p0.t, to: p1.t, predicted: false)
    }

    /// "14:32 · 34% · 1.2M tokens · $3.40" measured; "16:05 · proj. 41%"
    /// beyond the notch.
    private func readoutText(_ readout: Readout) -> String {
        var parts = [UsageFormatting.clockTime(readout.t)]
        if readout.predicted {
            parts.append("proj. \(readout.percent)%")
            return parts.joined(separator: " · ")
        }
        parts.append("\(readout.percent)%")
        if let from = readout.from, let to = readout.to {
            let rows = WindowTokens.breakdown(
                timeline: timeline, from: from.addingTimeInterval(1), to: to)
            let total = WindowTokens.total(rows)
            if total.total > 0 {
                parts.append("\(TokenFormat.compact(total.total)) tokens")
                let dollars = rows
                    .compactMap { pricing.rates(for: $0.model)?.dollars(for: $0.tally) }
                    .reduce(0, +)
                if dollars > 0 { parts.append(UsageFormatting.money(dollars)) }
            }
        }
        return parts.joined(separator: " · ")
    }

    /// "Weekly · Fable" → "Fable": a scoped meter's breakdown shows only its
    /// own model's usage, never the whole timeline.
    private var scopeName: String? {
        guard meter.rank == 2, meter.label.hasPrefix("Weekly · ") else { return nil }
        return String(meter.label.dropFirst("Weekly · ".count))
    }
}
