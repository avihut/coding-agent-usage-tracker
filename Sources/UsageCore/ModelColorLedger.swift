import Foundation

/// Which colors models wear, app-wide and for life — two levels: each model
/// FAMILY takes a hue slot, and each version within a family takes a shade
/// slot of that hue, so versions read as kin at a glance yet stay
/// discernable. Both levels assign the lowest free slot on first sight and
/// keep it forever (a model that stops appearing keeps its reservation so
/// colors never migrate). Pure — persistence is the caller's.
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
