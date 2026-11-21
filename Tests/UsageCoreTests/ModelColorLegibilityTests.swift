import Foundation
import Testing

@testable import UsageCore

/// The model-color constraint over the WHOLE slot grid (user-reported
/// 2026-11-21: "the opus 5.5 color makes it look disabled"): every hue slot ×
/// shade slot × harness accent × appearance holds 3:1 on its ground, keeps a
/// lightness that reads as a hue, keeps its family's hue, and stays apart
/// from its neighbours.
@Suite("ModelColorLegibility")
struct ModelColorLegibilityTests {
    /// The four harnesses' accents — the colors slot 0 is drawn from.
    static let harnessAccents: [String: RGBColor] = [
        "claude": RGBColor(red: 0.851, green: 0.467, blue: 0.341),
        "codex": RGBColor(red: 0.063, green: 0.639, blue: 0.498),
        "gemini": RGBColor(red: 0.259, green: 0.522, blue: 0.957),
        "antigravity": RGBColor(red: 0.631, green: 0.259, blue: 0.957),
    ]
    /// Accents no harness has, at the gamut's awkward corners: the legibility
    /// rules must hold for them too (distinctness is a tuning claim, made for
    /// the real accents only).
    static let stressAccents: [RGBColor] = [
        RGBColor(red: 0, green: 0, blue: 1),
        RGBColor(red: 1, green: 0.9, blue: 0),
        RGBColor(red: 0.5, green: 0.5, blue: 0.5),
        RGBColor(red: 0.1, green: 0.05, blue: 0.05),
        RGBColor(red: 0.98, green: 0.98, blue: 0.96),
    ]
    static let shadeSlots = 0..<10
    static let ledgerHueSlots = 0..<(ModelColorMath.fixedHues.count + 1)
    static let toneSlots = 0..<ModelColorMath.agentTones.count

    typealias Derive = @Sendable (Int, Int, RGBColor, ModelColorAppearance) -> RGBColor
    static let ledger: Derive = { ModelColorMath.rgb(hueSlot: $0, shadeSlot: $1, accent: $2, on: $3) }
    static let merged: Derive = { ModelColorMath.agentShade(hueSlot: $0, shadeSlot: $1, accent: $2, on: $3) }

    // MARK: - The arithmetic underneath

    @Test("WCAG contrast: black on white is 21, a color on itself is 1")
    func contrastSanity() {
        let black = RGBColor(red: 0, green: 0, blue: 0)
        let white = RGBColor(red: 1, green: 1, blue: 1)
        #expect(abs(ModelColorLegibility.contrast(black, white) - 21) < 1e-9)
        #expect(abs(ModelColorLegibility.contrast(white, black) - 21) < 1e-9)
        #expect(ModelColorLegibility.contrast(white, white) == 1)
    }

    @Test("OKLCH round-trips sRGB")
    func oklchRoundTrip() {
        for color in Array(Self.harnessAccents.values) + Self.stressAccents + ModelColorMath.fixedHues {
            let back = OKLCH(color).rgb
            #expect(abs(back.red - color.red) < 1e-6)
            #expect(abs(back.green - color.green) < 1e-6)
            #expect(abs(back.blue - color.blue) < 1e-6)
        }
        // White is L 1, black L 0, both achromatic.
        #expect(abs(OKLCH(RGBColor(red: 1, green: 1, blue: 1)).lightness - 1) < 1e-6)
        #expect(OKLCH(RGBColor(red: 0, green: 0, blue: 0)).chroma < 1e-9)
    }

    @Test("an out-of-gamut OKLCH keeps lightness and hue, giving up chroma")
    func gamutMapping() {
        let wild = OKLCH(lightness: 0.85, chroma: 0.4, hue: 2.5)
        let drawn = OKLCH(wild.rgb)
        #expect(abs(drawn.lightness - 0.85) < 1e-4)
        #expect(abs(remainder(drawn.hue - 2.5, 2 * .pi)) < 0.01)
        #expect(drawn.chroma < 0.4)
    }

    // MARK: - Legibility, every slot

    @Test("every model color holds 3:1 on its ground AS DRAWN — rounded to 8-bit sRGB")
    func contrastEverywhere() {
        forEveryColor { _, _, _, appearance, color in
            let drawn = Self.bytes(color)
            let ratio = ModelColorLegibility.contrast(drawn, ModelColorLegibility.ground(appearance))
            #expect(ratio >= ModelColorLegibility.minimumContrast, "\(appearance) \(drawn): \(ratio)")
        }
    }

