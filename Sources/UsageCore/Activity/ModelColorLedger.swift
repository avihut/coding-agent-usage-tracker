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

/// The slot→color math, pure sRGB: family base hues (slot 0 is the active
/// provider's brand accent) and alternating washed/deep shade rescales per
/// version. One implementation feeds both the app's SwiftUI palette and the
/// digest's encoded colors, so a model looks identical on every surface in
/// every process — no NSColor anywhere in the derivation.
public enum ModelColorMath {
    /// Fixed hues after the accent slot, tuned to read on dark material.
    public static let fixedHues: [RGBColor] = [
        RGBColor(red: 0.420, green: 0.620, blue: 0.970),  // blue
        RGBColor(red: 0.480, green: 0.780, blue: 0.420),  // green
        RGBColor(red: 0.730, green: 0.550, blue: 0.950),  // purple
        RGBColor(red: 0.900, green: 0.760, blue: 0.350),  // gold
        RGBColor(red: 0.330, green: 0.770, blue: 0.810),  // teal
        RGBColor(red: 0.930, green: 0.500, blue: 0.660),  // pink
        RGBColor(red: 0.610, green: 0.650, blue: 0.710),  // slate
    ]

    /// Saturation/brightness scaling per shade slot past the family's first
    /// version — alternating washed/deep so consecutive versions contrast.
    public static let shadeSteps: [(saturation: Double, brightness: Double)] = [
        (0.55, 1.25),
        (1.20, 0.68),
        (0.35, 1.40),
        (1.30, 0.50),
    ]

    /// The family's base hue re-shaded for a version's slot.
    public static func rgb(hueSlot: Int, shadeSlot: Int, accent: RGBColor) -> RGBColor {
        let palette = [accent] + fixedHues
        let base = palette[hueSlot % palette.count]
        guard shadeSlot > 0 else { return base }
        let step = shadeSteps[(shadeSlot - 1) % shadeSteps.count]
        let (h, s, b) = hsb(from: base)
        return rgb(hue: h, saturation: min(1, s * step.saturation), brightness: min(1, b * step.brightness))
    }

    /// Standard RGB→HSB (hexcone) — matches AppKit's conversion for sRGB
    /// inputs, minus AppKit.
    static func hsb(from color: RGBColor) -> (hue: Double, saturation: Double, brightness: Double) {
        let maxC = max(color.red, color.green, color.blue)
        let minC = min(color.red, color.green, color.blue)
        let delta = maxC - minC
        let brightness = maxC
        let saturation = maxC == 0 ? 0 : delta / maxC
        var hue = 0.0
        if delta != 0 {
            if maxC == color.red {
                hue = ((color.green - color.blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == color.green {
                hue = (color.blue - color.red) / delta + 2
            } else {
                hue = (color.red - color.green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, saturation, brightness)
    }

    /// Standard HSB→RGB (hexcone inverse).
    static func rgb(hue: Double, saturation: Double, brightness: Double) -> RGBColor {
        guard saturation > 0 else {
            return RGBColor(red: brightness, green: brightness, blue: brightness)
        }
        let sector = (hue - hue.rounded(.down)) * 6
        let index = Int(sector) % 6
        let fraction = sector - sector.rounded(.down)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        switch index {
        case 0: return RGBColor(red: brightness, green: t, blue: p)
        case 1: return RGBColor(red: q, green: brightness, blue: p)
        case 2: return RGBColor(red: p, green: brightness, blue: t)
        case 3: return RGBColor(red: p, green: q, blue: brightness)
        case 4: return RGBColor(red: t, green: p, blue: brightness)
        default: return RGBColor(red: brightness, green: p, blue: q)
        }
    }
}
