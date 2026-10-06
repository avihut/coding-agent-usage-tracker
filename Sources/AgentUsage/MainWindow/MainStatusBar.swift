import SwiftUI
import UsageCore

/// The window's bottom edge: the shown account's pipeline line (the panel's
/// status row), one status dot per shown harness, and the version with its
/// update chip — what the panel's footer says, set as a status bar.
struct MainStatusBar: View {
    var registry: ProviderRegistry
    let store: UsageStore
    let onOpenSettings: () -> Void
    /// The harness whose status card is up, if any.
    @State private var openStatus: String?

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
                        // The panel footer's dot: a click shows the vendor's
                        // status card, which a status bar has the room to name.
                        Button {
                            openStatus = openStatus == owner.provider.id ? nil : owner.provider.id
                        } label: {
                            HStack(spacing: 4) {
                                ServiceStatusDot(indicator: card.indicatorValue, diameter: 8)
                                Text(owner.provider.agentName)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                        .help(ServiceStatusStyle.headline(card))
                        .popover(
                            isPresented: Binding(
                                get: { openStatus == owner.provider.id },
                                set: { if !$0, openStatus == owner.provider.id { openStatus = nil } }),
                            arrowEdge: .top
                        ) {
                            ServiceStatusPopover(card: card)
                        }
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
