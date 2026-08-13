import Charts
import SwiftUI
import UsageCore

struct UsagePanelView: View {
    var store: UsageStore
    /// Wired by StatusItemController: closes the panel, opens the window.
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            Divider()
            HeatmapView(activity: store.activity, pricing: store.pricing)
            footer
        }
        .padding(14)
        // Wide enough that the breakdown grid never truncates model names.
        .frame(width: 360)
        .onAppear { store.scanActivity() }
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude Usage").font(.headline)
                Text("v\(AppIdentity.version)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if case .cached(let snapshot, _) = store.state {
                    Text("cached \(UsageFormatting.clockTime(snapshot.fetchedAt))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if let plan = store.state.snapshot?.plan?.displayLabel {
                Text(plan)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
                    samples: store.samples,
                    timeline: store.tokenTimeline,
                    pricing: store.pricing)
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
            EmptyView() // the header already shows the error + hint
        }
    }

    @ViewBuilder private var footer: some View {
        Divider()
        HStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(statusLine(now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private func statusLine(now: Date) -> String {
        var parts: [String] = []
        if let fetchedAt = store.state.snapshot?.fetchedAt {
            parts.append("Updated \(UsageFormatting.clockTime(fetchedAt))")
        }
        if let next = store.nextRefreshAt {
            parts.append(UsageFormatting.countdownText(to: next, now: now))
        }
        // Why "next in 20m" instead of 5: quiet decayed the cadence. Activity
        // (or usage moving) snaps it back — worth a word of transparency.
        let pace = store.paceMultiplier(now: now)
        if pace > 1 { parts.append("idle ×\(pace)") }
        // Surface the API budget only once it's half spent — quiet otherwise.
        let budget = store.apiBudget(now: now)
        if budget.fraction >= 0.5 { parts.append("API \(budget.used)/\(budget.ceiling)h") }
        return parts.joined(separator: " · ")
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

struct MeterRow: View {
    let meter: Meter
    let stale: Bool
    let burn: BurnEstimate?
    let samples: [UsageSample]
    let timeline: [TokenSlot]
    let pricing: PricingTable

    @State private var hoveringRow = false
    @State private var hoveringPopover = false
    @State private var showHistory = false

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
        .contentShape(Rectangle())
        // iStat-style lifecycle: hover opens after a beat, clicking opens
        // immediately (never closes), and the popover survives the cursor
        // travelling onto it — it hides only once the cursor has left both
        // the row and the popover for a grace period.
        .onHover { inside in
            hoveringRow = inside
            if inside {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    if hoveringRow { showHistory = true }
                }
            } else {
                scheduleHideIfLeft()
            }
        }
        .onTapGesture { showHistory = true }
        .popover(isPresented: $showHistory, arrowEdge: .trailing) {
            MeterHistoryView(
                meter: meter, samples: samples, timeline: timeline, pricing: pricing)
                .onHover { inside in
                    hoveringPopover = inside
                    if !inside { scheduleHideIfLeft() }
                }
        }
    }

    private func scheduleHideIfLeft() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            if !hoveringRow && !hoveringPopover { showHistory = false }
        }
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
