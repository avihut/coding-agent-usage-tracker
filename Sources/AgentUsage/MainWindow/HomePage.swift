import SwiftUI
import UsageCore

/// Every shown account at a glance — the panel's stacked form, as tiles in
/// the window's flow: one tile per account (who, on what, how fresh, its
/// limits), then Activity and Sessions for the account the menu bar is
/// focused on. A narrow window stacks them like the panel; a wide one lays
/// the accounts side by side.
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
                .padding(16)
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

    private var accounts: [(profile: Profile, store: UsageStore)] {
        registry.shownProfiles.compactMap { profile in
            registry.store(for: profile.key).map { (profile, $0) }
        }
    }

    var body: some View {
        let focused = registry.focusedStore
        VStack(alignment: .leading, spacing: 16) {
            NoticesBand(
                registry: registry, store: focused,
                onOpenMeterHistory: { label, _ in openFocused(meterLabel: label) },
                onOpenAccounts: {})
            ForEach(incidentStores, id: \.profile.key) { owner in
                if let card = owner.serviceStatus {
                    ServiceStatusBanner(card: card)
                }
            }
            DashboardFlow {
                ForEach(accounts, id: \.profile.key) { account in
                    DashboardTile { accountTile(account.profile, store: account.store) }
                        .environment(\.harnessStyle, account.store.style)
                }
                DashboardTile {
                    focusCaption("Activity")
                    activity(focused)
                }
                .environment(\.harnessStyle, focused.style)
                if focused.providesSessions {
                    DashboardTile {
                        focusCaption("Sessions")
                        SessionsShortlistSection(
                            store: focused, activityFocus: activityFocus,
                            onOpenSessions: { onOpenSessions(focused.profile.key, nil) },
                            onOpenSession: { onOpenSessions(focused.profile.key, $0) })
                    }
                    .environment(\.harnessStyle, focused.style)
                }
            }
        }
        .environment(\.faceDensity, .window)
        .onChange(of: registry.focusedID) { activityFocus = nil }
    }

    // MARK: - One account

    @ViewBuilder private func accountTile(_ profile: Profile, store: UsageStore) -> some View {
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
        case .live(let snapshot), .cached(let snapshot, _):
            VStack(alignment: .leading, spacing: 12) {
                ForEach(snapshot.meters) { meter in
                    meterCell(meter, profile: profile, store: store)
                }
            }
            if snapshot.meters.isEmpty {
                Text("No limits reported").foregroundStyle(.secondary)
            }
            if let spend = snapshot.spendLine {
                HStack {
                    Text("Credits").foregroundStyle(.secondary)
                    Spacer()
                    Text(spend.formatted).monospacedDigit()
                }
                .font(.subheadline)
            }
        case .unavailable:
            EmptyView()
        }
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

    /// Whose activity and sessions these are, once there is a choice: the
    /// account the menu bar shows.
    @ViewBuilder private func focusCaption(_ section: String) -> some View {
        if registry.shownProfiles.count > 1, let profile = registry.focusedProfile {
            Text("\(section) shows \(registry.rowTitle(for: profile).title), as the menu bar does")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func activity(_ store: UsageStore) -> some View {
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
            // A focus change swaps the account; nothing of the last one's
            // drill or page survives.
            .id(registry.focusedID)
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

/// An account's head on Home: its tile and name, how fresh its numbers are,
/// and what it is — agent, sign-in, plan — on the line under. A click opens
/// its page.
struct AccountHeader: View {
    var registry: ProviderRegistry
    let profile: Profile
    let store: UsageStore
    let onOpen: () -> Void

    private var focused: Bool { profile.key == registry.focusedID }

    var body: some View {
        let name = registry.rowTitle(for: profile)
        let lone = registry.isLoneInHarness(profile)
        HStack(alignment: .center, spacing: 10) {
            if lone {
                HarnessTile(style: store.style, focused: focused, size: 28)
            } else {
                MonogramTile(monogram: registry.monogram(for: profile), focused: focused, size: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        freshness(now: context.date).font(.footnote)
                    }
                }
                let detail = detail(name: name, lone: lone)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .contentShape(Rectangle())
        .pointerStyle(.link)
        .onTapGesture(perform: onOpen)
        .help("Open \(name.title)")
    }

    /// "<agent> · <sign-in> · <plan>" under an account's own name; the
    /// sign-in and plan alone under an agent's.
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
