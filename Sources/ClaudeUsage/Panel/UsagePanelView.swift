import Charts
import SwiftUI
import ServiceManagement
import UsageCore

struct UsagePanelView: View {
    var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            Divider()
            HeatmapView(activity: store.activity)
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { store.scanActivity() }
    }

    @ViewBuilder private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Claude Usage").font(.headline)
            Spacer()
            if case .cached(let snapshot, _) = store.state {
                Text("cached \(UsageFormatting.clockTime(snapshot.fetchedAt))")
                    .font(.caption)
                    .foregroundStyle(.orange)
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
                    samples: store.samples)
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
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .help("Refresh now (at most once per minute)")

            Link(destination: URL(string: "https://claude.ai/settings/usage")!) {
                Image(systemName: "arrow.up.right.square")
            }
            .help("Open claude.ai usage settings")

            Menu {
                Picker("Refresh every", selection: intervalBinding) {
                    Text("1 min").tag(60.0)
                    Text("5 min").tag(300.0)
                    Text("15 min").tag(900.0)
                }
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                Divider()
                Button("Quit Claude Usage") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
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
        return parts.joined(separator: " · ")
    }

    private var intervalBinding: Binding<Double> {
        Binding(
            get: { store.refreshInterval },
            set: { store.setRefreshInterval($0) }
        )
    }

    /// Registration happens only when the user flips this toggle (spec §10).
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
                if enabled {
                    try? SMAppService.mainApp.register()
                } else {
                    try? SMAppService.mainApp.unregister()
                }
            }
        )
    }
}

struct MeterRow: View {
    let meter: Meter
    let stale: Bool
    let burn: BurnEstimate?
    let samples: [UsageSample]

    @State private var hovering = false
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
        .onHover { inside in
            hovering = inside
            if inside {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    if hovering { showHistory = true }
                }
            } else {
                showHistory = false
            }
        }
        .popover(isPresented: $showHistory, arrowEdge: .trailing) {
            MeterHistoryView(meter: meter, samples: samples)
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
/// limit window (5h for the session meter, 7 days for weeklies).
struct MeterHistoryView: View {
    let meter: Meter
    let samples: [UsageSample]

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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.label).font(.caption.bold())
                Spacer()
                Text(windowLabel).font(.caption2).foregroundStyle(.secondary)
            }
            if points.count < 2 {
                Text("Collecting samples — this fills in as refreshes accumulate.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 240, height: 70)
            } else {
                Chart(points) { point in
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
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0, 50, 100]) }
                .chartXScale(domain: Date().addingTimeInterval(-window)...Date())
                .frame(width: 260, height: 110)
            }
        }
        .padding(10)
    }
}
