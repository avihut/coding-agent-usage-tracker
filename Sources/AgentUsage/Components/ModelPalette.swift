import AppKit
import SwiftUI
import UsageCore

/// The app's model colors, persistent and app-wide: each model FAMILY wears
/// one of the base hues (first-seen order — the launch scan seeds heaviest
/// first, so the heaviest family gets its vendor's own accent), and each
/// version within a family wears a shade of that hue — kin at a glance,
/// distinct on inspection. Assignments live in UserDefaults and never change
/// once made; every chart asks here, so a model looks the same on every
/// surface, this launch and the next. Hue table, shade steps, and the rescale
/// math all live in core `ModelColorMath` (slot 0 = the HARNESS's accent).
///
/// The ledger is provider-scoped and slot 0 is the vendor's accent, so both
/// the scope key and the accent come from the harness being drawn (0.101.0) —
/// passed in, never read off a global: with Claude and Codex metered at once
/// a global would paint one vendor's models in the other's brand.
@MainActor
enum ModelPalette {
    /// Set once, for a `--demo-digest` run: its bundle shares the live
    /// install's defaults domain, so a demo that grew the ledger there would
    /// write this Mac's colors (and borrow them, making the README's
    /// pictures depend on whose Mac drew them). A demo keeps its ledgers in
    /// memory instead, starting empty — the demo hatch's no-leak rule.
    static var isEphemeral = false
    private static var ephemeralLedgers: [String: ModelColorLedger] = [:]

    /// Colors for these models (and every model ever seen) from the
    /// persistent ledger, growing and saving it when new models appear.
    /// Persistence lives with core `ModelColorLedger` — the engine's
    /// usage-ordered seed and this lookup share the one write path.
    /// `family` reads a model's family; the merged consumption scope passes
    /// the model's own agent's catalog reading, every other chart the
    /// active one's.
    static func assignment(
        for models: [String], style: HarnessStyle,
        family: (String) -> String = ModelFamily.familyName
    ) -> [String: Color] {
        let grown = ledger(growing: models, providerID: style.providerID, family: family)
        var result: [String: Color] = [:]
        for (family, familyShades) in grown.shades {
            guard let hue = grown.hues[family] else { continue }
            for (model, shade) in familyShades {
                result[model] = color(hueSlot: hue, shadeSlot: shade, style: style)
            }
        }
        return result
    }

    /// The harness's ledger grown by any unseen models — persisted through
    /// core's one write path, or held in memory for a demo.
    /// Colors for one agent's models when several agents share a chart: the
    /// agent's accent at a tone per family (`ModelColorMath.agentShade`),
    /// read from — and growing — that agent's own ledger, so the slots and
    /// therefore the colors are as fixed as the ones above. Raw model ids
    /// only; the caller keys the result however its chart needs.
    static func agentShades(
        for models: [String], style: HarnessStyle,
        family: (String) -> String = ModelFamily.familyName
    ) -> [String: Color] {
        let grown = ledger(growing: models, providerID: style.providerID, family: family)
        var result: [String: Color] = [:]
        for model in models {
            guard let slots = grown.slots(for: model, family: family(model)) else { continue }
            result[model] = adaptive(.agentShade, hueSlot: slots.hue, shadeSlot: slots.shade, accent: style.accent)
        }
        return result
    }

    static func ledger(
        growing models: [String], providerID: String,
        family: (String) -> String = ModelFamily.familyName
    ) -> ModelColorLedger {
        // A merged scope's composite key (agent␟account␟model) is a chart's
        // key, never a model: saved here it would hold a slot forever.
        let entries = models
            .filter { !ConsumptionKey.isComposite($0) }
            .map { ($0, family($0)) }
        guard isEphemeral else {
            return ModelColorLedger.grow(entries, defaults: .standard, providerID: providerID)
        }
        let grown = (ephemeralLedgers[providerID] ?? ModelColorLedger()).assigning(entries)
        ephemeralLedgers[providerID] = grown
        return grown
    }

    /// The family's base hue re-shaded for a version's slot — core
    /// `ModelColorMath` owns the arithmetic, so the digest's encoded colors
    /// and these SwiftUI colors come out of one derivation.
    static func color(hueSlot: Int, shadeSlot: Int, style: HarnessStyle) -> Color {
        adaptive(.ledger, hueSlot: hueSlot, shadeSlot: shadeSlot, accent: style.accent)
    }

    enum Derivation: Hashable { case ledger, agentShade }

    private struct Key: Hashable {
        let derivation: Derivation
        let hueSlot: Int
        let shadeSlot: Int
        let red: Double, green: Double, blue: Double
    }

    /// Derived once per slot and accent: the band search is a few thousand
    /// conversions, and every chart body asks for its palette.
    private static var cache: [Key: Color] = [:]

    /// One `Color` holding both appearance variants — an NSColor whose
    /// provider picks by the appearance it is drawn in, so the light panel
    /// (and the snapshot hatch's light window) draws the light variant
    /// through Charts, Canvas and plain shapes alike.
    private static func adaptive(
        _ derivation: Derivation, hueSlot: Int, shadeSlot: Int, accent: UsageCore.RGBColor
    ) -> Color {
        let key = Key(
            derivation: derivation, hueSlot: hueSlot, shadeSlot: shadeSlot,
            red: accent.red, green: accent.green, blue: accent.blue)
        if let cached = cache[key] { return cached }
        func variant(_ appearance: ModelColorAppearance) -> NSColor {
            let rgb = switch derivation {
            case .ledger:
                ModelColorMath.rgb(hueSlot: hueSlot, shadeSlot: shadeSlot, accent: accent, on: appearance)
            case .agentShade:
                ModelColorMath.agentShade(hueSlot: hueSlot, shadeSlot: shadeSlot, accent: accent, on: appearance)
            }
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
        let (dark, light) = (variant(.dark), variant(.light))
        // @Sendable: AppKit may resolve a dynamic color off the main thread,
        // and a closure written in this @MainActor enum would otherwise
        // inherit its isolation and trap there. It captures two NSColors.
        let color = Color(nsColor: NSColor(name: nil) { @Sendable appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
        cache[key] = color
        return color
    }
}
