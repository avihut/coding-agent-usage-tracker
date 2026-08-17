import SwiftUI
import UsageCore

/// The Sessions browser: a sidebar of per-session "nutrition cards" with
/// search and sortable ordering, and a detail page with totals, a
/// running-cost curve, and the message-by-message breakdown. Titles are
/// click-to-rename (`SessionRow`'s opt-in affordance) — custom names live
/// in the store's overlay, and an empty commit restores the derived title.
struct SessionsView: View {
    var store: UsageStore
    var registry: ProviderRegistry
    var navigator: SessionsNavigator

    @State private var selectedID: String?
    @State private var hoveredID: String?
    /// The row whose title is currently a text field.
    @State private var editingID: String?
    @State private var query = ""
    /// User decision: background runs are visible by default, badged and
    /// dimmed; the toggle lets them be hidden.
    @AppStorage("sessionsShowBackground") private var showBackground = true
    @AppStorage("sessionsSortKey") private var sortKeyRaw = SessionSortKey.recency.rawValue
    @AppStorage("sessionsSortAscending") private var sortAscending = false

    private var sortKey: SessionSortKey {
        SessionSortKey(rawValue: sortKeyRaw) ?? .recency
    }

    /// Background filter + search, still in the scan's newest-first order —
    /// `SessionDayGroup.build` relies on that contract; the non-recency
    /// sorts reorder afterwards.
    private var filteredSessions: [SessionSummary] {
        store.sessions.filter { session in
            (showBackground || session.kind == .interactive)
                && SessionOrdering.matches(session, query: query)
        }
    }

    private var visibleSessions: [SessionSummary] {
        SessionOrdering.sorted(
            filteredSessions, by: sortKey, ascending: sortAscending
        ) { session in
            let cost = Self.cost(of: session, pricing: store.pricing)
            return cost.unpricedModels > 0 && cost.dollars == 0 ? nil : cost.dollars
        }
    }

    /// Day sections only make sense on the recency axis; ascending shows
    /// the oldest day first with each day's oldest session first.
    private var recencyGroups: [SessionDayGroup.Group] {
        let groups = SessionDayGroup.build(filteredSessions, calendar: .current)
        guard sortAscending else { return groups }
        return groups.reversed().map {
            SessionDayGroup.Group(day: $0.day, sessions: $0.sessions.reversed())
        }
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
            controls
            Divider()
            ScrollViewReader { proxy in
                List(selection: $selectedID) {
                    if filteredSessions.isEmpty, !store.sessions.isEmpty {
                        Text("No sessions match \"\(query)\"")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if sortKey == .recency {
                        ForEach(recencyGroups) { group in
                            Section(Self.dayLabel(group.day)) {
                                ForEach(group.sessions) { session in
                                    row(session, colors: colors)
                                }
                            }
                        }
                    } else {
                        ForEach(visibleSessions) { session in
                            row(session, colors: colors)
                        }
                    }
                }
                .listStyle(.sidebar)
                // Both halves of the navigator contract: onAppear catches a
                // request set before the window's first render (fresh window),
                // onChange catches retargeting while it's already open.
                .onAppear { applyNavigation(proxy) }
                .onChange(of: navigator.requested) { applyNavigation(proxy) }
            }
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

    /// Search + ordering, one quiet row above the list.
    private var controls: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search sessions", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
            Menu {
                Picker("Sort by", selection: $sortKeyRaw) {
                    ForEach(SessionSortKey.allCases, id: \.rawValue) { key in
                        Text(key.label).tag(key.rawValue)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(sortKey.label)
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort the list")
            Button {
                sortAscending.toggle()
            } label: {
                Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(sortAscending ? "Ascending — click for descending" : "Descending — click for ascending")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func row(_ session: SessionSummary, colors: [String: Color]) -> some View {
        SessionRow(
            session: session,
            cost: Self.cost(of: session, pricing: store.pricing),
            colors: colors,
            sortKey: sortKey,
            isEditingTitle: editingID == session.id,
            onBeginRename: { editingID = session.id },
            onCommitRename: { name in
                // A cancel already cleared the editing state; the text
                // field's focus-loss commit then arrives stale — drop it.
                guard editingID == session.id else { return }
                store.renameSession(id: session.id, to: name)
                editingID = nil
            },
            onCancelRename: {
                if editingID == session.id { editingID = nil }
            }
        )
        // The panel shortlist's hover grammar, minus its click chrome;
        // quiet on the selected row, where the system highlight already
        // speaks.
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(
                    hoveredID == session.id
                        && selectedID != session.id ? 0.06 : 0))
                .padding(.horizontal, -6)
                .padding(.vertical, -2))
        .onHover { inside in
            if inside {
                hoveredID = session.id
            } else if hoveredID == session.id {
                hoveredID = nil
            }
        }
        .tag(session.id)
    }

    /// Applies a pending outside selection request: land the sidebar on the
    /// session and consume the request. The search is cleared so the target
    /// can't be hidden by a stale filter; the shortlist only offers
    /// interactive sessions, which the background filter never hides.
    private func applyNavigation(_ proxy: ScrollViewProxy) {
        guard let id = navigator.requested else { return }
        query = ""
        editingID = nil
        selectedID = id
        proxy.scrollTo(id, anchor: .center)
        navigator.requested = nil
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