    @Test("a color from a chromatic design keeps a tint — none turns grey")
    func noneTurnsGrey() {
        // The slate fixed hue is grey by design; everything else is a hue
        // and must still read as one ("too grey on dark" reads disabled).
        forEveryColor { derivation, hueSlot, accent, _, color in
            let base = derivation == "merged"
                ? accent
                : ([accent] + ModelColorMath.fixedHues)[hueSlot % (ModelColorMath.fixedHues.count + 1)]
            guard OKLCH(base).chroma >= 0.05 else { return }
            #expect(OKLCH(color).chroma >= 0.025, "\(derivation) slot \(hueSlot) \(color)")
        }
    }

    @Test("no color is near-white on dark or near-black on light")
    func lightnessKeepsTheHue() {
        forEveryColor { _, _, _, appearance, color in
            let lightness = OKLCH(color).lightness
            switch appearance {
            case .dark: #expect(lightness <= ModelColorLegibility.darkLightnessCap + 1e-3, "\(color)")
            case .light: #expect(lightness >= ModelColorLegibility.lightLightnessFloor - 1e-3, "\(color)")
            }
        }
    }

    @Test("a model keeps its family's hue: the slot's base, or the agent's accent in a merge")
    func hueIsKept() {
        forEveryColor { derivation, hueSlot, accent, _, color in
            let base = derivation == "merged"
                ? accent
                : ([accent] + ModelColorMath.fixedHues)[hueSlot % (ModelColorMath.fixedHues.count + 1)]
            let (drawn, design) = (OKLCH(color), OKLCH(base))
            guard drawn.chroma > 0.02, design.chroma > 0.02 else { return }
            let drift = abs(remainder(drawn.hue - design.hue, 2 * .pi)) * 180 / .pi
            #expect(drift < 1, "\(derivation) slot \(hueSlot) \(color): \(drift)°")
        }
    }

    @Test("slot 0 is the brand accent wherever the accent already holds 3:1")
    func slotZeroIsTheAccent() {
        for (name, accent) in Self.harnessAccents {
            for appearance in ModelColorAppearance.allCases {
                let ground = ModelColorLegibility.ground(appearance)
                let lightness = OKLCH(accent).lightness
                let keeps = ModelColorLegibility.contrast(accent, ground) >= ModelColorLegibility.placementContrast
                    && (appearance == .dark
                        ? lightness <= ModelColorLegibility.darkLightnessCap
                        : lightness >= ModelColorLegibility.lightLightnessFloor)
                for derive in [Self.ledger, Self.merged] {
                    let color = derive(0, 0, accent, appearance)
                    if keeps {
                        #expect(OKLCH.difference(color, accent) < 1e-6, "\(name) \(appearance)")
                    } else {
                        #expect(OKLCH.difference(color, accent) > 0, "\(name) \(appearance)")
                    }
                }
            }
        }
        // The dark panel keeps Claude's own orange; the light one deepens it
        // (the accent is 2.6:1 on #ECECEC).
        let claude = Self.harnessAccents["claude"]!
        #expect(OKLCH.difference(ModelColorMath.rgb(hueSlot: 0, shadeSlot: 0, accent: claude, on: .dark), claude) < 1e-6)
        #expect(ModelColorLegibility.contrast(claude, ModelColorLegibility.ground(.light)) < 3)
    }

    @Test("the reported color is gone: a fifth Opus version is no longer near-black on dark")
    func reportedOpus() {
        let claude = Self.harnessAccents["claude"]!
        let color = ModelColorMath.agentShade(hueSlot: 0, shadeSlot: 4, accent: claude, on: .dark)
        #expect(ModelColorLegibility.contrast(color, ModelColorLegibility.ground(.dark)) >= 3)
        #expect(OKLCH(color).lightness > 0.58)
    }

    // MARK: - Neighbours stay apart

    /// The ΔE_ok floors below are the tuned derivation's measured minima less
    /// a margin — the light band is narrower (~0.23 of lightness against
    /// ~0.32), so its floors are lower.
    static func floor(_ appearance: ModelColorAppearance, dark: Double, light: Double) -> Double {
        appearance == .dark ? dark : light
    }

