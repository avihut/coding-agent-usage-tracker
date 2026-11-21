import Foundation

/// The two grounds a model color is drawn on. A color that holds 3:1 against
/// BOTH the dark and the light panel would need a relative luminance inside
/// [0.196, 0.246], a sliver with no room for a family of shades, so every
/// model color comes in one variant per appearance (user-reported 2026-11-21:
/// "the opus 5.5 color makes it look disabled").
public enum ModelColorAppearance: String, Sendable, CaseIterable {
    case dark
    case light
}

/// The constraint every model color satisfies: a minimum contrast against
/// the ground it is drawn on, a lightness that keeps its hue legible, and
/// the hue of the color it was derived from. Pure sRGB/OKLab arithmetic, no
/// AppKit, so the app, the digest and the tests agree to the bit.
public enum ModelColorLegibility {
    /// WCAG 2.2 SC 1.4.11 (non-text contrast): 3:1 for graphical objects.
    /// Bar segments and the 7pt legend swatches are exactly that.
    public static let minimumContrast = 3.0

    /// The ground each appearance is held against — the BINDING one, i.e.
    /// the plausible ground closest to the marks. Dark: the panel as the
    /// snapshot draws it and `windowBackgroundColor` (50,50,50); the live
    /// popover over a dark desktop measured (27,27,28), which is easier.
    /// Light: the snapshot's (236,236,236).
    public static func ground(_ appearance: ModelColorAppearance) -> RGBColor {
        switch appearance {
        case .dark: RGBColor(red: 50 / 255, green: 50 / 255, blue: 50 / 255)
        case .light: RGBColor(red: 236 / 255, green: 236 / 255, blue: 236 / 255)
        }
    }

    /// Past these an OKLab lightness stops reading as a hue: near-white on
    /// the dark ground, near-black on the light one.
    public static let darkLightnessCap = 0.90
    public static let lightLightnessFloor = 0.40

    // MARK: - Contrast

    /// WCAG relative luminance of an sRGB color.
    public static func luminance(_ color: RGBColor) -> Double {
        0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// The WCAG contrast ratio, 1...21, symmetric.
    public static func contrast(_ a: RGBColor, _ b: RGBColor) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    // MARK: - The band

    /// The OKLab lightnesses at which a color of this chroma and hue holds
    /// the minimum contrast on the appearance's ground and keeps its hue.
    /// The contrast edge is found by bisection on the color as it will be
    /// drawn (gamut-mapped), so the ratio holds exactly, not by a grey
    /// approximation. Above the ground's luminance contrast only grows with
    /// lightness on the dark side, and below it on the light side, so the
    /// predicate is monotone.
    public static func band(
        chroma: Double, hue: Double, on appearance: ModelColorAppearance
    ) -> ClosedRange<Double> {
        let ground = ground(appearance)
        func passes(_ lightness: Double) -> Bool {
            contrast(OKLCH(lightness: lightness, chroma: chroma, hue: hue).rgb, ground) >= minimumContrast
        }
        switch appearance {
        case .dark:
            var (fails, holds) = (0.0, 1.0)
            for _ in 0..<32 {
                let mid = (fails + holds) / 2
                if passes(mid) { holds = mid } else { fails = mid }
            }
            return holds...max(holds, darkLightnessCap)
        case .light:
            var (holds, fails) = (0.0, 1.0)
            for _ in 0..<32 {
                let mid = (fails + holds) / 2
                if passes(mid) { holds = mid } else { fails = mid }
            }
            return min(holds, lightLightnessFloor)...holds
        }
    }

    /// A color placed in its band: the design lightness fitted into the
    /// band, then moved `offset` of the band's width further up, wrapping
    /// back to the bottom — so distinct offsets stay distinct lightnesses
    /// in every appearance, however narrow its band. Hue is kept; chroma
    /// gives way only to stay inside sRGB.
    ///
    /// `exact` is the design color itself, when the caller has it unscaled:
    /// a color that needs no move comes back bit-identical rather than
    /// through an OKLab round trip, so slot 0 IS the brand accent wherever
    /// the accent already holds.
    static func place(
        _ design: OKLCH, offset: Double, on appearance: ModelColorAppearance, exact: RGBColor? = nil
    ) -> RGBColor {
        let band = band(chroma: design.chroma, hue: design.hue, on: appearance)
        if let exact, offset == 0, band.contains(design.lightness) { return exact }
        let width = band.upperBound - band.lowerBound
        guard width > 1e-9 else {
            return OKLCH(lightness: band.lowerBound, chroma: design.chroma, hue: design.hue).rgb
        }
        let fitted = min(max(design.lightness, band.lowerBound), band.upperBound)
        var position = (fitted - band.lowerBound) / width + offset
        while position > 1 + 1e-9 { position -= 1 }
        return OKLCH(
            lightness: band.lowerBound + position * width, chroma: design.chroma, hue: design.hue
        ).rgb
    }

    static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func gamma(_ value: Double) -> Double {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }
}

/// A color in OKLCH (Björn Ottosson's OKLab in polar form): lightness 0...1,
/// chroma, hue in radians. Lightness and hue are perceptual, which is what
/// "keep the agent's hue, change only how light it is" needs.
public struct OKLCH: Equatable, Sendable {
    public var lightness: Double
    public var chroma: Double
    public var hue: Double

