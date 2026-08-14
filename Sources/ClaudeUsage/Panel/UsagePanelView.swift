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
                timeline: store.tokenTimeline, pricing: store.pricing)
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
                    burn: store.burnEstimates[meter.label],
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
    let burn: BurnEstimate?

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
        if let burn {
            parts.append(Text(burn.text).foregroundStyle(burnColor(burn.verdict)))
        } else if meter.percent != nil && !stale {
            parts.append(Text("measuring rate…").foregroundStyle(.tertiary))
        }
        guard var line = parts.first else { return Text("") }
        for part in parts.dropFirst() {
            line = line + Text(" · ").foregroundStyle(.secondary) + part
        }
        return line
    }

    private func burnColor(_ verdict: BurnEstimate.Verdict) -> Color {
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

/// iStat-style per-limit history: this meter's sampled percent across its own
/// limit window (5h for the session meter, 7 days for weeklies), plus the
/// tokens local transcripts attribute to that window in the shared breakdown
/// table. The table doubles as a legend — hovering a row swaps the chart to
/// that model's cumulative tokens and the stats line to its share.
struct MeterHistoryView: View {
    let meter: Meter
    let samples: [UsageSample]
    let timeline: [TokenSlot]
    let pricing: PricingTable

    @State private var hoverDate: Date?
    @State private var hoveredModel: String?

    private static let chartWidth: CGFloat = 300
    private static let chartHeight: CGFloat = 110

    private var window: TimeInterval { meter.rank == 0 ? 5 * 3600 : 7 * 86400 }
    private var windowLabel: String { meter.rank == 0 ? "last 5h" : "last 7 days" }

    private struct Point: Identifiable {
        let id: TimeInterval
        let t: Date
        let percent: Int
    }

    private var points: [Point] {
        let cutoff = Date().addingTimeInterval(-window)
        return samples
            .filter { $0.t >= cutoff }
            .compactMap { sample in
                sample.percents[meter.label].map {
                    Point(id: sample.t.timeIntervalSince1970, t: sample.t, percent: $0)
                }
            }
    }

    /// This window's per-model usage, scoped for scoped meters — the rows of
    /// the shared table and the legend the chart follows.
    private var windowRows: [ModelTokenUsage] {
        let (start, _) = tokenWindow
        let all = WindowTokens.breakdown(timeline: timeline, from: start, to: Date())
        return scopeName.map { WindowTokens.scoped(all, name: $0) } ?? all
    }

    private var rowColors: [String: Color] {
        ModelPalette.assignment(for: windowRows.map(\.model))
    }

    var body: some View {
        let rows = windowRows
        let colors = rowColors
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.label).font(.caption.bold())
                Spacer()
                Text(windowLabel).font(.caption2).foregroundStyle(.secondary)
            }
            // Fixed-height stats line, the popover's counterpart of the main
            // section's: window totals normally, the hovered model's share
            // while the table filters the chart. Never reflows on hover.
            HStack(spacing: 5) {
                if let hoveredModel {
                    Circle()
                        .fill(colors[hoveredModel] ?? .gray)
                        .frame(width: 6, height: 6)
                }
                Text(statsText(rows: rows))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 14)
            if let hoveredModel {
                modelChart(model: hoveredModel, color: colors[hoveredModel] ?? .gray)
            } else if points.count < 2 {
                Text("Collecting samples — this fills in as refreshes accumulate.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.chartWidth, height: Self.chartHeight)
            } else {
                percentChart
            }
            Text(readout.map(readoutText) ?? hoverHint)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(readout == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
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
                    hoveredModel: $hoveredModel)
            }
            Text("Local Claude Code sessions on this Mac only.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
    }

    /// "89.2M tokens this session", or the hovered model's slice of it.
    private func statsText(rows: [ModelTokenUsage]) -> String {
        let (_, label) = tokenWindow
        if let hoveredModel, let row = rows.first(where: { $0.model == hoveredModel }) {
            return "\(row.displayName) · \(TokenFormat.compact(row.tally.total)) tokens \(label)"
        }
        return "\(TokenFormat.compact(WindowTokens.total(rows).total)) tokens \(label)"
    }

    private var hoverHint: String {
        hoveredModel.map { "Cumulative \(ModelNames.display($0)) tokens" }
            ?? "Hover the graph for point details"
    }

    /// The hovered model's cumulative tokens across the window — the
    /// popover's version of the legend filtering the chart.
    private func modelChart(model: String, color: Color) -> some View {
        let curve = cumulativeCurve(model: model)
        let (start, _) = tokenWindow
        return Chart(curve, id: \.t) { point in
            AreaMark(x: .value("Time", point.t), y: .value("Tokens", point.total))
                .foregroundStyle(color.opacity(0.18))
            LineMark(x: .value("Time", point.t), y: .value("Tokens", point.total))
                .foregroundStyle(color)
                .interpolationMethod(.monotone)
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let tokens = value.as(Double.self) {
                        Text(TokenFormat.compact(Int(tokens)))
                    }
                }
            }
        }
        .chartXScale(domain: start...Date())
        .frame(width: Self.chartWidth, height: Self.chartHeight)
    }

    /// Running total per ~180 buckets so a busy week doesn't hand Charts
    /// thousands of minute slots.
    private func cumulativeCurve(model: String) -> [(t: Date, total: Int)] {
        let (start, _) = tokenWindow
        let end = Date()
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

    private var percentChart: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("Time", point.t),
                    y: .value("Percent", point.percent)
                )
                .foregroundStyle(Color(nsColor: StatusItemRenderer.claudeOrange).opacity(0.18))
                LineMark(
                    x: .value("Time", point.t),
                    y: .value("Percent", point.percent)
                )
                .foregroundStyle(Color(nsColor: StatusItemRenderer.claudeOrange))
                .interpolationMethod(.monotone)
            }
            if let readout {
                RuleMark(x: .value("Time", readout.t))
                    .foregroundStyle(.quaternary)
                PointMark(
                    x: .value("Time", readout.t),
                    y: .value("Percent", readout.percent)
                )
                .foregroundStyle(Color(nsColor: StatusItemRenderer.claudeOrange))
                .symbolSize(30)
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis { AxisMarks(values: [0, 50, 100]) }
        .chartXScale(domain: Date().addingTimeInterval(-window)...Date())
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let x = location.x - geo[plotFrame].origin.x
                            hoverDate = proxy.value(atX: x, as: Date.self)
                        case .ended:
                            hoverDate = nil
                        }
                    }
            }
        }
        .frame(width: Self.chartWidth, height: Self.chartHeight)
    }

    /// A continuously-hoverable reading: percent is interpolated between the
    /// surrounding samples (flat beyond the ends), so sparse data doesn't
    /// make the cursor jump between far-apart points. Tokens attribute to the
    /// enclosing poll interval.
    private struct Readout {
        let t: Date
        let percent: Int
        /// The measured interval containing `t`; nil before the first sample.
        let from: Date?
        let to: Date?
    }

    private var readout: Readout? {
        // Point readouts belong to the percent chart; in model mode the
        // stats line carries the numbers.
        guard hoveredModel == nil, let hoverDate else { return nil }
        let all = points
        guard let first = all.first, let last = all.last else { return nil }
        let t = min(max(hoverDate, Date().addingTimeInterval(-window)), Date())
        if t <= first.t {
            return Readout(t: t, percent: first.percent, from: nil, to: nil)
        }
        if t >= last.t {
            return Readout(t: t, percent: last.percent, from: last.t, to: t)
        }
        let index = all.lastIndex { $0.t <= t } ?? 0
        let p0 = all[index]
        let p1 = all[index + 1]
        let span = p1.t.timeIntervalSince(p0.t)
        let fraction = span > 0 ? t.timeIntervalSince(p0.t) / span : 0
        let percent = Double(p0.percent) + fraction * Double(p1.percent - p0.percent)
        return Readout(t: t, percent: Int(percent.rounded()), from: p0.t, to: p1.t)
    }

    /// "14:32 · 34% · 1.2M tokens · $3.40" — tokens and cost cover what the
    /// transcripts logged in the poll interval the cursor sits in.
    private func readoutText(_ readout: Readout) -> String {
        var parts = [UsageFormatting.clockTime(readout.t), "\(readout.percent)%"]
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

    /// Tokens are attributed to the limit's real window when the API gave a
    /// live reset time (a session runs resetsAt − 5h → resetsAt); with no
    /// live reset the trailing window is an honest stand-in.
    private var tokenWindow: (start: Date, label: String) {
        let now = Date()
        if let resetsAt = meter.resetsAt, resetsAt > now {
            return (
                resetsAt.addingTimeInterval(-window),
                meter.rank == 0 ? "this session" : "this week"
            )
        }
        return (now.addingTimeInterval(-window), windowLabel)
    }

    /// "Weekly · Fable" → "Fable": a scoped meter's breakdown shows only its
    /// own model's usage, never the whole timeline.
    private var scopeName: String? {
        guard meter.rank == 2, meter.label.hasPrefix("Weekly · ") else { return nil }
        return String(meter.label.dropFirst("Weekly · ".count))
    }

}
