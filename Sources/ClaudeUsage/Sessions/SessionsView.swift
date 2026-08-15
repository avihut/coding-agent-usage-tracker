import Charts
import SwiftUI
import UsageCore

/// The Sessions browser: a sidebar of per-session "nutrition cards" ordered
/// by last activity, and a detail page with totals, a running-cost curve,
/// and the message-by-message breakdown.
struct SessionsView: View {
    var store: UsageStore
    var registry: ProviderRegistry

    @State private var selectedID: String?
    /// User decision: background runs are visible by default, badged and
    /// dimmed; the toggle lets them be hidden.
    @AppStorage("sessionsShowBackground") private var showBackground = true

    private var visibleSessions: [SessionSummary] {
        showBackground
            ? store.sessions
            : store.sessions.filter { $0.kind == .interactive }
    }

    private var backgroundCount: Int {
        store.sessions.count(where: { $0.kind == .background })
    }

    /// One palette lookup per render, never per row — assignment re-reads
    /// UserDefaults and rebuilds the whole map on every call.
    private var modelColors: [String: Color] {
        var models: Set<String> = []
        for session in store.sessions { models.formUnion(session.models.keys) }
        return ModelPalette.assignment(for: models.sorted())
    }

    var body: some View {
        let colors = modelColors
        NavigationSplitView {
            sidebar(colors: colors)
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 440)
        } detail: {
            if let selected = visibleSessions.first(where: { $0.id == selectedID }) {
                SessionDetailPane(store: store, summary: selected, colors: colors)
            } else if store.sessions.isEmpty {
                emptyState
            } else {
                ContentUnavailableView(
                    "Select a session",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Costs are estimated at API list prices."))
            }
        }
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 940, minHeight: 560)
    }

    private func sidebar(colors: [String: Color]) -> some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(SessionDayGroup.build(visibleSessions, calendar: .current)) { group in
                    Section(Self.dayLabel(group.day)) {
                        ForEach(group.sessions) { session in
                            SessionRow(
                                session: session,
                                cost: Self.cost(of: session, pricing: store.pricing),
                                colors: colors
                            )
                            .tag(session.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Toggle("Show background runs", isOn: $showBackground)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                if backgroundCount > 0 {
                    Text("\(backgroundCount) background")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No \(store.provider.agentName) sessions yet", systemImage: "clock.badge.questionmark")
        } description: {
            Text(
                "Sessions appear as \(store.localActivity?.displayPath ?? "the agent's transcripts") "
                + "fills — and vanish when \(store.provider.agentName)'s own retention cleans them up.")
        }
    }

    /// "Today · Fri, Aug 15" / "Yesterday · …" / "Wed, Aug 13".
    static func dayLabel(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        let label = formatter.string(from: day)
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today · \(label)" }
        if calendar.isDateInYesterday(day) { return "Yesterday · \(label)" }
        return label
    }

    /// Priced total across the session's models; unpriced models are counted,
    /// never silently $0.
    static func cost(of session: SessionSummary, pricing: PricingTable)
        -> (dollars: Double, unpricedModels: Int)
    {
        var dollars = 0.0
        var unpriced = 0
        for (model, tally) in session.models {
            if let rates = pricing.rates(for: model) {
                dollars += rates.dollars(for: tally)
            } else {
                unpriced += 1
            }
        }
        return (dollars, unpriced)
    }
}

private func plural(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}

// MARK: - Sidebar row

/// One session's nutrition card: title + cost, place + when, models + counts.
private struct SessionRow: View {
    let session: SessionSummary
    let cost: (dollars: Double, unpricedModels: Int)
    let colors: [String: Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(costText)
                    .font(.callout.weight(.bold))
                    .monospacedDigit()
            }
            HStack(spacing: 6) {
                Text(place)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(when)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    ForEach(dotModels, id: \.self) { model in
                        Circle()
                            .fill(colors[model] ?? .secondary)
                            .frame(width: 7, height: 7)
                    }
                }
                Text("\(TokenFormat.compact(session.totalTokens)) tokens")
                Text("\(plural(session.prompts, "prompt")) · \(plural(session.apiCalls, "call"))")
                Spacer(minLength: 0)
                if session.kind == .background {
                    Text("background")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .opacity(session.kind == .background ? 0.62 : 1)
    }

    private var costText: String {
        cost.unpricedModels > 0 && cost.dollars == 0
            ? "—" : UsageFormatting.money(cost.dollars)
    }

    /// Heaviest models first, capped at four dots.
    private var dotModels: [String] {
        session.models
            .sorted { $0.value.total > $1.value.total }
            .prefix(4)
            .map(\.key)
    }

    private var place: String {
        let path = (session.projectPath ?? "").replacingOccurrences(
            of: NSHomeDirectory(), with: "~")
        let repo = path.isEmpty ? "—" : (path as NSString).lastPathComponent
        if let branch = session.gitBranch { return "\(repo) · \(branch)" }
        return repo
    }

    private var when: String {
        let stamp = UsageFormatting.clockTime(session.start)
        let active = session.activeSeconds > 0
            ? UsageFormatting.duration(session.activeSeconds) : "—"
        return "\(stamp) · \(active)"
    }
}

// MARK: - Detail

/// The detail page for one selected session. The full parse runs off-main on
/// selection (and re-runs when a live session's scan advances its `end`);
/// cancellation propagates so rapid sidebar clicks never stack parses.
private struct SessionDetailPane: View {
    var store: UsageStore
    let summary: SessionSummary
    let colors: [String: Color]

    @State private var detail: SessionDetail?
    @State private var ledger: [SessionLedger.Entry] = []
    @State private var vanished = false
    @State private var hoveredModel: String?

    private struct DetailKey: Equatable {
        let id: String
        let end: Date
    }

    var body: some View {
        Group {
            if let detail {
                loaded(detail)
            } else if vanished {
                ContentUnavailableView(
                    "Transcript no longer on disk",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(
                        "\(store.provider.agentName)'s own retention removed this "
                        + "session's transcript; its numbers left with it."))
            } else {
                ProgressView("Reading transcript…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: DetailKey(id: summary.id, end: summary.end)) {
            let result = await store.sessionDetail(id: summary.id)
            if Task.isCancelled { return }
            if let result {
                ledger = SessionLedger.runningCost(rows: result.rows, pricing: store.pricing)
                detail = result
                vanished = false
            } else {
                detail = nil
                ledger = []
                vanished = true
            }
        }
    }

    private func loaded(_ detail: SessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(detail.summary)
                .padding(.horizontal, 18)
                .padding(.top, 14)
            ModelBreakdownGrid(
                rows: WindowTokens.rows(from: detail.summary.models),
                colors: colors,
                pricing: store.pricing,
                hoveredModel: $hoveredModel)
                .padding(.horizontal, 18)
                .padding(.top, 10)
            sparkline
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            Divider()
            columnHeader
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(detail.rows) { row in
                        messageRow(row)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func header(_ summary: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary.title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 6) {
                GridRow {
                    metaCell("Repository", path(summary.projectPath))
                    metaCell("Branch", summary.gitBranch ?? "—")
                    // The id's tail: rollout stems share their whole prefix,
                    // and a uuid's last block is as unique as its first.
                    metaCell("Session", String(summary.id.suffix(8)), mono: true)
                }
                GridRow {
                    metaCell("Started", started(summary))
                    metaCell("Active", active(summary))
                    metaCell(
                        "Agent",
                        summary.agentVersion.map { "\(store.provider.agentName) \($0)" }
                            ?? store.provider.agentName)
                }
            }
            Text(counters(summary))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func metaCell(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(mono ? .caption.monospaced() : .callout)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .gridColumnAlignment(.leading)
    }

    private func path(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        return raw.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func started(_ summary: SessionSummary) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d HH:mm"
        return formatter.string(from: summary.start)
    }

    private func active(_ summary: SessionSummary) -> String {
        guard summary.activeSeconds > 0 else { return "—" }
        let active = UsageFormatting.duration(summary.activeSeconds)
        let span = summary.end.timeIntervalSince(summary.start)
        guard span > summary.activeSeconds * 1.5 else { return active }
        return "\(active) of \(UsageFormatting.duration(span))"
    }

    private func counters(_ summary: SessionSummary) -> String {
        var parts = [
            plural(summary.prompts, "prompt"),
            "\(summary.apiCalls) API call\(summary.apiCalls == 1 ? "" : "s")",
            plural(summary.toolCalls, "tool call"),
        ]
        if summary.subagentCount > 0 { parts.append(plural(summary.subagentCount, "subagent run")) }
        if summary.compactions > 0 { parts.append(plural(summary.compactions, "compaction")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Running-cost sparkline

    private var sparkPoints: [(t: Date, running: Double)] {
        guard let rows = detail?.rows, !rows.isEmpty, ledger.count == rows.count
        else { return [] }
        var points: [(Date, Double)] = []
        for (index, row) in rows.enumerated()
        where ledger[index].incremental != nil {
            points.append((row.t, ledger[index].running))
        }
        guard points.count > 200 else { return points }
        let stride = Double(points.count) / 200
        var thinned = (0..<200).map { points[Int(Double($0) * stride)] }
        thinned.append(points[points.count - 1])
        return thinned
    }

    @ViewBuilder private var sparkline: some View {
        let points = sparkPoints
        if points.count > 1, let last = points.last {
            HStack(spacing: 10) {
                Text("RUNNING COST")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Chart(Array(points.enumerated()), id: \.offset) { _, point in
                    AreaMark(
                        x: .value("Time", point.t),
                        y: .value("Cost", point.running))
                        .foregroundStyle(
                            .linearGradient(
                                colors: [
                                    ProviderStyle.accentColor.opacity(0.28),
                                    ProviderStyle.accentColor.opacity(0.02),
                                ],
                                startPoint: .top, endPoint: .bottom))
                    LineMark(
                        x: .value("Time", point.t),
                        y: .value("Cost", point.running))
                        .foregroundStyle(ProviderStyle.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 44)
                Text(UsageFormatting.money(last.running))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ProviderStyle.accentColor)
                    .monospacedDigit()
            }
        }
    }

    // MARK: Message rows

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("TIME").frame(width: Column.time, alignment: .leading)
            Text("MESSAGE").frame(maxWidth: .infinity, alignment: .leading)
            Text("INPUT").frame(width: Column.tokens, alignment: .trailing)
            Text("CACHED").frame(width: Column.tokens, alignment: .trailing)
            Text("OUTPUT").frame(width: Column.output, alignment: .trailing)
            Text("COST").frame(width: Column.cost, alignment: .trailing)
            Text("RUNNING").frame(width: Column.running, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 18)
        .padding(.vertical, 5)
    }

    private enum Column {
        static let time: CGFloat = 40
        static let tokens: CGFloat = 56
        static let output: CGFloat = 48
        static let cost: CGFloat = 58
        static let running: CGFloat = 64
    }

    @ViewBuilder private func messageRow(_ row: SessionEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(UsageFormatting.clockTime(row.t))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(width: Column.time, alignment: .leading)
            switch row.kind {
            case .prompt(let preview):
                (Text("❯ ").foregroundStyle(ProviderStyle.accentColor).bold()
                    + Text(preview))
                    .font(.caption)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .command(let name):
                Text(name)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .compaction:
                Text("⟲ compacted — continued with summarized context")
                    .font(.caption.italic())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .apiCall(let model, let tally, let toolUses):
                callColumns(row: row, model: model, tally: tally, toolUses: toolUses)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 2.5)
        .background(rowBackground(row))
    }

    private func callColumns(
        row: SessionEvent, model: String, tally: TokenTally, toolUses: Int
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(colors[model] ?? .secondary)
                    .frame(width: 7, height: 7)
                Text(ModelNames.display(model))
                    .font(.caption.weight(.semibold))
                if toolUses > 0 {
                    Text("· \(toolUses) tool\(toolUses > 1 ? "s" : "")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(TokenFormat.compact(tally.inputSide))
                .frame(width: Column.tokens, alignment: .trailing)
            Text(TokenFormat.compact(tally.cacheRead))
                .frame(width: Column.tokens, alignment: .trailing)
            Text(TokenFormat.compact(tally.output))
                .frame(width: Column.output, alignment: .trailing)
            Group {
                if let entry = entry(for: row), let incremental = entry.incremental {
                    Text("+\(UsageFormatting.money(incremental))")
                } else {
                    Text("—")
                }
            }
            .frame(width: Column.cost, alignment: .trailing)
            Text(entry(for: row).map { UsageFormatting.money($0.running) } ?? "")
                .foregroundStyle(.secondary)
                .frame(width: Column.running, alignment: .trailing)
        }
        .font(.caption)
        .monospacedDigit()
    }

    private func entry(for row: SessionEvent) -> SessionLedger.Entry? {
        ledger.indices.contains(row.id) ? ledger[row.id] : nil
    }

    @ViewBuilder private func rowBackground(_ row: SessionEvent) -> some View {
        if case .prompt = row.kind {
            ProviderStyle.accentColor.opacity(0.06)
        } else {
            Color.clear
        }
    }
}
