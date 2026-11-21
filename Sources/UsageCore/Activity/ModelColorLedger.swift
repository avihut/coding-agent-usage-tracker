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

// MARK: - Slot colors

/// The slot→color math: family base hues (slot 0 is the harness's brand
/// accent), each version a lightness level of its family's hue, every
/// result placed inside the legibility band of the appearance it is drawn
/// in (`ModelColorLegibility`: 3:1 against that ground, a lightness that
/// keeps the hue). One implementation feeds both the app's SwiftUI palette
/// and the digest's encoded colors, so a model looks identical on every
/// surface in every process — no NSColor anywhere in the derivation.
///
/// Slots are kept for life, so the version a person uses NOW holds its
/// family's highest slot: every slot must be as legible as slot 0 (the old
/// HSB steps grew with the slot and ran to near-black — #411204 at 1.08:1
/// for a fifth Opus version, user-reported 2026-11-21).
public enum ModelColorMath {
    /// Fixed hues after the accent slot — the DESIGN colors; each is fitted
    /// into the appearance's band when drawn.
    public static let fixedHues: [RGBColor] = [
        RGBColor(red: 0.420, green: 0.620, blue: 0.970),  // blue
        RGBColor(red: 0.480, green: 0.780, blue: 0.420),  // green
        RGBColor(red: 0.730, green: 0.550, blue: 0.950),  // purple
        RGBColor(red: 0.900, green: 0.760, blue: 0.350),  // gold
        RGBColor(red: 0.330, green: 0.770, blue: 0.810),  // teal
        RGBColor(red: 0.930, green: 0.500, blue: 0.660),  // pink
        RGBColor(red: 0.610, green: 0.650, blue: 0.710),  // slate
    ]

    /// A family's first five versions: where each sits in its band (a
    /// fraction of the band's width above the family's own lightness,
    /// wrapping) and how saturated — five levels a fifth of the band apart,
    /// ordered so consecutive versions sit two fifths apart; slot 0 is the
    /// family's own color. Later slots keep stepping two fifths
    /// (`versionLevel`).
    public static let versionLevels: [(offset: Double, chroma: Double)] = [
        (0.0, 1.00),
        (0.4, 0.70),
        (0.8, 1.10),
        (0.2, 0.55),
        (0.6, 0.85),
    ]

    /// The version level a shade slot wears: two fifths of the band past
    /// the previous slot, and each round of five shifted a tenth, so the
    /// step from one round into the next is half the band (not the fifth a
    /// plain cycle gave slot 4 → 5) and a later round never repeats an
    /// earlier one's lightness. Slots are kept for life, so the newest
    /// version — the one in use — is the highest slot; it and its
    /// predecessor share charts in a release week. Chroma cycles with the
    /// first round's levels.
    public static func versionLevel(_ shadeSlot: Int) -> (offset: Double, chroma: Double) {
        guard shadeSlot > 0 else { return versionLevels[0] }
        let round = Double(shadeSlot / versionLevels.count)
        let offset = (0.4 * Double(shadeSlot) + 0.1 * round).truncatingRemainder(dividingBy: 1)
        return (offset, versionLevels[1 + (shadeSlot - 1) % (versionLevels.count - 1)].chroma)
    }

    /// The family's base color re-shaded for a version's slot, for one
    /// appearance.
    public static func rgb(
        hueSlot: Int, shadeSlot: Int, accent: RGBColor, on appearance: ModelColorAppearance
    ) -> RGBColor {
        let palette = [accent] + fixedHues
        let base = palette[hueSlot % palette.count]
        var design = OKLCH(base)
        let level = versionLevel(shadeSlot)
        design.chroma *= level.chroma
        return ModelColorLegibility.place(
            design, offset: level.offset, on: appearance, exact: shadeSlot == 0 ? base : nil)
    }

    /// Tones of one hue for a chart that stacks several agents: the agent
    /// owns the hue (its accent), each model FAMILY a tone — a place in the
    /// band and a chroma — so no two vendors' models can wear look-alike
    /// colors. Indexed by the family's persistent hue slot, fixed for life
    /// like the ledger's own colors. Tuned (2026-11-21) over the four
    /// harness accents for the widest gap between the first four families'
    /// tones and the fewest cross-family look-alikes at any version slot.
    public static let agentTones: [(offset: Double, chroma: Double)] = [
        (0.00, 1.00),
        (0.25, 1.25),
        (0.06, 0.45),
        (0.83, 0.45),
        (0.32, 0.90),
        (0.81, 1.25),
    ]

    /// A model's color when agents share a chart: the agent's accent at the
    /// family's tone, each version a level further along the band from it.
    /// Both slots come from the agent's own ledger, so the color never moves
    /// between periods.
    public static func agentShade(
        hueSlot: Int, shadeSlot: Int, accent: RGBColor, on appearance: ModelColorAppearance
    ) -> RGBColor {
        let tone = agentTones[hueSlot % agentTones.count]
        let level = versionLevel(shadeSlot)
        var design = OKLCH(accent)
        design.chroma *= tone.chroma * level.chroma
        var offset = tone.offset + level.offset
        if offset >= 1 { offset -= 1 }
        return ModelColorLegibility.place(
            design, offset: offset, on: appearance,
            exact: hueSlot % agentTones.count == 0 && shadeSlot == 0 ? accent : nil)
    }
}