    public init(lightness: Double, chroma: Double, hue: Double) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
    }

    public init(_ color: RGBColor) {
        let lab = Self.lab(
            ModelColorLegibility.linear(color.red),
            ModelColorLegibility.linear(color.green),
            ModelColorLegibility.linear(color.blue))
        self.init(lightness: lab.l, chroma: (lab.a * lab.a + lab.b * lab.b).squareRoot(), hue: atan2(lab.b, lab.a))
    }

    /// The sRGB color, chroma reduced (hue and lightness kept) until it fits
    /// the gamut.
    public var rgb: RGBColor {
        var linear = Self.linearRGB(lightness, chroma, hue)
        if !Self.inGamut(linear) {
            var (fits, overflows) = (0.0, chroma)
            for _ in 0..<24 {
                let mid = (fits + overflows) / 2
                if Self.inGamut(Self.linearRGB(lightness, mid, hue)) { fits = mid } else { overflows = mid }
            }
            linear = Self.linearRGB(lightness, fits, hue)
        }
        func encode(_ value: Double) -> Double { min(1, max(0, ModelColorLegibility.gamma(min(1, max(0, value))))) }
        return RGBColor(red: encode(linear.r), green: encode(linear.g), blue: encode(linear.b))
    }

    /// Euclidean distance in OKLab — the perceptual difference ΔE_ok.
    public static func difference(_ x: RGBColor, _ y: RGBColor) -> Double {
        let (p, q) = (OKLCH(x), OKLCH(y))
        let da = p.chroma * cos(p.hue) - q.chroma * cos(q.hue)
        let db = p.chroma * sin(p.hue) - q.chroma * sin(q.hue)
        let dl = p.lightness - q.lightness
        return (dl * dl + da * da + db * db).squareRoot()
    }

    private static func lab(_ r: Double, _ g: Double, _ b: Double) -> (l: Double, a: Double, b: Double) {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    private static func linearRGB(
        _ lightness: Double, _ chroma: Double, _ hue: Double
    ) -> (r: Double, g: Double, b: Double) {
        let (a, b) = (chroma * cos(hue), chroma * sin(hue))
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    private static func inGamut(_ c: (r: Double, g: Double, b: Double)) -> Bool {
        let tolerance = 1e-7
        return c.r >= -tolerance && c.r <= 1 + tolerance
            && c.g >= -tolerance && c.g <= 1 + tolerance
            && c.b >= -tolerance && c.b <= 1 + tolerance
    }
}
