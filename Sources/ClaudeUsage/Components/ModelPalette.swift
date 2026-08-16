import AppKit
import SwiftUI
import UsageCore

/// The app's model colors, persistent and app-wide: each model FAMILY wears
/// one of the base hues (first-seen order — the launch scan seeds heaviest
/// first, so the heaviest family gets Claude's own orange), and each version
/// within a family wears a shade of that hue — kin at a glance, distinct on
/// inspection. Assignments live in UserDefaults and never change once made;
/// every chart asks here, so a model looks the same on every surface, this
/// launch and the next.
enum ModelPalette {
    /// Family base hues, tuned to read on the panel's dark material. Slot
    /// 0 is the ACTIVE provider's brand accent — the launch scan seeds
    /// heaviest-first, so each harness's heaviest family wears its own
    /// vendor color (terracotta for Claude, green for Codex, blue for
    /// Gemini).
    static var colors: [Color] {
        [ProviderStyle.accentColor] + fixedHues
    }

    private static let fixedHues: [Color] = [
        Color(red: 0.420, green: 0.620, blue: 0.970),  // blue
        Color(red: 0.480, green: 0.780, blue: 0.420),  // green
        Color(red: 0.730, green: 0.550, blue: 0.950),  // purple
        Color(red: 0.900, green: 0.760, blue: 0.350),  // gold
        Color(red: 0.330, green: 0.770, blue: 0.810),  // teal
        Color(red: 0.930, green: 0.500, blue: 0.660),  // pink
        Color(red: 0.610, green: 0.650, blue: 0.710),  // slate
    ]

    /// Saturation/brightness scaling per shade slot past the family's first
    /// version — alternating washed/deep so consecutive versions contrast.
    private static let shadeSteps: [(saturation: Double, brightness: Double)] = [
        (0.55, 1.25),
        (1.20, 0.68),
        (0.35, 1.40),
        (1.30, 0.50),
    ]

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

    /// The family's base hue re-shaded for a version's slot.
    static func color(hueSlot: Int, shadeSlot: Int) -> Color {
        let base = colors[hueSlot % colors.count]
        guard shadeSlot > 0 else { return base }
        let step = shadeSteps[(shadeSlot - 1) % shadeSteps.count]
        guard let rgb = NSColor(base).usingColorSpace(.sRGB) else { return base }
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(
            hue: h, saturation: min(1, s * step.saturation),
            brightness: min(1, b * step.brightness), opacity: a)
    }
}
