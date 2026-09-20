import Foundation

/// The harnesses a host meters and how each stands (multi-harness metering,
/// v0.101.0): every PRESENT provider in the build's standard order, its
/// accounts resolved exactly as one provider's always were
/// (`ProfileStore.resolved`), and whether the person shows it. Pure —
/// presence, the stored records and the hidden set come in, rows go out.
///
/// Two floors keep a machine from metering nothing: with no harness found on
/// disk the bundled default is metered anyway (a fresh Mac still renders its
/// loading state), and the last SHOWN harness can never be hidden — were the
/// stored set to cover every one, the first is shown regardless.
public struct HarnessRoster: Sendable {
    public struct Row: Sendable, Identifiable {
        public let provider: any UsageProvider
        /// This harness's accounts, the implicit default first, in the
        /// person's order.
        public let profiles: [Profile]
        /// Found on disk. False only for the bundled fallback row.
        public let present: Bool
        /// Drawn in the bar and eligible for focus. A hidden harness keeps
        /// being METERED (user-decided: "turn off displaying") — its engines
        /// run, its rates still list, it just owns no cell.
        public let shown: Bool
        /// The default record was synthesized rather than stored, so its
        /// enrolment stamp is "now" and dormancy must not lean on it.
        public let synthesizedDefault: Bool

        public var id: String { provider.id }

        public init(
            provider: any UsageProvider, profiles: [Profile], present: Bool, shown: Bool,
            synthesizedDefault: Bool
        ) {
            self.provider = provider
            self.profiles = profiles
            self.present = present
            self.shown = shown
            self.synthesizedDefault = synthesizedDefault
        }
    }

    /// The defaults key holding the ids of the harnesses the person hid —
    /// the app writes it, a daemon re-reads it on `settingsChanged`.
    public static let hiddenKey = "hiddenHarnesses"

    public let rows: [Row]

    public init(rows: [Row]) {
        self.rows = rows
    }

    public static func build(
        providers: [any UsageProvider], present: Set<String>, stored: [Profile],
        hidden: Set<String>, now: Date
    ) -> HarnessRoster {
        var metered = providers.filter { present.contains($0.id) }
        if metered.isEmpty, let first = providers.first { metered = [first] }
        let anyShown = metered.contains { !hidden.contains($0.id) }
        return HarnessRoster(rows: metered.enumerated().map { index, provider in
            Row(
                provider: provider,
                profiles: ProfileStore.resolved(stored, provider: provider, now: now),
                present: present.contains(provider.id),
                shown: !hidden.contains(provider.id) || (!anyShown && index == 0),
                synthesizedDefault: !stored.contains {
                    $0.providerID == provider.id && $0.isDefault
                })
        })
    }

    /// Every metered account, harness blocks in standard order.
    public var profiles: [Profile] { rows.flatMap(\.profiles) }

    public func row(_ providerID: String) -> Row? { rows.first { $0.id == providerID } }

    public func profile(key: String) -> Profile? { profiles.first { $0.key == key } }

    public func isShown(_ providerID: String) -> Bool { row(providerID)?.shown ?? false }

    /// Whether the person may hide this harness now — never the last shown.
    public func canHide(_ providerID: String) -> Bool {
        rows.contains { $0.shown && $0.id != providerID }
    }

    public static func hidden(from defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: hiddenKey) ?? [])
    }

    public static func setHidden(_ hidden: Set<String>, in defaults: UserDefaults) {
        if hidden.isEmpty {
            defaults.removeObject(forKey: hiddenKey)
        } else {
            defaults.set(hidden.sorted(), forKey: hiddenKey)
        }
    }
}
