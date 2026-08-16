import SwiftUI
import UsageCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, usage, apiCost

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .usage: "Usage"
        case .apiCost: "API Cost"
        }
    }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .usage: "chart.xyaxis.line"
        case .apiCost: "dollarsign.circle"
        }
    }
}

/// The settings window: sidebar navigation on the left, one pane on the
/// right — general behavior, and the API-cost page (where the pricing data
/// comes from, how the estimate is computed, and a what-if playground).
struct SettingsView: View {
    var store: UsageStore
    var registry: ProviderRegistry

    @State private var section: SettingsSection?

    init(
        store: UsageStore, registry: ProviderRegistry,
        initialSection: SettingsSection = .general
    ) {
        self.store = store
        self.registry = registry
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(SettingsSection.allCases) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            switch section ?? .general {
            case .general: GeneralSettingsPane(store: store, registry: registry)
            case .usage: UsageSettingsPane(store: store)
            case .apiCost: CostSettingsPane(store: store)
            }
        }
        // A settings window's sidebar is permanent — no collapse toggle.
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 760, minHeight: 600)
    }
}
