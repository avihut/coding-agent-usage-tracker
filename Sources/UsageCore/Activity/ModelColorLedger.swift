import Foundation

/// Which colors models wear, app-wide and for life — two levels: each model
/// FAMILY takes a hue slot, and each version within a family takes a shade
/// slot of that hue, so versions read as kin at a glance yet stay
/// discernable. Both levels assign the lowest free slot on first sight and
/// keep it forever (a model that stops appearing keeps its reservation so
/// colors never migrate). The value type is pure; the UserDefaults
/// persistence below is the ONE write path, shared by the engine's
/// usage-ordered seeding and the charts' lookups.
public struct ModelColorLedger: Equatable, Sendable {
    /// Family name → hue slot.
    public var hues: [String: Int]
    /// Family name → model id → shade slot within the family's hue.
    public var shades: [String: [String: Int]]

    public init(hues: [String: Int] = [:], shades: [String: [String: Int]] = [:]) {
        self.hues = hues
        self.shades = shades
    }

    /// The ledger grown by any unseen models, in the order given.
    public func assigning(_ models: [(id: String, family: String)]) -> ModelColorLedger {
        var grown = self
        for (id, family) in models {
            if grown.hues[family] == nil {
                grown.hues[family] = Self.lowestFreeSlot(in: grown.hues.values)
            }
            if grown.shades[family]?[id] == nil {
                var familyShades = grown.shades[family] ?? [:]
                familyShades[id] = Self.lowestFreeSlot(in: familyShades.values)
                grown.shades[family] = familyShades
            }
        }
        return grown
    }

    /// Both slots for a model, nil until it has been assigned.
    public func slots(for id: String, family: String) -> (hue: Int, shade: Int)? {
        guard let hue = hues[family], let shade = shades[family]?[id] else { return nil }
        return (hue, shade)
    }

    private static func lowestFreeSlot(in used: some Collection<Int>) -> Int {
        let taken = Set(used)
        var slot = 0
        while taken.contains(slot) { slot += 1 }
        return slot
    }
}

// MARK: - Persistence

extension ModelColorLedger {
    /// Provider-scoped: each harness keeps its own ledger, so every
    /// provider's heaviest family lands on slot 0 — its vendor accent —
    /// instead of whatever slots another vendor's families left free.
    public static func storageKey(providerID: String) -> String {
        "\(providerID).modelColorLedger"
    }

    public static func load(from defaults: UserDefaults, providerID: String) -> ModelColorLedger {
        guard let dict = defaults.dictionary(forKey: storageKey(providerID: providerID))
        else { return ModelColorLedger() }
        return ModelColorLedger(
            hues: dict["hues"] as? [String: Int] ?? [:],
            shades: dict["shades"] as? [String: [String: Int]] ?? [:])
    }

    public func save(to defaults: UserDefaults, providerID: String) {
        defaults.set(
            ["hues": hues, "shades": shades],
            forKey: Self.storageKey(providerID: providerID))
        // One launch briefly persisted a flat model→slot scheme here.
        defaults.removeObject(forKey: "modelColorSlots")
    }

    /// The stored ledger grown by any unseen models and persisted when it
    /// changed — the shared write path behind seeding and chart lookups.
    @discardableResult
    public static func grow(
        _ models: [(id: String, family: String)],
        defaults: UserDefaults, providerID: String
    ) -> ModelColorLedger {
        let stored = load(from: defaults, providerID: providerID)
        let grown = stored.assigning(models)
        if grown != stored { grown.save(to: defaults, providerID: providerID) }
        return grown
    }
}
