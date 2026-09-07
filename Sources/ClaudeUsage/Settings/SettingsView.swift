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
    var registry: ProviderRegistry
    var navigator: SettingsNavigator

    @State private var section: SettingsSection?

    /// The focused account's face — the panes read one account at a time,
    /// the way the panel does.
    private var store: UsageStore { registry.focusedStore }

    init(
        registry: ProviderRegistry, navigator: SettingsNavigator,
        initialSection: SettingsSection = .general
    ) {
        self.registry = registry
        self.navigator = navigator
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
            case .general: GeneralSettingsPane(store: store, registry: registry, navigator: navigator)
            case .usage: UsageSettingsPane(store: store)
            case .apiCost: CostSettingsPane(store: store)
            }
        }
        // A request landing while the window is already open retargets it
        // (the consume-once idiom: the pane takes the landing from here).
        .onChange(of: navigator.requestedSection) { _, requested in
            if let requested = navigator.consumeSection() { section = requested }
            _ = requested
        }
        // A settings window's sidebar is permanent — no collapse toggle.
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 760, minHeight: 600)
    }
}
