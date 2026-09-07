import Foundation

/// The profile list's persistence: one JSON blob in the app's UserDefaults
/// domain (`meteringProfiles`), the channel the daemon already reads for
/// every other setting — no new on-disk artifact (spec §10). Plus the focus
/// pin. The value type is pure; this enum is the one read/write path, like
/// `ModelColorLedger`'s.
public enum ProfileStore {
    public static let profilesKey = "meteringProfiles"
    public static let pinKey = "focusedProfilePin"

    public static func load(from defaults: UserDefaults) -> [Profile] {
        guard let data = defaults.data(forKey: profilesKey),
              let profiles = try? decoder().decode([Profile].self, from: data)
        else { return [] }
        return profiles
    }

    public static func save(_ profiles: [Profile], to defaults: UserDefaults) {
        guard let data = try? encoder().encode(profiles) else { return }
        defaults.set(data, forKey: profilesKey)
    }

    /// The person's pinned focus (nil = follows activity).
    public static func pin(from defaults: UserDefaults) -> String? {
        defaults.string(forKey: pinKey)
    }

    public static func setPin(_ id: String?, in defaults: UserDefaults) {
        if let id {
            defaults.set(id, forKey: pinKey)
        } else {
            defaults.removeObject(forKey: pinKey)
        }
    }

    /// The stored list made whole for one provider: its records only, the
    /// implicit `default` synthesized when absent (and its home refreshed
    /// from the provider, since the standard home is the provider's fact,
    /// not the record's), ordered by `order` then `addedAt`. A provider
    /// without multiple homes resolves to exactly `[default]` — stored
    /// extras are ignored, never deleted.
    public static func resolved(
        _ stored: [Profile], provider: any UsageProvider, now: Date
    ) -> [Profile] {
        var mine = stored.filter { $0.providerID == provider.id }
        if let index = mine.firstIndex(where: \.isDefault) {
            var standard = mine[index]
            standard = Profile(
                id: standard.id, providerID: standard.providerID, home: provider.homeDirectory,
                nickname: standard.nickname, monogram: standard.monogram,
                enabled: standard.enabled, showInMenuBar: standard.showInMenuBar,
                menuBarForm: standard.menuBarForm, ownMenuBarItem: standard.ownMenuBarItem,
                menuBarElements: standard.menuBarElements,
                order: standard.order, addedAt: standard.addedAt,
                ignoredIdentityKey: nil)
            mine[index] = standard
        } else {
            let lowest = mine.map(\.order).min() ?? 1
            var standard = Profile.standard(for: provider, addedAt: now)
            standard.order = lowest - 1
            mine.insert(standard, at: 0)
        }
        guard provider.supportsMultipleHomes else {
            return mine.filter(\.isDefault)
        }
        return mine.sorted { a, b in
            if a.order != b.order { return a.order < b.order }
            return a.addedAt < b.addedAt
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
