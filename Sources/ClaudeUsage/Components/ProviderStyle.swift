import AppKit
import SwiftUI
import UsageCore

/// The active provider's display facts for code with no store in hand —
/// the status-item renderer, the model palette's statics, chart tints.
/// Same contract as `ModelNames.catalog`: written only on MainActor by
/// ProviderRegistry while re-binding the active provider, at launch and on
/// a Metering switch, always before dependent UI rebuilds — so every
/// render observes one settled value.
enum ProviderStyle {
    nonisolated(unsafe) private(set) static var providerID = "claude"
    /// The vendor's brand accent (Claude's terracotta by default) — the
    /// base every accent surface derives washes and ramps from.
    nonisolated(unsafe) private(set) static var accent =
        NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
    /// The same accent as plain components — what ModelColorMath (and the
    /// digest) derive slot colors from, so app and TUI colors can't drift.
    nonisolated(unsafe) private(set) static var accentRGB =
        RGBColor(red: 0.851, green: 0.467, blue: 0.341)

    /// The vendor's mark as the menu bar draws it (Claude's ✳︎) — what a
    /// chart uses to say "the vendor did this" without naming one.
    nonisolated(unsafe) private(set) static var glyph = "✳︎"

    static var accentColor: Color { Color(nsColor: accent) }

    static func install(_ provider: any UsageProvider) {
        providerID = provider.id
        glyph = provider.menuBarGlyph
        accent = NSColor(
            srgbRed: provider.accent.red, green: provider.accent.green,
            blue: provider.accent.blue, alpha: 1)
        accentRGB = RGBColor(provider.accent)
    }
}
