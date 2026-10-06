import SwiftUI
import UsageCore

/// Every shown account at a glance — the panel's stacked form, given room:
/// one block per account (who, on what, how fresh) with its meters laid
/// out in columns by kind (core `MeterColumns`), so "every weekly window"
/// reads straight down. Below, Activity beside Sessions for the account
/// the menu bar is focused on, as the panel shows them.
struct HomePage: View {
    var registry: ProviderRegistry
    @Binding var activityFocus: DateInterval?
    /// Opens an account's page, on one of its meters when one was clicked.
    let onOpenAccount: (_ profileKey: String, _ meterID: String?) -> Void
    let onOpenSessions: (_ profileKey: String, _ sessionID: String?) -> Void

    var body: some View {
        ScrollView {
            HomePageContent(
                registry: registry, activityFocus: $activityFocus,
                onOpenAccount: onOpenAccount, onOpenSessions: onOpenSessions)
                .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Only the focused account's activity is shown, so only it scans.
        .task(id: registry.focusedID) { registry.focusedStore.scanActivity() }
    }
}

/// Home without its scroll view — what the `--snapshot` hatch draws.
struct HomePageContent: View {
    var registry: ProviderRegistry
    @Binding var activityFocus: DateInterval?
    let onOpenAccount: (_ profileKey: String, _ meterID: String?) -> Void
    let onOpenSessions: (_ profileKey: String, _ sessionID: String?) -> Void

    @State private var hoveredMeter: String?

    /// The account page's two columns, so Home and a page share one width.
    private static let columnWidth = AccountPageContent.columnWidth
    private static let columnGap = AccountPageContent.columnGap
    private static let meterGap: CGFloat = 24
    /// Narrower than this and a meter's label and percent crowd each other.
    private static let minMeterWidth: CGFloat = 190

    private var accounts: [(profile: Profile, store: UsageStore)] {
        registry.shownProfiles.compactMap { profile in
            registry.store(for: profile.key).map { (profile, $0) }
        }
    }

