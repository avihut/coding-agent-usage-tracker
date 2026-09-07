import SwiftUI
import UsageCore

/// Settings → Accounts (0.97.0, user-directed: the accounts and their
/// presentation had been "dumped under General"): which sign-ins this Mac
/// meters and how each draws, then the bar as a whole with its live
/// preview, then the panel. Only a provider that can have several homes
/// has the pane at all.
struct AccountsSettingsPane: View {
    var registry: ProviderRegistry
    /// A landing request (an "account found" notice's click-through) —
    /// consumed once, then the pane scrolls to the Accounts card.
    var navigator: SettingsNavigator?

    var body: some View {
        ScrollViewReader { proxy in
            SettingsPaneScroll {
                MenuBarSettingsCard(registry: registry)
                AccountsCard(registry: registry).id(SettingsLanding.accounts.rawValue)
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
