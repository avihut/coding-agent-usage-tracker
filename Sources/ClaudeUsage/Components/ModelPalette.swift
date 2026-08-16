import SwiftUI
import UsageCore

/// The app's model colors, persistent and app-wide: each model FAMILY wears
/// one of the base hues (first-seen order — the launch scan seeds heaviest
/// first, so the heaviest family gets Claude's own orange), and each version
/// within a family wears a shade of that hue — kin at a glance, distinct on
/// inspection. Assignments live in UserDefaults and never change once made;
/// every chart asks here, so a model looks the same on every surface, this
/// launch and the next. Hue table, shade steps, and the rescale math all
/// live in core `ModelColorMath` (slot 0 = the active provider's accent);
/// this facade just binds them to the installed ProviderStyle and SwiftUI.
enum ModelPalette {
    /// Colors for these models (and every model ever seen) from the
    /// persistent ledger, growing and saving it when new models appear.
    /// Persistence lives with core `ModelColorLedger` — the engine's
    /// usage-ordered seed and this lookup share the one write path.
    static func assignment(for models: [String]) -> [String: Color] {
        let grown = ModelColorLedger.grow(
            models.map { ($0, ModelFamily.familyName($0)) },
            defaults: .standard, providerID: ProviderStyle.providerID)
        var result: [String: Color] = [:]
        for (family, familyShades) in grown.shades {
            guard let hue = grown.hues[family] else { continue }
            for (model, shade) in familyShades {
                result[model] = color(hueSlot: hue, shadeSlot: shade)
            }
        }
        return result
    }

    /// The family's base hue re-shaded for a version's slot — core
    /// `ModelColorMath` owns the arithmetic, so the digest's encoded colors
    /// and these SwiftUI colors come out of one derivation.
    static func color(hueSlot: Int, shadeSlot: Int) -> Color {
        let rgb = ModelColorMath.rgb(
            hueSlot: hueSlot, shadeSlot: shadeSlot, accent: ProviderStyle.accentRGB)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
