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