    @Test("consecutive versions of a family stay apart, at every slot a ledger can reach")
    func adjacentVersions() {
        for (derivation, derive, hueSlots) in [
            ("ledger", Self.ledger, Self.ledgerHueSlots), ("merged", Self.merged, Self.toneSlots),
        ] {
            for (name, accent) in Self.harnessAccents {
                for appearance in ModelColorAppearance.allCases {
                    for hueSlot in hueSlots {
                        let colors = Self.shadeSlots.map { derive(hueSlot, $0, accent, appearance) }
                        for slot in colors.indices.dropLast() {
                            let difference = OKLCH.difference(colors[slot], colors[slot + 1])
                            #expect(
                                difference >= Self.floor(appearance, dark: 0.10, light: 0.075),
                                "\(derivation) \(name) \(appearance) hue \(hueSlot) shades \(slot)/\(slot + 1): \(difference)")
                        }
                    }
                }
            }
        }
    }

    @Test("any two of a family's first five versions stay apart")
    func versionsPairwise() {
        for (derive, hueSlots) in [(Self.ledger, Self.ledgerHueSlots), (Self.merged, Self.toneSlots)] {
            for accent in Self.harnessAccents.values {
                for appearance in ModelColorAppearance.allCases {
                    for hueSlot in hueSlots {
                        let colors = (0..<5).map { derive(hueSlot, $0, accent, appearance) }
                        for i in colors.indices {
                            for j in colors.indices where j > i {
                                let difference = OKLCH.difference(colors[i], colors[j])
                                #expect(
                                    difference >= Self.floor(appearance, dark: 0.050, light: 0.035),
                                    "\(appearance) hue \(hueSlot) shades \(i)/\(j): \(difference)")
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("in a merge, an agent's first four families wear distinct tones")
    func familyTones() {
        for (name, accent) in Self.harnessAccents {
            for appearance in ModelColorAppearance.allCases {
                let tones = (0..<4).map { Self.merged($0, 0, accent, appearance) }
                for i in tones.indices {
                    for j in tones.indices where j > i {
                        let difference = OKLCH.difference(tones[i], tones[j])
                        #expect(
                            difference >= Self.floor(appearance, dark: 0.060, light: 0.045),
                            "\(name) \(appearance) tones \(i)/\(j): \(difference)")
                    }
                }
            }
        }
    }

    @Test("one account's families wear distinct base colors")
    func ledgerFamilies() {
        for (name, accent) in Self.harnessAccents {
            for appearance in ModelColorAppearance.allCases {
                let bases = Self.ledgerHueSlots.map { Self.ledger($0, 0, accent, appearance) }
                for i in bases.indices {
                    for j in bases.indices where j > i {
                        let difference = OKLCH.difference(bases[i], bases[j])
                        // Gemini's accent IS a blue, and so is the first
                        // fixed hue (0.081 apart as designed). On light both
                        // sit above the band and meet near its top: a known,
                        // narrower gap for a deprecated harness's second
                        // family, held to its own floor rather than hidden.
                        let knownBlues = name == "gemini" && appearance == .light && i == 0 && j == 1
                        #expect(
                            difference >= (knownBlues ? 0.035 : 0.05),
                            "\(name) \(appearance) hues \(i)/\(j): \(difference)")
                    }
                }
            }
        }
    }

    @Test("the derivation is deterministic")
    func deterministic() {
        let accent = Self.harnessAccents["codex"]!
        for appearance in ModelColorAppearance.allCases {
            #expect(Self.ledger(3, 2, accent, appearance) == Self.ledger(3, 2, accent, appearance))
            #expect(Self.merged(1, 4, accent, appearance) == Self.merged(1, 4, accent, appearance))
        }
    }

    // MARK: - Helpers

    /// The color as the screen draws it: each channel rounded to a byte.
    static func bytes(_ color: RGBColor) -> RGBColor {
        func byte(_ value: Double) -> Double { (value * 255).rounded() / 255 }
        return RGBColor(red: byte(color.red), green: byte(color.green), blue: byte(color.blue))
    }

    private func forEveryColor(
        _ body: (_ derivation: String, _ hueSlot: Int, _ accent: RGBColor, ModelColorAppearance, RGBColor) -> Void
    ) {
        let accents = Array(Self.harnessAccents.values) + Self.stressAccents
        for accent in accents {
            for appearance in ModelColorAppearance.allCases {
                for shade in Self.shadeSlots {
                    for hue in Self.ledgerHueSlots {
                        body("ledger", hue, accent, appearance, Self.ledger(hue, shade, accent, appearance))
                    }
                    for hue in Self.toneSlots {
                        body("merged", hue, accent, appearance, Self.merged(hue, shade, accent, appearance))
                    }
                }
            }
        }
    }
}
