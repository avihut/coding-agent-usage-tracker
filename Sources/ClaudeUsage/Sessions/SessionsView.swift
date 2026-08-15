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

// MARK: - Dashboard header primitives

/// Muted hues for the stat tiles — each tile wears its color as a light
/// wash, a slightly stronger frame, and a corner glyph, desaturated enough
/// to sit quietly in both appearances. The prompts tile uses the provider
/// accent instead: ❯ is already the app's prompt color story.
private enum StatTint {
    static let api = Color(red: 0.31, green: 0.50, blue: 0.79)
    static let tools = Color(red: 0.56, green: 0.41, blue: 0.77)
    static let agents = Color(red: 0.25, green: 0.62, blue: 0.50)
    static let compactions = Color(red: 0.74, green: 0.58, blue: 0.25)
    static let tokens = Color(red: 0.39, green: 0.44, blue: 0.54)
}

/// One dashboard stat: the whole tile wears a light wash of its color
/// under a slightly stronger frame of the same tint, and the tinted
/// glyph, number, and noun stack centered — the glyph gets its own row
/// so no width can collide it with the value. Tiles stretch — each takes
/// an equal share of the row, so the grid fills the header at any width.
private struct StatTile: View {
    let symbol: String
    let tint: Color
    let value: String
    let label: String

    @State private var hovered = false

    /// The KPI number wants a touch more light than the standard label's
    /// 85%-white dark-mode ink; light mode keeps the standard label.
    private static let valueColor = Color(nsColor: NSColor(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.96)
                : .labelColor
        }))

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            VStack(spacing: 1) {
                Text(value)
                    .font(.system(size: 20, weight: .bold).monospacedDigit())
                    .foregroundStyle(Self.valueColor)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(
            // The wash deepens a touch under the cursor — the same quiet
            // lift the model grid's rows give.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(hovered ? 0.16 : 0.1)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.3), lineWidth: 1))
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// Wraps subviews into left-aligned rows the way text wraps words — the
/// context strip's chips flow to the pane's width instead of imposing one.
private struct FlowLayout: Layout {
    var hSpacing: CGFloat = 16
    var vSpacing: CGFloat = 5

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        arrange(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let slots = arrange(in: bounds.width, subviews: subviews).slots
        for (subview, slot) in zip(subviews, slots) {
            subview.place(
                at: CGPoint(x: bounds.minX + slot.x, y: bounds.minY + slot.y),
                proposal: .unspecified)
        }
    }

    private func arrange(
        in width: CGFloat, subviews: Subviews
    ) -> (size: CGSize, slots: [CGPoint]) {
        var slots: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            slots.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x + size.width)
            x += size.width + hSpacing
        }
        return (CGSize(width: maxX, height: y + rowHeight), slots)
    }
}

// MARK: - Skeleton primitives

/// One placeholder bar, matched to the text heights it stands in for. An
/// accent bar suggests a prompt row. `width` is a CAP, never a constant —
/// the text a bar stands in for truncates under pressure, so the bar must
/// compress the same way. A fixed width would give the skeleton a larger
/// minimum than the loaded content and make the split view breathe on
/// every selection change.
private struct SkeletonBar: View {
    var width: CGFloat?
    var height: CGFloat = 9
    var accent = false

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(accent
                ? ProviderStyle.accentColor.opacity(0.14)
                : Color.primary.opacity(0.07))
            .frame(height: height)
            .frame(maxWidth: width, alignment: .leading)
    }
}

