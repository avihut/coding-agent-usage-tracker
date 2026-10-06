import SwiftUI
import UsageCore

/// One account, the way the panel shows it — its limits, the selected
/// limit's card (the panel's hover popover, pinned), its activity and its
/// sessions — as tiles in the window's flow: one column in a narrow window,
/// the popover's own order, and side by side as the window widens.
/// Selecting a limit replaces the card; nothing here opens on hover.
struct AccountPage: View {
    var registry: ProviderRegistry
    let profile: Profile
    let store: UsageStore
    @Binding var chosenMeterID: String?
    @Binding var activityFocus: DateInterval?
    let onOpenSessions: () -> Void
    let onOpenSession: (String) -> Void

    var body: some View {
        ScrollView {
            AccountPageContent(
                registry: registry, profile: profile, store: store,
                chosenMeterID: $chosenMeterID, activityFocus: $activityFocus,
                onOpenSessions: onOpenSessions, onOpenSession: onOpenSession)
                .padding(16)
        }
        .scrollBounceBehavior(.basedOnSize)
        // The panel scans on open; a page scans on appear, and only its own
        // account — never every account at once.
        .task(id: profile.key) { store.scanActivity() }
    }
}

/// The page without its scroll view — what the `--snapshot` hatch draws
/// (an off-screen window renders a ScrollView's content blank).
struct AccountPageContent: View {
    var registry: ProviderRegistry
    let profile: Profile
    let store: UsageStore
    @Binding var chosenMeterID: String?
    @Binding var activityFocus: DateInterval?
    let onOpenSessions: () -> Void
    let onOpenSession: (String) -> Void

    @State private var hoveredMeter: String?
    /// The card tile's inner width, which its plot takes.
    @State private var cardWidth: CGFloat = 332

    private var meters: [Meter] { store.state.snapshot?.meters ?? [] }

    /// The person's pick, else the meter most at risk, else the weekly one,
    /// else the first — the card that answers "should I worry".
    private var chosenMeter: Meter? {
        if let chosenMeterID, let meter = meters.first(where: { $0.id == chosenMeterID }) {
            return meter
        }
        let atRisk = meters
            .compactMap { meter in store.predictions[meter.label].map { (meter, $0.severity) } }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }
        return atRisk?.0 ?? meters.first { $0.rank == 1 } ?? meters.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let card = store.serviceStatus, card.hasIncident {
                ServiceStatusBanner(card: card)
            }
            AccountErrorBlock(store: store)
            DashboardFlow {
                DashboardTile { limits }
                if let meter = chosenMeter {
                    DashboardTile { meterCard(meter) }
                }
                DashboardTile { activity }
                if store.providesSessions {
                    DashboardTile {
                        SessionsShortlistSection(
                            store: store, activityFocus: activityFocus,
                            onOpenSessions: onOpenSessions, onOpenSession: onOpenSession)
                    }
                }
            }
        }
        .environment(\.faceDensity, .window)
        .environment(\.harnessStyle, store.style)
    }

    // MARK: - Limits

    @ViewBuilder private var limits: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Limits").font(.headline)
            Spacer()
            planLink
        }
        switch store.state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…").foregroundStyle(.secondary)
            }
        case .live(let snapshot), .cached(let snapshot, _):
            VStack(alignment: .leading, spacing: 12) {
                ForEach(snapshot.meters) { meter in
                    MeterRow(
                        meter: meter,
                        stale: store.state.isStale,
                        prediction: store.predictions[meter.label],
                        overshoot: store.forecastOvershoots[meter.label],
                        opensOnHover: false,
                        openMeter: Binding(
                            get: { chosenMeter?.id },
                            set: { if let id = $0 { chosenMeterID = id } }),
                        hoveredMeter: $hoveredMeter,
                        onLeave: {})
                }
            }
            if snapshot.meters.isEmpty {
                Text("No limits reported").foregroundStyle(.secondary)
            }
            if let spend = snapshot.spendLine {
                Divider()
                HStack {
                    Text("Credits").foregroundStyle(.secondary)
                    Spacer()
                    Text(spend.formatted).monospacedDigit()
                }
            }
            // Where the panel has it: right under the meters it describes.
            AccountStatusLine(store: store)
        case .unavailable:
            EmptyView() // the error block above says why
        }
    }

    /// The plan, linked to its upgrade page where the provider has one —
    /// absent for a harness that reports no plan.
    @ViewBuilder private var planLink: some View {
        if let plan = store.state.snapshot?.plan?.displayLabel {
            if let upgrade = store.provider.links.planUpgrade {
                Link(destination: upgrade) {
                    Label(plan, systemImage: "arrow.up.right")
                        .labelStyle(.titleAndIcon)
                }
                .font(.subheadline)
                .help("Choose your plan on \(upgrade.host() ?? store.provider.serviceName)")
            } else {
                Text(plan).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - The meter card

    /// The hover card at the tile's width. The card draws its own 10pt inset;
    /// it is handed back so the card's title lines up with every other
    /// tile's, and its plot takes exactly the tile's inner width.
    private func meterCard(_ meter: Meter) -> some View {
        MeterHistoryView(
            meter: meter, samples: store.samples,
            timeline: store.tokenTimeline, pricing: store.pricing,
            prediction: store.predictions[meter.label],
            overshoot: store.forecastOvershoots[meter.label],
            outcomes: store.windowOutcomes,
            agentName: store.provider.agentName,
            // The popover's key, so span and frame choices are shared with it.
            providerID: store.profile.scopeKey,
            style: store.style,
            outages: store.outages,
            onOpenOutage: openOutage,
            chartWidth: max(MeterHistoryView.chartWidth, cardWidth))
            // A fresh card per meter: its paging and hover state belong to
            // the meter it was opened on.
            .id("\(profile.key)|\(meter.id)")
            .padding(-10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .reportingWidth($cardWidth)
    }

    // MARK: - Activity

    private var activity: some View {
        HeatmapView(
            activity: store.activity, pricing: store.pricing,
            weeklyProfile: store.weeklyProfile,
            agentName: store.provider.agentName,
            style: store.style,
            focus: $activityFocus,
            samples: store.samples,
            timeline: store.tokenTimeline,
            sessions: store.sessions,
            windowOutcomes: store.windowOutcomes,
            outages: store.outages,
            onOpenOutage: openOutage,
            sessionAuditMeter: store.auditMeter(rank: 0),
            weeklyAuditMeter: store.auditMeter(rank: 1),
            resetsOnPanelClose: false)
    }

    private func openOutage(_ span: OutageSpan) {
        guard let url = store.provider.outageDestination(url: span.url) else { return }
        NSWorkspace.shared.open(url)
    }
}
