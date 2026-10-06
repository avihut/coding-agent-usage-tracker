import SwiftUI
import UsageCore

/// One account, the way the panel shows it — given room: its limits beside
/// the chosen meter's card (the panel's hover popover, inline), then its
/// activity beside its sessions. Selecting a limit replaces the card; nothing
/// here opens on hover.
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
                .padding(20)
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

    /// One column is the popover's own width: the activity chart's day
    /// slide is measured at 332pt, and the meter card's plot is 300pt plus
    /// its padding. The page is two of them — the panel's column, and the
    /// hover card pinned beside it — so it keeps the popover's proportions
    /// instead of stretching them.
    static let columnWidth: CGFloat = 340
    static let columnGap: CGFloat = 36

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
        VStack(alignment: .leading, spacing: 18) {
            if let card = store.serviceStatus, card.hasIncident {
                ServiceStatusBanner(card: card)
            }
            AccountErrorBlock(store: store)
            // Two columns while they fit, one under the other when the
            // window is too narrow for both.
            ViewThatFits(in: .horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: Self.columnGap, verticalSpacing: 18) {
                    GridRow {
                        column(limits)
                        column(card)
                    }
                    GridRow {
                        Divider().frame(width: Self.columnWidth)
                        Divider().frame(width: Self.columnWidth)
                    }
                    GridRow {
                        column(activity)
                        column(sessions)
                    }
                }
                VStack(alignment: .leading, spacing: 18) {
                    column(limits)
                    column(card)
                    Divider().frame(width: Self.columnWidth)
                    column(activity)
                    column(sessions)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .environment(\.faceDensity, .window)
        .environment(\.harnessStyle, store.style)
    }

    private func column(_ content: some View) -> some View {
        content.frame(width: Self.columnWidth, alignment: .topLeading)
    }

    @ViewBuilder private var card: some View {
        if let meter = chosenMeter {
            meterCard(meter)
        }
    }

    private var sessions: some View {
        SessionsShortlistSection(
            store: store, activityFocus: activityFocus,
            onOpenSessions: onOpenSessions, onOpenSession: onOpenSession)
    }

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

    // MARK: - Limits

    @ViewBuilder private var limits: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                VStack(alignment: .leading, spacing: 14) {
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
            case .unavailable:
                EmptyView() // the error block above says why
            }
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
            onOpenOutage: openOutage)
            // A fresh card per meter: its paging and hover state belong to
            // the meter it was opened on.
            .id("\(profile.key)|\(meter.id)")
            // Unboxed, like every other section of the page: the card's own
            // 10pt inset is handed back so its header lines up with Limits'.
            .padding(-10)
    }

    private func openOutage(_ span: OutageSpan) {
        guard let url = store.provider.outageDestination(url: span.url) else { return }
        NSWorkspace.shared.open(url)
    }
}