/// A gentle breathing pulse over skeleton content — the "still working"
/// signal. Honors Reduce Motion by standing still.
private struct Pulsing<Content: View>: View {
    @ViewBuilder var content: Content

    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .opacity(dimmed ? 0.45 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
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
    @State private var chartModel: SessionChartModel = .empty
    @State private var vanished = false
    @State private var hoveredModel: String?
    /// One hover truth for chart and list — either surface writes it, both
    /// render it (crosshair there, row highlight here).
    @State private var hoveredRow: Int?
    /// The row a chart click just jumped to; its flash fades right back out.
    @State private var flashRow: Int?
    @State private var measure: SessionChartMeasure = .cost
    /// The chart's context-size overlay — a display preference, so it
    /// survives selection switches and relaunches.
    @AppStorage("sessionsShowContext") private var showContext = false

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
                skeleton
            }
        }
        .task(id: DetailKey(id: summary.id, end: summary.end)) {
            // A different session's content must not linger while its parse
            // runs — clear synchronously so the skeleton shows at once. A
            // same-id re-fire (live session, scan moved `end`) keeps the
            // current content and swaps silently when the fresh parse lands.
            if detail?.summary.id != summary.id {
                detail = nil
                ledger = []
                chartModel = .empty
                hoveredRow = nil
                flashRow = nil
                vanished = false
            }
            let result = await store.sessionDetail(id: summary.id)
            if Task.isCancelled { return }
            if let result {
                let entries = SessionLedger.runningCost(rows: result.rows, pricing: store.pricing)
                ledger = entries
                let windows = Dictionary(uniqueKeysWithValues:
                    result.summary.models.keys.compactMap { model in
                        contextWindow(for: model).map { (model, $0) }
                    })
                chartModel = SessionChartModel.build(
                    rows: result.rows, ledger: entries, windows: windows)
                // An all-unpriced session (Codex before the pricing feed) has
                // no cost curve to draw — fall to tokens. A priced session
                // keeps whatever measure the user last picked.
                if (chartModel.runningCost.last ?? 0) <= 0 { measure = .tokens }
                detail = result
                vanished = false
            } else {
                detail = nil
                ledger = []
                chartModel = .empty
                vanished = true
            }
        }
    }

    private func loaded(_ detail: SessionDetail) -> some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                header(detail.summary)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                ModelBreakdownGrid(
                    rows: WindowTokens.rows(from: detail.summary.models),
                    colors: colors,
                    pricing: store.pricing,
                    showsHeadline: false,
                    hoveredModel: $hoveredModel)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                RunningBreakdownChart(
                    model: chartModel,
                    rows: detail.rows,
                    colors: colors,
                    measure: $measure,
                    hoveredRow: $hoveredRow,
                    hoveredModel: $hoveredModel,
                    showContext: $showContext,
                    onSelectRow: { row in jump(to: row, proxy: proxy) })
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                Divider()
                columnHeader
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(detail.rows) { row in
                            messageRow(row)
                                .id(row.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: Skeleton

    /// The loading state while a selection's parse runs. Everything the
    /// sidebar summary already knows renders REAL and instantly — title,
    /// meta grid, per-model totals — and only what the parse owes (chart,
    /// message rows) shows as pulsing placeholders, so a switch never reads
    /// as frozen. Structure mirrors `loaded` exactly — same shells, same
    /// width behavior — so the swap moves nothing but the placeholders.
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(summary)
                .padding(.horizontal, 18)
                .padding(.top, 14)
            ModelBreakdownGrid(
                rows: WindowTokens.rows(from: summary.models),
                colors: colors,
                pricing: store.pricing,
                showsHeadline: false,
                hoveredModel: $hoveredModel)
                .padding(.horizontal, 18)
                .padding(.top, 10)
            if summary.apiCalls > 0 {
                Pulsing { skeletonChart }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }
            Divider()
            columnHeader
            Divider()
            // The same ScrollView shell as the loaded list: a vertical
            // scroll view absorbs its content's width instead of imposing
            // it, so the placeholder rows can never push the pane wider
            // than the rows they stand in for.
            ScrollView {
                Pulsing { skeletonRows }
            }
            .scrollDisabled(true)
        }
    }

    private var skeletonChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SkeletonBar(width: 110, height: 14)
                Spacer()
                SkeletonBar(width: 48, height: 12)
            }
            .frame(height: 18)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .frame(height: 140)
        }
    }

    private var skeletonRows: some View {
        let widths: [CGFloat] = [340, 220, 420, 180, 300, 260]
        return VStack(spacing: 0) {
            ForEach(0..<14, id: \.self) { index in
                HStack(spacing: 8) {
                    SkeletonBar(width: 30)
                        .frame(width: Column.time, alignment: .leading)
                    SkeletonBar(
                        width: widths[index % widths.count],
                        accent: index % widths.count == 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SkeletonBar(width: 36)
                        .frame(width: Column.tokens, alignment: .trailing)
                    SkeletonBar(width: 36)
                        .frame(width: Column.tokens, alignment: .trailing)
                    SkeletonBar(width: 30)
                        .frame(width: Column.output, alignment: .trailing)
                    SkeletonBar(width: 26)
                        .frame(width: Column.ctx, alignment: .trailing)
                    SkeletonBar(width: 38)
                        .frame(width: Column.cost, alignment: .trailing)
                    SkeletonBar(width: 42)
                        .frame(width: Column.running, alignment: .trailing)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 4.5)
            }
        }
        .padding(.vertical, 4)
    }

    /// Chart click → the list centers the clicked message and flashes it,
    /// the flash easing back out on its own.
    private func jump(to row: Int, proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(row, anchor: .center) }
        flashRow = row
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            withAnimation(.easeOut(duration: 0.9)) {
                if flashRow == row { flashRow = nil }
            }
        }
    }

    /// The dashboard header: identity row with the cost KPI top-right, an
    /// icon-led context strip (the glyph is the label), and a full-width
    /// row of stat tiles that stretch equally with the pane. Everything
    /// here derives from the sidebar summary, so the skeleton renders the
    /// whole header real.
    private func header(_ summary: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(summary.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 12)
                costKPI(summary)
            }
            contextStrip(summary)
            statTiles(summary)
        }
    }

    /// The headline number the centered block used to carry, promoted to
    /// dashboard gravity: top-right, on the title's own row.
    private func costKPI(_ summary: SessionSummary) -> some View {
        let cost = SessionsView.cost(of: summary, pricing: store.pricing)
        return VStack(alignment: .trailing, spacing: 1) {
            Text(cost.unpricedModels > 0 && cost.dollars == 0
                ? "—" : "≈ \(UsageFormatting.money(cost.dollars))")
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
            Text(cost.unpricedModels > 0
                ? "at API list prices · \(cost.unpricedModels) unpriced"
                : "at API list prices")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func contextStrip(_ summary: SessionSummary) -> some View {
        FlowLayout(hSpacing: 16, vSpacing: 5) {
            if let project = summary.projectPath, !project.isEmpty {
                chip("folder", path(project))
            }
            if let branch = summary.gitBranch, !branch.isEmpty {
                chip("arrow.triangle.branch", branch)
            }
            chip("calendar", started(summary))
            if summary.activeSeconds > 0 {
                chip("timer", active(summary))
            }
            chip(
                "terminal",
                summary.agentVersion.map { "\(store.provider.agentName) \($0)" }
                    ?? store.provider.agentName)
            // The id's tail: rollout stems share their whole prefix,
            // and a uuid's last block is as unique as its first.
            chip("number", String(summary.id.suffix(8)), mono: true)
        }
    }

    private func chip(_ symbol: String, _ text: String, mono: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(mono ? .caption.monospaced() : .callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// One row, six tiles, equal stretch — the grid always spans the full
    /// header width and breathes with the window.
    private func statTiles(_ summary: SessionSummary) -> some View {
        HStack(spacing: 8) {
            StatTile(
                symbol: "chevron.right", tint: ProviderStyle.accentColor,
                value: summary.prompts.formatted(),
                label: noun(summary.prompts, "prompt"))
            StatTile(
                symbol: "bolt.fill", tint: StatTint.api,
                value: summary.apiCalls.formatted(),
                label: noun(summary.apiCalls, "API call"))
            StatTile(
                symbol: "hammer.fill", tint: StatTint.tools,
                value: summary.toolCalls.formatted(),
                label: noun(summary.toolCalls, "tool call"))
            StatTile(
                symbol: "person.2.fill", tint: StatTint.agents,
                value: summary.subagentCount.formatted(),
                label: noun(summary.subagentCount, "subagent run"))
            StatTile(
                symbol: "arrow.down.right.and.arrow.up.left", tint: StatTint.compactions,
                value: summary.compactions.formatted(),
                label: noun(summary.compactions, "compaction"))
            StatTile(
                symbol: "cylinder.split.1x2.fill", tint: StatTint.tokens,
                value: TokenFormat.compact(summary.totalTokens),
                label: "tokens")
        }
    }

    private func noun(_ count: Int, _ singular: String) -> String {
        count == 1 ? singular : singular + "s"
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

    // MARK: Message rows

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("TIME").frame(width: Column.time, alignment: .leading)
            Text("MESSAGE").frame(maxWidth: .infinity, alignment: .leading)
            Text("INPUT").frame(width: Column.tokens, alignment: .trailing)
            Text("CACHED").frame(width: Column.tokens, alignment: .trailing)
            Text("OUTPUT").frame(width: Column.output, alignment: .trailing)
            Text("CTX").frame(width: Column.ctx, alignment: .trailing)
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
        static let ctx: CGFloat = 40
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
        .opacity(row.subagent ? 0.7 : 1)
        .background(rowBackground(row))
        .onHover { inside in
            if inside {
                hoveredRow = row.id
            } else if hoveredRow == row.id {
                hoveredRow = nil
            }
        }
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
                if row.subagent {
                    Text("· subagent")
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
            Text(contextPercent(model: model, tally: tally))
                .foregroundStyle(.secondary)
                .frame(width: Column.ctx, alignment: .trailing)
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

    /// The model's context window: the live pricing table first; a disk
    /// cache written before windows rode the feed has none, so the bundled
    /// floor answers until the next live fetch. Feeds both the CTX column
    /// and the chart's context overlay.
    private func contextWindow(for model: String) -> Int? {
        store.pricing.rates(for: model)?.contextTokens
            ?? PricingTable.bundled.rates(for: model)?.contextTokens
    }

    /// The call's context footprint as a share of the model's window: the
    /// INPUT column (everything the model read) over the pricing feed's
    /// max_input_tokens. "—" only when nobody knows the window.
    private func contextPercent(model: String, tally: TokenTally) -> String {
        guard let window = contextWindow(for: model), window > 0
        else { return "—" }
        let percent = Double(tally.inputSide) / Double(window) * 100
        if percent > 0, percent < 1 { return "<1%" }
        return "\(Int(percent.rounded()))%"
    }

    /// Layered row grounds: prompts keep their standing tint, the hovered
    /// prompt's whole section echoes the chart's lit stretch, the hovered
    /// row itself sits on top, and a chart-click flash outshines them all
    /// while it fades.
    @ViewBuilder private func rowBackground(_ row: SessionEvent) -> some View {
        ZStack {
            if case .prompt = row.kind {
                ProviderStyle.accentColor.opacity(0.06)
            }
            if hoveredSectionRange?.contains(row.id) == true {
                Color.primary.opacity(0.045)
            }
            if hoveredRow == row.id {
                Color.primary.opacity(0.07)
            }
            if flashRow == row.id {
                ProviderStyle.accentColor.opacity(0.3)
            }
        }
    }

    /// The prompt-to-prompt stretch lit while a prompt row is hovered on
    /// either surface — the list-side echo of the chart's curtained section.
    private var hoveredSectionRange: Range<Int>? {
        guard let hoveredRow, let rows = detail?.rows, rows.indices.contains(hoveredRow),
              case .prompt = rows[hoveredRow].kind
        else { return nil }
        return chartModel.sections.first { $0.promptRow == hoveredRow }?.range
    }
}