    var body: some View {
        let accounts = accounts
        let rows = MeterColumns.arrange(accounts.map { $0.store.state.snapshot?.meters ?? [] })
        let columns = rows.first?.count ?? 0
        let width = max(
            2 * Self.columnWidth + Self.columnGap,
            CGFloat(columns) * Self.minMeterWidth + CGFloat(max(0, columns - 1)) * Self.meterGap)
        let meterWidth = columns > 0
            ? (width - CGFloat(columns - 1) * Self.meterGap) / CGFloat(columns) : width
        VStack(alignment: .leading, spacing: 18) {
            NoticesBand(
                registry: registry, store: registry.focusedStore,
                onOpenMeterHistory: { label, _ in openFocused(meterLabel: label) },
                onOpenAccounts: {})
            ForEach(incidentStores, id: \.profile.key) { owner in
                if let card = owner.serviceStatus {
                    ServiceStatusBanner(card: card)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(accounts.enumerated()), id: \.element.profile.key) { index, account in
                    if index > 0 { Divider() }
                    accountBlock(
                        account.profile, store: account.store,
                        cells: rows.indices.contains(index) ? rows[index] : [],
                        meterWidth: meterWidth)
                }
            }
            .frame(width: width, alignment: .leading)
            Divider().frame(width: width)
            focusedSections
                .frame(width: width, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .environment(\.faceDensity, .window)
    }

    // MARK: - One account

    private func accountBlock(
        _ profile: Profile, store: UsageStore, cells: [Meter?], meterWidth: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AccountHeader(registry: registry, profile: profile, store: store) {
                onOpenAccount(profile.key, nil)
            }
            AccountErrorBlock(store: store)
            switch store.state {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                }
            case .live, .cached:
                HStack(alignment: .top, spacing: Self.meterGap) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, meter in
                        Group {
                            if let meter {
                                meterCell(meter, profile: profile, store: store)
                            } else {
                                // A limit this account doesn't have: nothing,
                                // never an empty bar that reads as 0%.
                                Color.clear.frame(height: 1)
                            }
                        }
                        .frame(width: meterWidth, alignment: .topLeading)
                    }
                }
            case .unavailable:
                EmptyView()
            }
        }
        .environment(\.harnessStyle, store.style)
    }

    private func meterCell(_ meter: Meter, profile: Profile, store: UsageStore) -> some View {
        MeterRow(
            meter: meter,
            stale: store.state.isStale,
            prediction: store.predictions[meter.label],
            overshoot: store.forecastOvershoots[meter.label],
            key: "\(profile.key)|\(meter.id)",
            opensOnHover: false,
            // A click opens the account's page on this meter's card.
            openMeter: Binding(
                get: { nil },
                set: { if $0 != nil { onOpenAccount(profile.key, meter.id) } }),
            hoveredMeter: $hoveredMeter,
            onLeave: {})
            .pointerStyle(.link)
            .help("Open \(registry.rowTitle(for: profile).title) on \(meter.label)")
    }

    // MARK: - The focused account's activity

    @ViewBuilder private var focusedSections: some View {
        let store = registry.focusedStore
        VStack(alignment: .leading, spacing: 10) {
            if registry.shownProfiles.count > 1, let focused = registry.focusedProfile {
                Text("\(registry.rowTitle(for: focused).title), as in the menu bar")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: Self.columnGap) {
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
                    onOpenOutage: { span in
                        guard let url = store.provider.outageDestination(url: span.url) else { return }
                        NSWorkspace.shared.open(url)
                    },
                    sessionAuditMeter: store.auditMeter(rank: 0),
                    weeklyAuditMeter: store.auditMeter(rank: 1),
                    resetsOnPanelClose: false)
                    .frame(width: Self.columnWidth, alignment: .topLeading)
                SessionsShortlistSection(
                    store: store, activityFocus: activityFocus,
                    onOpenSessions: { onOpenSessions(store.profile.key, nil) },
                    onOpenSession: { onOpenSessions(store.profile.key, $0) })
                    .frame(width: Self.columnWidth, alignment: .topLeading)
            }
            .environment(\.harnessStyle, store.style)
        }
        // A focus change crossfades the pair, as the panel does below its strip.
        .id(registry.focusedID)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.16), value: registry.focusedID)
        .onChange(of: registry.focusedID) { activityFocus = nil }
    }

    // MARK: - Helpers

    /// One face per shown harness whose vendor reports an incident that no
    /// pending notice already carries (the panel's rule).
    private var incidentStores: [UsageStore] {
        ProfileGroups.byHarness(registry.shownProfiles)
            .compactMap { registry.store(ofHarness: $0.providerID) }
            .filter { owner in
                guard let card = owner.serviceStatus, card.hasIncident else { return false }
                return !(owner.notices?.items.contains { $0.ownsMenuBarSurface } ?? false)
            }
    }

    /// A reset notice's click-through: the focused account's page, on the
    /// meter it names.
    private func openFocused(meterLabel: String?) {
        let store = registry.focusedStore
        let meter = store.state.snapshot?.meters.first { $0.label == meterLabel }
        onOpenAccount(store.profile.key, meter?.id)
    }
}

/// An account's line on Home: its tile, its name, and what it is — agent,
/// sign-in, plan — with how fresh its numbers are at the far end. A click
/// opens its page.
struct AccountHeader: View {
    var registry: ProviderRegistry
    let profile: Profile
    let store: UsageStore
    let onOpen: () -> Void

    private var focused: Bool { profile.key == registry.focusedID }

    var body: some View {
        let name = registry.rowTitle(for: profile)
        let lone = registry.isLoneInHarness(profile)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if lone {
                    HarnessTile(style: store.style, focused: focused, size: 22)
                } else {
                    MonogramTile(monogram: registry.monogram(for: profile), focused: focused, size: 22)
                }
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            Text(name.title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text(detail(name: name, lone: lone))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                freshness(now: context.date)
                    .font(.footnote)
            }
        }
        .contentShape(Rectangle())
        .pointerStyle(.link)
        .onTapGesture(perform: onOpen)
        .help("Open \(name.title)")
    }

    /// "<agent> · <sign-in> · <plan>" under an account's own
    /// name; the sign-in and plan alone beside an agent's.
    private func detail(name: (title: String, detail: String?), lone: Bool) -> String {
        let agent = lone ? nil : store.provider.agentName
        let signIn = name.detail ?? store.accountPresence?.current?.label
        let plan = store.state.snapshot?.plan?.displayLabel
        return [agent, signIn == name.title ? nil : signIn, plan]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func freshness(now: Date) -> Text {
        guard let fetchedAt = store.state.snapshot?.fetchedAt else {
            return Text(store.isDormant ? "Dormant" : "No data yet").foregroundStyle(.tertiary)
        }
        let stamp = UsageFormatting.updatedStamp(fetchedAt, now: now)
        return store.state.isStale
            ? Text("cached \(stamp)").foregroundStyle(.orange)
            : Text("Updated \(stamp)").foregroundStyle(.secondary)
    }
}
