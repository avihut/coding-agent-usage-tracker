import SwiftUI
import UsageCore

/// The Sessions browser: a sidebar of per-session "nutrition cards" ordered
/// by last activity, and a detail page with totals, a running-cost curve,
/// and the message-by-message breakdown.
struct SessionsView: View {
    var store: UsageStore
    var registry: ProviderRegistry
    var navigator: SessionsNavigator

    @State private var selectedID: String?
    @State private var hoveredID: String?
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
            ScrollViewReader { proxy in
                List(selection: $selectedID) {
                    ForEach(SessionDayGroup.build(visibleSessions, calendar: .current)) { group in
                        Section(Self.dayLabel(group.day)) {
                            ForEach(group.sessions) { session in
                                SessionRow(
                                    session: session,
                                    cost: Self.cost(of: session, pricing: store.pricing),
                                    colors: colors
                                )
                                // The panel shortlist's hover grammar, minus
                                // its click chrome; quiet on the selected row,
                                // where the system highlight already speaks.
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

    /// Applies a pending outside selection request: land the sidebar on the
    /// session and consume the request. The shortlist only offers interactive
    /// sessions, which the background filter never hides.
    private func applyNavigation(_ proxy: ScrollViewProxy) {
        guard let id = navigator.requested else { return }
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
