import AppKit
import SwiftUI
import UsageCore

/// One harness's display facts, as a VALUE (v0.101.0). Up to 0.100.x this was
/// `ProviderStyle`, a set of `nonisolated(unsafe)` statics holding the ONE
/// active provider's accent and mark — honest while exactly one harness was
/// metered, and a lie the moment Claude and Codex draw side by side. Every
/// accent surface now takes the harness it is drawing, and nothing reads a
/// global.
///
/// Where it travels: EXPLICITLY into anything hoisted out of its section —
/// the meter popover lives on the panel's wrapper and the menu bar's hover
/// card is its own `NSHostingController`, so neither can read a per-section
/// environment — and through `\.harnessStyle` inside a window whose whole
/// tree belongs to one account (Sessions, Settings), injected at its root.
///
/// The accent is kept as core `RGBColor`, never `NSColor`: the renderer's
/// `Model` is `Equatable` and the status item skips a redraw when the model
/// compares equal, which a freshly-built dynamic NSColor would defeat.
struct HarnessStyle: Equatable, Sendable {
    let providerID: String
    /// The vendor's mark as the menu bar draws it (Claude's ✳︎) — what a
    /// chart uses to say "the vendor did this" without naming one.
    let glyph: String
    /// The brand accent every wash, ramp and slot-0 model color derives
    /// from. Semantic colors (warning, critical, the risk ramp, the cached
    /// badge) deliberately do NOT follow the harness.
    let accent: UsageCore.RGBColor

    init(providerID: String, glyph: String, accent: UsageCore.RGBColor) {
        self.providerID = providerID
        self.glyph = glyph
        self.accent = accent
    }

    init(_ provider: any UsageProvider) {
        self.init(
            providerID: provider.id, glyph: provider.menuBarGlyph,
            accent: UsageCore.RGBColor(provider.accent))
    }

    /// The digest's word for a harness — what a client-mode face has.
    init(_ harness: HarnessState) {
        self.init(providerID: harness.id, glyph: harness.glyph, accent: harness.accent)
    }

    /// The provider this build bundles, as a constant: the fallback for a
    /// surface with no harness in hand yet (a preview swatch, a snapshot
    /// case, an environment nobody injected). Same terracotta the statics
    /// defaulted to, so every pinned pixel is unchanged.
    static let bundled = HarnessStyle(
        providerID: HarnessResolution.bundledProviderID,
        glyph: "✳︎",
        accent: UsageCore.RGBColor(red: 0.851, green: 0.467, blue: 0.341))

    var nsAccent: NSColor {
        NSColor(srgbRed: accent.red, green: accent.green, blue: accent.blue, alpha: 1)
    }

    var accentColor: Color { Color(red: accent.red, green: accent.green, blue: accent.blue) }

    /// The accent lifted ~45% toward white — the highlight register for a
    /// mark that must read as "this one".
    var accentHighlightColor: Color {
        let lifted = nsAccent.blended(withFraction: 0.45, of: .white) ?? nsAccent
        return Color(nsColor: lifted)
    }
}

private struct HarnessStyleKey: EnvironmentKey {
    static let defaultValue = HarnessStyle.bundled
}

extension EnvironmentValues {
    /// The harness the surrounding tree belongs to. Injected at the root of a
    /// window built for one account; never a substitute for an explicit
    /// parameter in a hoisted popover, which sits outside that tree.
    var harnessStyle: HarnessStyle {
        get { self[HarnessStyleKey.self] }
        set { self[HarnessStyleKey.self] = newValue }
    }
}
