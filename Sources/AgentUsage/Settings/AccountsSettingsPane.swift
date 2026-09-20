import SwiftUI
import UsageCore

/// Settings → Accounts (0.97.0, user-directed: the accounts had been
/// "dumped under General"; 0.98.1: the bar's styling moved out to its own
/// pane): which sign-ins this Mac meters, then how the panel presents
/// them. Every metered harness has a card (0.101.0): an account is an
/// account whichever agent it belongs to, and a one-home harness simply has
/// one, with no folders to add.
struct AccountsSettingsPane: View {
    var registry: ProviderRegistry
    /// A landing request (an "account found" notice's click-through) —
    /// consumed once, then the pane scrolls to the Accounts card.
    var navigator: SettingsNavigator?

    var body: some View {
        ScrollViewReader { proxy in
            SettingsPaneScroll {
                // One card per metered harness — the pane is about accounts,
                // and every harness has at least one.
                ForEach(registry.accountHarnesses, id: \.id) { harness in
                    AccountsCard(registry: registry, harnessID: harness.id)
                        .id(harness.id == registry.accountHarnesses.first?.id
                            ? SettingsLanding.accounts.rawValue : harness.id)
                }
                PanelSettingsCard(registry: registry)
            }
            .onAppear { applyLanding(proxy) }
            .onChange(of: navigator?.landing) { _, _ in applyLanding(proxy) }
        }
    }

    /// The consume-once landing: a request puts the Accounts card in front
    /// of the person, whether the window was already open or not.
    private func applyLanding(_ proxy: ScrollViewProxy) {
        guard let landing = navigator?.consumeLanding() else { return }
        // One turn late: the card has to exist before it can be scrolled to.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation { proxy.scrollTo(landing.rawValue, anchor: .top) }
        }
    }
}
