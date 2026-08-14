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
    /// Clicking the red (budget-spent) reload button opens its explanation
    /// instead of refreshing.
    @State private var showRefreshBlocked = false

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
                    // A working link dressed as a plain caption: Link's tint
                    // shouted over the header, so the hand cursor and help
                    // tag carry the affordance instead of color.
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://claude.ai/upgrade")!)
                    } label: {
                        Text(plan)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .help("Choose your plan on claude.ai")
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
                // A red button is soft-disabled: the click surfaces WHY
                // instead of spending a request that risks the lockout the
                // color warns about. Hover already tells; click insists.
                if store.apiBudget(now: Date()).fraction >= 1 {
                    showRefreshBlocked = true
                } else {
                    store.refresh(.manual)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(refreshPressureStyle)
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .help(refreshHelp)
            .popover(isPresented: $showRefreshBlocked, arrowEdge: .bottom) {
                Text(refreshHelp)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 220)
                    .padding(10)
            }

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

    /// Tiered with `refreshPressureStyle` — whatever color the button
    /// wears, hovering it says why.
    private var refreshHelp: String {
        let budget = store.apiBudget(now: Date())
        if budget.fraction >= 1 {
            return "This hour's ~\(budget.ceiling)-request API budget is spent"
                + " (\(budget.used) used) — refreshing now risks a rate-limit"
                + " lockout. The gauge clears as requests age out of the hour."
        }
        if budget.fraction >= 0.8 {
            return "Refresh now — \(budget.used) of ~\(budget.ceiling) hourly"
                + " API requests used; nearing the budget, another poll may"
                + " trip the rate limit"
        }
        return "Refresh now (at most once per 3 minutes)"
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

    /// "resets in 3h 20m" — joined by "runs out in 1h 05m" ONLY when the
    /// forecast actually crosses the limit, in resetText's own tiers. An
    /// on-track forecast stays silent; the bar's tint carries the risk.
    /// Before enough samples exist the burn slot says it's measuring.
    private var captionLine: Text {
        var parts: [Text] = []
        if let resetsAt = meter.resetsAt {
            parts.append(
                Text(UsageFormatting.resetText(resetsAt, now: Date()))
                    .foregroundStyle(.secondary))
        }
        if let prediction, let exhaust = prediction.exhaustsAt {
            parts.append(
                Text(UsageFormatting.exhaustText(exhaust, now: Date()))
                    .foregroundStyle(riskColor(severity: prediction.severity) ?? .orange))
        } else if prediction == nil, meter.percent != nil, !stale {
            parts.append(Text("measuring rate…").foregroundStyle(.tertiary))
        }
        guard var line = parts.first else { return Text("") }
        for part in parts.dropFirst() {
            line = line + Text(" · ").foregroundStyle(.secondary) + part
        }
        return line
    }

    /// Exhaustion risk first — regular accent while the forecast is clean,
    /// the severity blend otherwise. Percent thresholds only stand in
    /// until a rate exists.
    private var barColor: Color {
        if stale { return Color(nsColor: .secondaryLabelColor) }
        if let prediction {
            return riskColor(severity: prediction.severity)
                ?? Color(nsColor: .controlAccentColor)
        }
        switch meter.level {
        case .normal: return Color(nsColor: .controlAccentColor)
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

/// The continuous exhaustion-risk ramp: nil while the forecast is clean,
/// pure yellow where the projection touches the warning threshold, sliding
/// linearly to pure red where the limit is spent. Every risk surface —
/// meter bars, captions, the chart's projection curve and axis label —
/// blends through this one function.
private func riskColor(severity: Double) -> Color? {
    guard severity > 0 else { return nil }
    return Color.yellow.mix(with: .red, by: severity)
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

    /// The Sliding span's trailing frame. Week-to-date follows the
    /// calendar locale's first weekday (Sunday or Monday).
    enum SlidingFrame: String, CaseIterable {
        case h5 = "5h"
        case h12 = "12h"
        case h24 = "24h"
        case week = "wk"
        case d7 = "7d"
        case d30 = "30d"

        func length(now: Date) -> TimeInterval {
            switch self {
            case .h5: return 5 * 3600
            case .h12: return 12 * 3600
            case .h24: return 24 * 3600
            case .week:
                let start = Calendar.current.dateInterval(of: .weekOfYear, for: now)?.start
                // A week only seconds old still deserves a visible frame.
                return max(3600, now.timeIntervalSince(start ?? now))
            case .d7: return 7 * 86400
            case .d30: return 30 * 86400
            }
        }

        var label: String {
            switch self {
            case .h5: return "last 5h"
            case .h12: return "last 12h"
            case .h24: return "last 24h"
            case .week: return "this week"
            case .d7: return "last 7 days"
            case .d30: return "last 30 days"
            }
        }
    }

    /// The span choice, remembered per meter across popover dismissals and
    /// relaunches — the single shared popover would otherwise leak one
    /// meter's choice onto the next while sweeping rows.
    @AppStorage private var span: Span
    /// The Sliding frame, remembered the same way; defaults to the
    /// meter's native window scale.
    @AppStorage private var slidingFrame: SlidingFrame
    /// Idle tolerance for the activity strip — adjustable in Settings.
    @AppStorage(ActivityGrace.storageKey)
    private var graceSeconds = ActivityGrace.defaultSeconds
    @State private var hoverDate: Date?
    /// The focused model — set by hovering its curve or its legend row.
    @State private var focusedModel: String?
    /// The activity-strip nub under the cursor, if any.
    @State private var hoveredSegment: ActivitySegment?
    /// The reset line under the cursor — its whole ended window lights up.
    @State private var hoveredReset: Date?

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
        _slidingFrame = AppStorage(
            wrappedValue: meter.rank == 0 ? .h5 : .d7, "meterSlidingFrame-\(meter.id)")
    }

    private static let chartWidth: CGFloat = 300
    private static let chartHeight: CGFloat = 124
    /// One width for Y-axis labels in both modes — sized for the widest
    /// token string TokenFormat.compact emits ("838.9M", six characters),
    /// so nothing wraps or truncates and the axis flipping between percent
    /// and tokens never resizes the plot.
    private static let axisLabelWidth: CGFloat = 42
    /// Vertical room (in domain percent units — the plot maps ~1 unit per
    /// point) a Y-axis label needs; standard marks closer than this to the
    /// projection mark are dropped instead of overlapped.
    private static let axisLabelClearance = 12.0
    /// X-axis eclipse reach, as a fraction of the visible domain: half the
    /// crossing label plus half a base tick label, in plot-relative width.
    private static let xAxisClearanceFraction = 0.15
    // The Y domain's ceiling is dynamic — dataCeiling × 1.15, headroom
    // where the now and session-duration labels live, atop the data
    // instead of on it and inside the chart instead of crashing into the
    // stats line. The same trick the activity strip plays below 0.
    // (chartPlotStyle top padding is NOT this — it shifts the plot
    // against its own axis marks.)
    private static let weekdayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()
    private static let dayName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()
    private static let monthDayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
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
        return (now.addingTimeInterval(-slidingFrame.length(now: now)), now)
    }

    private var spanLabel: String {
        switch effectiveSpan {
        case .window: meter.rank == 0 ? "this session" : "this week"
        case .sliding: slidingFrame.label
        }
    }

    /// The frame dropdown: current choice + chevron, menu of the long
    /// labels. Same bare-button dressing as the panel's ⋯ menu — the
    /// default menu style wraps it in a bordered pull-down pill.
    private var framePicker: some View {
        Menu {
            Picker("Frame", selection: $slidingFrame) {
                ForEach(SlidingFrame.allCases, id: \.self) { frame in
                    Text(frame.label).tag(frame)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 2) {
                Text(slidingFrame.rawValue)
                    .font(.caption2.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
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

    private struct PercentSeries {
        let drawn: [Point]
        /// The reset moments inside the frame — where the drawn line
        /// cliffs, and where the vertical reset markers stand.
        let resets: [Date]
    }

    /// The drawn percent series: the in-domain samples, the last sample
    /// before the frame (so the line enters at its true height), and a
    /// reset cliff wherever the percent dropped between neighbors — the
    /// line holds its level to the old window's end, falls to zero there,
    /// then climbs again. A limit reset is an instant, and sparse samples
    /// straddling it must not draw as a gradual decline. `points` alone
    /// keeps anchoring the token normalization: its first/last must stay
    /// in-domain.
    private var percentSeries: PercentSeries {
        let (start, end) = domain
        let measuredEnd = min(end, Date())
        var series: [ResetCliffs.Sample] = []
        var lastBefore: ResetCliffs.Sample?
        for sample in samples where sample.t <= measuredEnd {
            guard let percent = sample.percents[meter.label] else { continue }
            let point = ResetCliffs.Sample(
                t: sample.t, percent: percent, resetsAt: sample.resets?[meter.label])
            if sample.t < start { lastBefore = point } else { series.append(point) }
        }
        if let lastBefore { series.insert(lastBefore, at: 0) }
        let cliffs = ResetCliffs.cliffs(
            between: series, window: window, currentReset: meter.resetsAt)
        var drawn = series.map {
            Point(id: $0.t.timeIntervalSince1970, t: $0.t, percent: $0.percent)
        }
        for cliff in cliffs {
            drawn.append(Point(
                id: cliff.at.timeIntervalSince1970 + 0.25, t: cliff.at, percent: cliff.from))
            drawn.append(Point(
                id: cliff.at.timeIntervalSince1970 + 0.75,
                t: cliff.at.addingTimeInterval(1), percent: 0))
        }
        return PercentSeries(
            drawn: drawn.sorted { $0.t < $1.t },
            resets: cliffs.map(\.at).filter { $0 >= start })
    }

    /// This window's per-model usage, scoped for scoped meters — the rows of
    /// the shared table and the curves the chart overlays.
    private var windowRows: [ModelTokenUsage] {
        let all = WindowTokens.breakdown(timeline: timeline, from: domain.start, to: Date())
        return scopeName.map { WindowTokens.scoped(all, name: $0) } ?? all
    }

    /// The grid's rows: the whole frame normally; while an active nub is
    /// hovered, the same models re-tallied over just that session — and
    /// while a reset line is hovered, over the limit window that ended
    /// there (the true window, even the part outside the frame). The row
    /// set and order stay fixed — hover must never reflow the popover — so
    /// models silent during the slice read zero.
    private func sessionRows(base: [ModelTokenUsage]) -> [ModelTokenUsage] {
        if let reset = hoveredReset {
            return scopedRows(base: base, from: reset.addingTimeInterval(-window), to: reset)
        }
        guard let session = hoveredSegment, session.kind == .active else { return base }
        return scopedRows(base: base, from: session.sessionStart, to: session.end)
    }

    private func scopedRows(
        base: [ModelTokenUsage], from: Date, to: Date
    ) -> [ModelTokenUsage] {
        let slice = WindowTokens.breakdown(timeline: timeline, from: from, to: to)
        let byModel = Dictionary(uniqueKeysWithValues: slice.map { ($0.model, $0.tally) })
        return base.map {
            ModelTokenUsage(model: $0.model, tally: byModel[$0.model] ?? TokenTally())
        }
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
        let scale = percentPerToken(rows: rows)
        let curves = modelCurves(rows: rows, colors: colors, percentPerToken: scale)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.label).font(.caption.bold())
                Spacer()
                // The Sliding span picks its trailing frame from a compact
                // dropdown beside the span picker; the Window span's frame
                // IS the limit window, so the dropdown hides there.
                if effectiveSpan == .sliding {
                    framePicker
                }
                if liveReset != nil {
                    SegmentedPicker(
                        title: "Span", selection: $span,
                        options: Span.allCases.map { ($0.rawValue, $0) })
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
                    chart(curves: curves, now: context.date, percentPerToken: scale)
                }
            }
            domainLabels
            Text(resetReadout ?? segmentReadout ?? readout.map(readoutText) ?? hoverHint)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(readout == nil && segmentReadout == nil && resetReadout == nil
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
                    rows: sessionRows(base: rows), colors: colors, pricing: pricing,
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
            hoveredReset = nil
        }
    }

    /// The reset line within grabbing distance of the cursor (~4pt of
    /// track). Reset dates are value-stable across renders, so matching
    /// the stored hover by value is drift-proof.
    private func nearestReset(
        to date: Date, in resets: [Date], start: Date, end: Date
    ) -> Date? {
        let tolerance = end.timeIntervalSince(start) * 4 / Double(Self.chartWidth)
        return resets
            .min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
            .flatMap { abs($0.timeIntervalSince(date)) <= tolerance ? $0 : nil }
    }

    // MARK: - Chart

    private func chart(
        curves: [ModelCurve], now: Date, percentPerToken: Double?
    ) -> some View {
        let (start, end) = domain
        let measuredEnd = min(end, now)
        let segments = activitySegments(now: now)
        let series = percentSeries
        let drawnPercent = series.drawn
        // Y geometry scales from the tallest curve: the headroom band that
        // hosts the top labels is always 15% of the data ceiling, so the
        // Window span keeps its familiar 100→115 shape and a Sliding frame
        // holding 2.6 limits gets 260→299 — labels never land on data.
        let ceiling = dataCeiling(curves)
        let plotTop = ceiling * 1.15
        // The stored hover re-anchored onto this render's freshly built
        // segments — see liveNub for why no direct comparison can do it.
        let hovered = hoveredSegment.flatMap { liveNub(for: $0, in: segments) }
        let focusedCurve = focusedModel.flatMap { model in curves.first { $0.model == model } }
        let nowLabelShown = hovered == nil
            && !nowEclipsed(by: focusedCurve, now: now, start: start, end: end)
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
                .foregroundStyle(nubColor(segment).opacity(nubOpacity(segment, hovered: hovered)))
            }
            // Scaffolding under the data: a muted dashed vertical at each
            // reset that happened inside the frame, and — when the frame
            // holds more than one limit — a dashed horizontal pinning where
            // a single limit tops out. The percent line can never cross
            // that line; the token curves honestly can.
            // Conspicuous on purpose — the same lesson as the now rule:
            // anything softer vanishes against the dark material. The
            // hovered line goes full primary and its whole ended window
            // lights via the curtains below.
            ForEach(series.resets, id: \.timeIntervalSinceReferenceDate) { reset in
                RuleMark(
                    x: .value("Reset", reset),
                    yStart: .value("Usage", 0), yEnd: .value("Usage", ceiling))
                .foregroundStyle(Color.primary.opacity(hoveredReset == reset ? 1 : 0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            // Reset hover: curtain-dim everything outside the limit window
            // that ended at this line — the undimmed stretch IS the window
            // — with a solid twin marking where that window began. The
            // summary below re-tallies to the same window.
            if let hoveredReset {
                let curtain = Color(nsColor: .windowBackgroundColor).opacity(0.5)
                let windowStart = max(start, hoveredReset.addingTimeInterval(-window))
                RuleMark(
                    x: .value("Window start", windowStart),
                    yStart: .value("Usage", 0), yEnd: .value("Usage", ceiling))
                .foregroundStyle(Color.primary)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                if windowStart > start {
                    RectangleMark(
                        xStart: .value("Time", start),
                        xEnd: .value("Time", windowStart),
                        yStart: .value("Usage", 0), yEnd: .value("Usage", ceiling))
                    .foregroundStyle(curtain)
                }
                if hoveredReset < end {
                    RectangleMark(
                        xStart: .value("Time", hoveredReset),
                        xEnd: .value("Time", end),
                        yStart: .value("Usage", 0), yEnd: .value("Usage", ceiling))
                    .foregroundStyle(curtain)
                }
            }
            if effectiveSpan == .sliding,
               ceiling > 100 || end.timeIntervalSince(start) > window * 1.01 {
                RuleMark(y: .value("Usage", 100))
                    .foregroundStyle(.tertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
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
                ForEach(drawnPercent) { point in
                    AreaMark(
                        x: .value("Time", point.t),
                        yStart: .value("Usage", 0),
                        yEnd: .value("Usage", Double(point.percent)))
                    .foregroundStyle(orange.opacity(0.18))
                    .interpolationMethod(.monotone)
                }
            }
            ForEach(drawnPercent) { point in
                LineMark(
                    x: .value("Time", point.t),
                    y: .value("Usage", Double(point.percent)),
                    series: .value("Series", "percent"))
                .foregroundStyle(orange.opacity(focusedModel == nil ? 1 : 0.3))
                .interpolationMethod(.monotone)
            }
            if effectiveSpan == .window {
                // The prediction engine's trajectory: dashed, measured side
                // of the notch left alone. It speaks the risk ramp — accent
                // while the forecast is clean, yellow-to-red as the
                // projection climbs past the warning threshold.
                if let prediction, prediction.curve.count >= 2 {
                    let trajectory = riskColor(severity: prediction.severity) ?? orange
                    ForEach(prediction.curve, id: \.t) { point in
                        LineMark(
                            x: .value("Time", point.t),
                            y: .value("Usage", point.percent),
                            series: .value("Series", "prediction"))
                        .foregroundStyle(trajectory.opacity(focusedModel == nil ? 0.8 : 0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
                // The now separator: everything left is measured, right is
                // ahead. Full primary — anything softer (.tertiary, then
                // .secondary) got lost against the chart. The rule stops at
                // 100 so its label sits in the headroom band above the data;
                // while a nub is hovered it yields the band to the
                // session-duration label.
                RuleMark(
                    x: .value("Now", now),
                    yStart: .value("Usage", Self.stripBottom),
                    yEnd: .value("Usage", 100))
                    .foregroundStyle(.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(
                        position: .top, alignment: .center, spacing: 2,
                        overflowResolution: .init(x: .fit(to: .plot), y: .disabled)
                    ) {
                        if nowLabelShown {
                            // Frame-aware like every timestamp here: clock
                            // within a day, weekday + clock across days,
                            // date + clock past a week.
                            Text(timeLabel(now))
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                // Where the current pace hits the limit; the hatched region
                // beyond it is unusable. The crossing's timestamp lives in
                // the X axis row (always on), not up here — as an annotation
                // it landed on the strip's red nub and vanished into it.
                if let exhaust = exhaustDate {
                    RuleMark(
                        x: .value("Exhausted", exhaust),
                        yStart: .value("Usage", Self.stripBottom),
                        yEnd: .value("Usage", 100))
                        .foregroundStyle(.red.opacity(0.75))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            // Nub hover: dimming curtains cover the graph outside the
            // hovered slice — the slice keeps full strength, which IS the
            // highlight. Nubs dim via their own opacity (curtains stop at
            // the plot floor).
            if let hovered {
                let curtain = Color(nsColor: .windowBackgroundColor).opacity(0.5)
                if hovered.start > start {
                    RectangleMark(
                        xStart: .value("Time", start),
                        xEnd: .value("Time", hovered.start),
                        yStart: .value("Usage", 0), yEnd: .value("Usage", ceiling))
                    .foregroundStyle(curtain)
                }
                if hovered.end < end {
                    RectangleMark(
                        xStart: .value("Time", hovered.end),
                        xEnd: .value("Time", end),
                        yStart: .value("Usage", 0), yEnd: .value("Usage", ceiling))
                    .foregroundStyle(curtain)
                }
                // The session's duration, highlighted in the headroom band
                // and centered over its nub — the at-a-glance answer while
                // the readout line below spells out the range.
                PointMark(
                    x: .value("Time", hovered.start.addingTimeInterval(
                        hovered.end.timeIntervalSince(hovered.start) / 2)),
                    y: .value("Usage", ceiling))
                .symbolSize(0)
                .annotation(
                    position: .top, alignment: .center, spacing: 2,
                    overflowResolution: .init(x: .fit(to: .plot), y: .disabled)
                ) {
                    Text(UsageFormatting.duration(
                        hovered.end.timeIntervalSince(hovered.sessionStart)))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(
                            hovered.kind == .exhausted
                                ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                }
            }
            // The focused model's name rides above its curve's tip — the
            // chart-side echo of the legend row. Labels are layered: this
            // outranks the now label (which yields on overlap) and the
            // strip's duration label can't coexist with a curve focus.
            if let focusedCurve, let tip = focusedCurve.points.last {
                PointMark(
                    x: .value("Time", tip.t),
                    y: .value("Usage", tip.normalized))
                .symbolSize(0)
                .annotation(
                    position: .top, alignment: .center, spacing: 2,
                    overflowResolution: .init(x: .fit(to: .plot), y: .disabled)
                ) {
                    Text(ModelNames.display(focusedCurve.model))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(focusedCurve.color)
                }
            }
            if let readout {
                RuleMark(
                    x: .value("Time", readout.t),
                    yStart: .value("Usage", Self.stripBottom),
                    yEnd: .value("Usage", ceiling))
                    .foregroundStyle(.quaternary)
                PointMark(
                    x: .value("Time", readout.t),
                    y: .value("Usage", Double(readout.percent)))
                .foregroundStyle(orange.opacity(readout.predicted ? 0.8 : 1))
                .symbolSize(30)
            }
        }
        .chartYScale(domain: Self.stripBottom - 1...plotTop)
        // While a model is focused the axis speaks its language: the
        // gridlines re-labeled as tokens through the shared conversion,
        // climbing in steps of half a limit as far as the curves reach.
        // Both modes render labels at one fixed width — token strings are
        // wider than "100", and a mode flip must never resize the plot.
        .chartYAxis {
            if focusedModel != nil, let percentPerToken {
                AxisMarks(values: Array(stride(from: 0.0, through: ceiling, by: 50))) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let percent = value.as(Double.self) {
                            Text(TokenFormat.compact(Int(percent / percentPerToken)))
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .frame(width: Self.axisLabelWidth, alignment: .leading)
                        }
                    }
                }
            } else {
                // The projected-finish height gets its own labeled mark; a
                // standard label it would eclipse steps aside rather than
                // overlap (the projection is the one worth reading).
                let projection = axisProjection
                AxisMarks(values: [0, 50, 100].filter { mark in
                    guard let projection else { return true }
                    return abs(Double(mark) - projection) >= Self.axisLabelClearance
                }) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let percent = value.as(Double.self) {
                            Text("\(Int(percent))%")
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .frame(width: Self.axisLabelWidth, alignment: .leading)
                        }
                    }
                }
                if let projection {
                    AxisMarks(values: [projection]) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        AxisValueLabel {
                            Text("\(Int(projection))%")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(
                                    riskColor(severity: prediction?.severity ?? 0) ?? orange)
                                .lineLimit(1)
                                .frame(width: Self.axisLabelWidth, alignment: .leading)
                        }
                    }
                }
            }
        }
        .chartXScale(domain: start...end)
        // A frame of several days labels its axis with day names at the
        // day boundaries — dates mean less than weekdays at that zoom.
        // Beyond ~a week the names would repeat, so the month scale keeps
        // the default date ticks; within a day, the default hour ticks.
        // When the forecast crosses the limit, the crossing's timestamp
        // joins the axis row in red — always on — and any base tick whose
        // label it would overlap steps aside (the Y axis projection's
        // eclipse rule, applied to time).
        .chartXAxis {
            let length = end.timeIntervalSince(start)
            if length >= 48 * 3600, length <= 8 * 86400 {
                AxisMarks(values: withoutEclipsed(dayTicks)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let day = value.as(Date.self) {
                            Text(Self.dayName.string(from: day))
                                .fontWeight(.semibold)
                        }
                    }
                }
            } else if exhaustDate != nil, length < 48 * 3600 {
                // Automatic ticks can't be eclipsed, so the crossing's
                // presence switches this frame to explicit hour marks.
                AxisMarks(values: withoutEclipsed(hourTicks)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(UsageFormatting.clockTime(date))
                                .fontWeight(.semibold)
                        }
                    }
                }
            } else {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisValueLabel()
                        .font(.caption2.weight(.semibold))
                }
            }
            if let exhaust = exhaustDate {
                AxisMarks(values: [exhaust]) { _ in
                    // fixedSize + an edge-aware anchor: centered on its tick
                    // the label truncated against the plot edge whenever the
                    // crossing sat near the reset.
                    AxisValueLabel(anchor: exhaustLabelAnchor) {
                        Text(timeLabel(exhaust))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                            .fixedSize()
                    }
                }
            }
        }
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
                                if hoveredReset != nil { hoveredReset = nil }
                            } else {
                                if hoveredSegment != nil { hoveredSegment = nil }
                                // A reset line within reach takes the hover
                                // before curve focus — its ended window
                                // lights up instead.
                                let reset = date.flatMap { d in
                                    nearestReset(
                                        to: d, in: series.resets, start: start, end: end)
                                }
                                if hoveredReset != reset { hoveredReset = reset }
                                if reset != nil {
                                    if focusedModel != nil { focusedModel = nil }
                                } else {
                                    updateFocus(at: date, yValue: yValue, curves: curves)
                                }
                            }
                        case .ended:
                            hoverDate = nil
                            focusedModel = nil
                            hoveredSegment = nil
                            hoveredReset = nil
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

    /// The Window span's projected finish height for the Y axis — only
    /// while the forecast stays within the limit (an exhausting one is the
    /// red rule's story) and the axis still speaks percent.
    private var axisProjection: Double? {
        guard effectiveSpan == .window, focusedModel == nil,
              let prediction, prediction.exhaustsAt == nil,
              let projected = prediction.projectedAtReset, projected < 100
        else { return nil }
        return Double(projected)
    }

    /// Day-boundary X ticks, explicit (rather than `.stride(by: .day)`) so
    /// the exhaustion label can eclipse the ones it would overlap.
    private var dayTicks: [Date] {
        let (start, end) = domain
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: start)
        if day < start { day = calendar.date(byAdding: .day, value: 1, to: day) ?? end }
        var ticks: [Date] = []
        while day <= end {
            ticks.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return ticks
    }

    /// Whole-hour X ticks for sub-two-day frames, strided to land a handful
    /// of labels. Only rendered while a crossing needs the eclipse rule.
    private var hourTicks: [Date] {
        let (start, end) = domain
        let length = end.timeIntervalSince(start)
        let strideHours = length <= 6 * 3600 ? 1 : length <= 12 * 3600 ? 2 : 6
        let calendar = Calendar.current
        guard var tick = calendar.nextDate(
            after: start, matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .nextTime)
        else { return [] }
        var ticks: [Date] = []
        while tick <= end {
            ticks.append(tick)
            guard let next = calendar.date(byAdding: .hour, value: strideHours, to: tick)
            else { break }
            tick = next
        }
        return ticks
    }

    /// Near a plot edge the crossing's label hangs inward from its tick
    /// instead of centering on it — centered, the edge clipped it to "Sat…".
    private var exhaustLabelAnchor: UnitPoint {
        guard let exhaust = exhaustDate else { return .top }
        let (start, end) = domain
        let fraction = exhaust.timeIntervalSince(start) / end.timeIntervalSince(start)
        if fraction > 0.88 { return .topTrailing }
        if fraction < 0.12 { return .topLeading }
        return .top
    }

    /// The crossing's timestamp owns its stretch of the axis row: base
    /// ticks whose labels would crowd it step aside rather than overlap.
    /// The reach follows the anchor — a trailing-anchored label lies almost
    /// entirely left of its tick, so the eclipse shifts with it.
    private func withoutEclipsed(_ ticks: [Date]) -> [Date] {
        guard let exhaust = exhaustDate else { return ticks }
        let (start, end) = domain
        let clearance = end.timeIntervalSince(start) * Self.xAxisClearanceFraction
        let anchor = exhaustLabelAnchor
        let (leftReach, rightReach): (Double, Double) = anchor == .topTrailing
            ? (1.7, 0.4)
            : anchor == .topLeading ? (0.4, 1.7) : (1, 1)
        return ticks.filter {
            let offset = $0.timeIntervalSince(exhaust)
            return offset < -clearance * leftReach || offset > clearance * rightReach
        }
    }

    private struct ActivitySegment: Equatable {
        enum Kind: Equatable {
            case active
            /// The dead stretch past the projected limit crossing.
            case exhausted
        }

        let start: Date
        let end: Date
        var kind: Kind = .active
        /// The session's true start when the frame clips its nub at the
        /// domain's left edge — labels and the session summary honor it;
        /// drawing keeps `start`.
        var fullStart: Date? = nil

        var sessionStart: Date { fullStart ?? start }
    }

    private func nubColor(_ segment: ActivitySegment) -> Color {
        segment.kind == .exhausted ? .red : orange
    }

    /// The stored hover re-anchored onto freshly built segments. No date
    /// field survives a rebuild — the sliding domain re-anchors at Date()
    /// every render, shifting every bucket boundary, and the trailing end /
    /// exhausted start move with time — so equality on any of them orphans
    /// the hover. The stored nub's midpoint finding the segment that
    /// contains it is drift-proof (drift is micro/30s-scale, nubs are
    /// minutes wide).
    private func liveNub(
        for stored: ActivitySegment, in segments: [ActivitySegment]
    ) -> ActivitySegment? {
        if stored.kind == .exhausted { return segments.first { $0.kind == .exhausted } }
        let mid = stored.start.addingTimeInterval(
            stored.end.timeIntervalSince(stored.start) / 2)
        return segments.first { $0.kind == .active && $0.start <= mid && mid <= $0.end }
    }

    /// The hovered nub at full strength; with any nub hovered, its peers
    /// recede along with the curtained graph above them. `hovered` is the
    /// live-resolved nub, an element of the same array being drawn, so
    /// equality here is exact.
    private func nubOpacity(_ segment: ActivitySegment, hovered: ActivitySegment?) -> Double {
        guard let hovered else { return 0.7 }
        return segment == hovered ? 1 : 0.25
    }

    /// "Wed 09:15 – Wed 14:15 · window 5 hr" while a reset line is
    /// hovered — the bounds and length of the limit window being lit.
    private var resetReadout: String? {
        hoveredReset.map { reset in
            let windowStart = reset.addingTimeInterval(-window)
            return "\(timeLabel(windowStart)) – \(timeLabel(reset)) · window "
                + UsageFormatting.duration(window)
        }
    }

    /// "Wed 09:15 – Wed 11:30 · active 2 hr 15 min" while a nub is hovered;
    /// the exhausted nub reads "unreachable" instead. A frame-clipped
    /// session reads from its true start, before the domain.
    private var segmentReadout: String? {
        hoveredSegment.map { segment in
            let verb = segment.kind == .exhausted ? "unreachable" : "active"
            return "\(timeLabel(segment.sessionStart)) – \(timeLabel(segment.end)) · \(verb) "
                + UsageFormatting.duration(
                    segment.end.timeIntervalSince(segment.sessionStart))
        }
    }

    /// The scoped activity moments before `boundary`, walked backwards with
    /// the strip's grace bridging — the true start of a session whose nub
    /// the frame clips. Only computed for a first segment touching the
    /// domain's left edge.
    private func clippedSessionStart(before boundary: Date) -> Date? {
        let needle = scopeName?.lowercased()
        let moments = timeline.compactMap { slot -> Date? in
            if let needle, !slot.model.lowercased().contains(needle) { return nil }
            return slot.t
        }
        return ActivityGrace.clippedStart(
            before: boundary, moments: moments, grace: graceSeconds)
    }

    /// Contiguous stretches of the measured domain where transcripts logged
    /// tokens (scoped meters count only their own model), bucketed so a week
    /// of minute slots collapses to a handful of marks.
    private func activitySegments(now: Date) -> [ActivitySegment] {
        // Month scale: sessions are minutes-to-hours wide — sub-pixel
        // slivers or misleading bucket-wide blobs at this zoom. The strip
        // goes quiet rather than cluttered; the heatmap owns that scale.
        if effectiveSpan == .sliding, slidingFrame == .d30 { return [] }
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
        // Human-scale pauses — reading, typing a reply — are still the same
        // session: gaps within the grace period get bridged (0 = raw Claude
        // activity only), and the newest stretch is held open to now while
        // its idle time could still turn out to be such a pause; once the
        // gap outgrows the grace, the nub snaps back to the session's true
        // end. The hold caps at the exhausted boundary — a session can't
        // run into the unreachable region.
        let stitched = ActivityGrace.stitch(
            segments.map { DateInterval(start: $0.start, end: $0.end) },
            grace: graceSeconds)
        segments = ActivityGrace.holdOpen(
            stitched, until: min(end, exhaustDate ?? end), grace: graceSeconds
        ).map { ActivitySegment(start: $0.start, end: $0.end) }
        // A session the frame clips at its left edge is longer than its
        // nub: walk the timeline before the domain (same grace bridging)
        // for its true start, so hover reports the whole session.
        if let first = segments.first, first.kind == .active,
           first.start.timeIntervalSince(start) < 1 {
            segments[0].fullStart = clippedSessionStart(before: first.start)
        }
        // The dead stretch gets its own nub at the strip's end, so the
        // unreachable region reads from the strip too.
        if let exhaust = exhaustDate {
            segments.append(ActivitySegment(
                start: exhaust, end: domain.end, kind: .exhausted))
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

    /// The chart's one tokens→percent conversion: the percent the meter
    /// gained over the visible window, divided by the tokens spent in it.
    /// Under this scale the models' combined spend meets the percent
    /// curve's growth exactly, so every token curve stays perceptually
    /// contained inside the usage it fed — and the Y axis can speak tokens
    /// by dividing back. Nil when percent data is missing, flat, or dipped
    /// through a reset — curves then fall back to busiest-model scaling
    /// and the axis stays percent.
    private func percentPerToken(rows: [ModelTokenUsage]) -> Double? {
        if effectiveSpan == .sliding { return slidingPercentPerToken }
        let total = WindowTokens.total(rows).total
        guard total > 0, let first = points.first, let last = points.last else { return nil }
        let delta = Double(last.percent - first.percent)
        guard delta >= 1 else { return nil }
        return delta / Double(total)
    }

    /// The Sliding span's anchor. Its frame can straddle resets, where
    /// percent deltas lie, so one limit's worth of tokens is measured on
    /// the CURRENT live window instead: the live percent over the tokens
    /// spent since that window began. Curves normalized by it read as
    /// fractions of a single limit — and may honestly exceed it across a
    /// frame longer than one window.
    private var slidingPercentPerToken: Double? {
        guard let reset = liveReset, let percent = meter.percent, percent >= 1
        else { return nil }
        let windowStart = reset.addingTimeInterval(-window)
        let all = WindowTokens.breakdown(timeline: timeline, from: windowStart, to: Date())
        let scoped = scopeName.map { WindowTokens.scoped(all, name: $0) } ?? all
        let total = WindowTokens.total(scoped).total
        guard total > 0 else { return nil }
        return Double(percent) / Double(total)
    }

    /// Layered labels: when the focused model's name and the now label
    /// would collide, the now label (the lower layer) disappears for the
    /// moment. Extents are estimated in track space — close enough for a
    /// yield decision.
    private func nowEclipsed(
        by curve: ModelCurve?, now: Date, start: Date, end: Date
    ) -> Bool {
        guard let curve, let tip = curve.points.last else { return false }
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return false }
        let xNow = now.timeIntervalSince(start) / span * Self.chartWidth
        let xLabel = tip.t.timeIntervalSince(start) / span * Self.chartWidth
        let labelWidth = Double(ModelNames.display(curve.model).count) * 4.5 + 4
        return abs(xLabel - xNow) < (labelWidth + 18) / 2
    }

    private func modelCurves(
        rows: [ModelTokenUsage], colors: [String: Color], percentPerToken: Double?
    ) -> [ModelCurve] {
        let raw = rows.map { row in (model: row.model, curve: cumulativeCurve(model: row.model)) }
        let norm: Double
        if let percentPerToken {
            norm = percentPerToken
        } else {
            let maxTotal = raw.compactMap { $0.curve.last?.total }.max() ?? 0
            guard maxTotal > 0 else { return [] }
            norm = 100.0 / Double(maxTotal)
        }
        // The Window span is one window — nothing can honestly exceed one
        // limit there, so the cap is a safety net. A Sliding frame can
        // span several windows and the overshoot IS the information.
        let cap = effectiveSpan == .window
        return raw.map { entry in
            ModelCurve(
                model: entry.model,
                color: colors[entry.model] ?? .gray,
                points: entry.curve.map {
                    let value = Double($0.total) * norm
                    return ($0.t, cap ? min(100, value) : value)
                })
        }
    }

    /// The tallest drawn value: 100 in the Window span (curves cap there),
    /// beyond it when a Sliding frame holds more than one limit's worth.
    /// The plot top and the label headroom band scale from it.
    private func dataCeiling(_ curves: [ModelCurve]) -> Double {
        max(100, curves.flatMap { $0.points }.map { $0.normalized }.max() ?? 100)
    }

    /// Running total per ~180 buckets so a busy week doesn't hand Charts
    /// thousands of minute slots. Covers the measured part of the domain.
    /// CumulativeSeries holds the level flat across idle gaps — sparse
    /// cumulative points would otherwise interpolate as phantom growth.
    private func cumulativeCurve(model: String) -> [CumulativePoint] {
        let start = domain.start
        let end = min(domain.end, Date())
        let moments = timeline
            .filter { $0.model == model }
            .map { (t: $0.t, amount: $0.tally.total) }
        return CumulativeSeries.build(moments: moments, start: start, end: end)
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
        focusedModel.map { "\(ModelNames.display($0)) focused" }
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

    /// Frame-aware timestamps: hours within a day, weekday + time across
    /// several days, month + day once weekday names would repeat.
    private func timeLabel(_ date: Date) -> String {
        let (start, end) = domain
        let length = end.timeIntervalSince(start)
        if length > 8 * 86400 { return Self.monthDayTime.string(from: date) }
        if length > 24 * 3600 { return Self.weekdayTime.string(from: date) }
        return UsageFormatting.clockTime(date)
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
        // Interpolate on the drawn series — the reset cliffs included, so
        // the readout steps where the line steps.
        let all = percentSeries.drawn
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
