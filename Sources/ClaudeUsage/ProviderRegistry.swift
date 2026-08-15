import Foundation
import Observation
import UsageCore

/// The one place a vendor is chosen. Knows every harness this build can
/// meter, detects which one is actually in use on this machine, and owns
/// the active provider's store. Exactly one store runs at a time —
/// switching retires the old one (this is an adoption seam, not concurrent
/// metering). The Metering picker in the panel's ⋯ menu and in Settings
/// drives `select(_:)`; "auto" re-resolves against the detection signals.
@MainActor
@Observable
final class ProviderRegistry {
    static let selectionKey = "activeProviderID"
    static let automatic = "auto"

    /// A Metering picker row.
    struct HarnessChoice: Identifiable, Equatable {
        let id: String
        let name: String
    }

    /// Every provider this build ships, bundled default first — the
    /// tie-break order when detection sees an all-quiet machine.
    let providers: [any UsageProvider]
    let bundleID: String
    /// Presence + recency per harness, most-active first; refreshed by
    /// every detection pass. Settings renders these.
    private(set) var signals: [HarnessSignal]
    /// "auto" or a provider id — the user's persisted Metering choice.
    private(set) var selection: String
    private(set) var activeID: String
    /// Re-binds the status item to a new active store. The Bool says the
    /// switch may wait for the panel to close (daily auto re-detection
    /// must not yank the UI out from under the user; an explicit pick
    /// applies immediately).
    var onActiveChange: ((UsageStore, _ deferrable: Bool) -> Void)?

    private var stores: [String: UsageStore] = [:]
    private var redetectTimer: Timer?

    /// `launchOverride` is the `--provider <id>` verification hatch: it
    /// wins for this launch without touching the persisted choice.
    init(bundleID: String, launchOverride: String? = nil) {
        let providers: [any UsageProvider] = [
            ClaudeProvider(), CodexProvider(), GeminiProvider(),
        ]
        self.providers = providers
        self.bundleID = bundleID
        let stored = UserDefaults.standard.string(forKey: Self.selectionKey) ?? Self.automatic
        let selection = launchOverride ?? stored
        self.selection = selection
        let signals = HarnessDetector.rank(
            candidates: Self.candidates(providers: providers, bundleID: bundleID))
        self.signals = signals
        self.activeID = Self.resolve(
            selection: selection, providers: providers, signals: signals)
        // Catalog + style install before any UI renders or scan runs —
        // display names and accent colors read them from everywhere.
        let active = provider(for: activeID)
        ModelNames.catalog = active.modelCatalog
        ProviderStyle.install(active)
        scheduleDailyRedetect()
    }

    var activeStore: UsageStore { store(for: activeID) }
    var activeProvider: any UsageProvider { provider(for: activeID) }

    /// Rows for the Metering pickers: only harnesses that exist on this
    /// machine are offered.
    var presentChoices: [HarnessChoice] {
        signals.filter(\.present).compactMap { signal in
            providers.first { $0.id == signal.id }
                .map { HarnessChoice(id: $0.id, name: $0.agentName) }
        }
    }

    /// "Automatic (Claude Code)" — names what auto currently resolves to.
    var automaticLabel: String {
        let autoID = Self.resolve(
            selection: Self.automatic, providers: providers, signals: signals)
        return "Automatic (\(provider(for: autoID).agentName))"
    }

    /// The user picked from a Metering menu. Persists and applies now.
    func select(_ choice: String) {
        selection = choice
        UserDefaults.standard.set(choice, forKey: Self.selectionKey)
        apply(deferrable: false)
    }

    /// Re-runs detection off-main (the stat walk is capped but a cold disk
    /// shouldn't stall the main thread) and applies the outcome. Auto mode
    /// may switch the active harness; an explicit choice only refreshes
    /// the signals shown in Settings.
    func redetect(deferrable: Bool) {
        let candidates = Self.candidates(providers: providers, bundleID: bundleID)
        Task.detached(priority: .utility) {
            let signals = HarnessDetector.rank(candidates: candidates)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.signals = signals
                self.apply(deferrable: deferrable)
            }
        }
    }

    private func apply(deferrable: Bool) {
        let winner = Self.resolve(
            selection: selection, providers: providers, signals: signals)
        guard winner != activeID else { return }
        // Drop the registry's reference; the status item still holds the
        // outgoing store and shuts it down as part of adopting the new one.
        stores.removeValue(forKey: activeID)
        activeID = winner
        let active = provider(for: winner)
        ModelNames.catalog = active.modelCatalog
        ProviderStyle.install(active)
        onActiveChange?(store(for: winner), deferrable)
    }

    private func store(for id: String) -> UsageStore {
        if let store = stores[id] { return store }
        let store = UsageStore(provider: provider(for: id))
        stores[id] = store
        return store
    }

    private func provider(for id: String) -> any UsageProvider {
        providers.first { $0.id == id } ?? providers[0]
    }

    /// A manual choice must exist and be present on this machine; anything
    /// else falls back to detection, and an empty machine falls back to
    /// the bundled default.
    private static func resolve(
        selection: String, providers: [any UsageProvider], signals: [HarnessSignal]
    ) -> String {
        if selection != automatic,
           providers.contains(where: { $0.id == selection }),
           signals.first(where: { $0.id == selection })?.present == true {
            return selection
        }
        return HarnessDetector.activeID(in: signals) ?? providers[0].id
    }

    /// Detection scores each provider's session artifacts — the same trees
    /// the FSEvents watcher observes.
    private static func candidates(
        providers: [any UsageProvider], bundleID: String
    ) -> [(id: String, directories: [URL])] {
        providers.map { provider in
            let support = StorageScope.supportDirectory(
                bundleID: bundleID, providerID: provider.id)
            let directories =
                provider.makeLocalActivity(cacheDirectory: support)?.watchDirectories ?? []
            return (provider.id, directories)
        }
    }

    private func scheduleDailyRedetect() {
        let timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.selection == Self.automatic else { return }
                self.redetect(deferrable: true)
            }
        }
        timer.tolerance = 3600
        redetectTimer = timer
    }
}
