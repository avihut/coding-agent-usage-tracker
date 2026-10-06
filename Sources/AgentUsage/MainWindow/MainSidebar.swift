import SwiftUI
import UsageCore

/// The window's source list — the panel's account strip, given a column:
/// Home, then one section per harness with its accounts, each row its tile,
/// its name and its meters in miniature. The strip's accent rule still
/// means "focused in the menu bar", which is a different thing from
/// selected here.
struct MainSidebar: View {
    var registry: ProviderRegistry
    @Binding var selection: String?
    let onOpenSettings: () -> Void

    private var profiles: [Profile] { registry.shownProfiles }

    var body: some View {
        List(selection: $selection) {
            if profiles.count > 1 {
                Label("Home", systemImage: "house")
                    .tag(MainWindowView.homeSelection)
            }
            // The strip's rule: a harness with several accounts gets a
            // heading over their names; a lone account's row already says
            // its agent, so its section has none.
            ForEach(ProfileGroups.byHarness(profiles), id: \.providerID) { group in
                if group.profiles.count > 1 {
                    Section(agentName(group.providerID)) { rows(group.profiles) }
                } else {
                    Section { rows(group.profiles) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MainSidebarFooter(registry: registry, onOpenSettings: onOpenSettings)
        }
    }

    private func rows(_ profiles: [Profile]) -> some View {
        ForEach(profiles, id: \.key) { profile in
            MainSidebarRow(registry: registry, profile: profile)
                .tag(profile.key)
                .contextMenu { contextMenu(for: profile) }
        }
    }

    private func agentName(_ providerID: String) -> String {
        registry.providers.first { $0.id == providerID }?.agentName ?? providerID
    }

    @ViewBuilder private func contextMenu(for profile: Profile) -> some View {
        Button("Show in Menu Bar") { registry.focus(profile.key) }
            .disabled(registry.pinnedID == profile.key)
        Button("Follow Activity") { registry.pin(nil) }
            .disabled(registry.pinnedID == nil)
    }
}

/// One account in the sidebar: the strip row's vocabulary at sidebar size.
struct MainSidebarRow: View {
    var registry: ProviderRegistry
    let profile: Profile

    private var store: UsageStore? { registry.store(for: profile.key) }
    private var focused: Bool { profile.key == registry.focusedID }
    private var style: HarnessStyle {
        store?.style ?? HarnessStyle(registry.provider(for: profile))
    }

    var body: some View {
        let name = registry.rowTitle(for: profile)
        HStack(spacing: 7) {
            // The strip's "in the menu bar" rule, at the row's leading edge.
            Capsule()
                .fill(focused ? AnyShapeStyle(style.accentColor) : AnyShapeStyle(.clear))
                .frame(width: 2, height: 16)
            if registry.isLoneInHarness(profile) {
                HarnessTile(style: style, focused: focused, size: 20)
            } else {
                MonogramTile(monogram: registry.monogram(for: profile), focused: focused, size: 20)
            }
            Text(name.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            MiniMeterBars(segments: segments, stale: store?.state.isStale ?? true)
        }
        .help(registry.qualifiedLabel(for: profile))
    }

    private var segments: [MenuBarSegment] {
        guard let store, let meters = store.state.snapshot?.meters else { return [] }
        return UsageFormatting.menuBarSegments(from: meters, predictions: store.predictions)
    }
}

/// The sidebar's foot: each shown harness's service status — a click shows
/// the vendor's card, as the panel footer's dot does — and the version with
/// its update chip. What the panel's footer says, where a window keeps it.
struct MainSidebarFooter: View {
    var registry: ProviderRegistry
    let onOpenSettings: () -> Void
    /// The harness whose status card is up, if any.
    @State private var openStatus: String?

    /// One face per shown harness, for its vendor's status card.
    private var harnessStores: [UsageStore] {
        ProfileGroups.byHarness(registry.shownProfiles)
            .compactMap { registry.store(ofHarness: $0.providerID) }
            .filter { $0.serviceStatus != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(harnessStores, id: \.profile.key) { owner in
                if let card = owner.serviceStatus {
                    Button {
                        openStatus = openStatus == owner.provider.id ? nil : owner.provider.id
                    } label: {
                        HStack(spacing: 6) {
                            ServiceStatusDot(indicator: card.indicatorValue, diameter: 8)
                            Text(owner.provider.agentName)
                            Text(ServiceStatusStyle.headline(card))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .font(.footnote)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .help(ServiceStatusStyle.headline(card))
                    .popover(
                        isPresented: Binding(
                            get: { openStatus == owner.provider.id },
                            set: { if !$0, openStatus == owner.provider.id { openStatus = nil } }),
                        arrowEdge: .trailing
                    ) {
                        ServiceStatusPopover(card: card)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(AppIdentity.displayName) \(AppIdentity.version)")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                UpdateChip(store: registry.focusedStore, onOpenSettings: onOpenSettings)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
