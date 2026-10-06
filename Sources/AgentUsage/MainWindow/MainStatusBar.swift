import SwiftUI
import UsageCore

/// The window's bottom edge: the shown account's pipeline line (the panel's
/// status row), one status dot per shown harness, and the version with its
/// update chip — what the panel's footer says, set as a status bar.
struct MainStatusBar: View {
    var registry: ProviderRegistry
    let store: UsageStore
    let onOpenSettings: () -> Void

    /// One face per shown harness, for its vendor's status card.
    private var harnessStores: [UsageStore] {
        ProfileGroups.byHarness(registry.shownProfiles)
            .compactMap { registry.store(ofHarness: $0.providerID) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                AccountStatusLine(store: store)
                Spacer(minLength: 12)
                ForEach(harnessStores, id: \.profile.key) { owner in
                    if let card = owner.serviceStatus {
                        HStack(spacing: 4) {
                            ServiceStatusDot(indicator: card.indicatorValue, diameter: 8)
                            Text(owner.provider.agentName)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .help(ServiceStatusStyle.headline(card))
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("v\(AppIdentity.version)")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                    UpdateChip(store: store, onOpenSettings: onOpenSettings)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .environment(\.faceDensity, .window)
    }
}
