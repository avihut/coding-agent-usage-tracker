import Foundation

/// A plain sRGB triple (0…1 components) — the digest's color vocabulary,
/// and the shared type behind every core color computation. UI layers wrap
/// it in their own color types; core never imports one.
public struct RGBColor: Codable, Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(_ accent: ProviderAccent) {
        self.init(red: accent.red, green: accent.green, blue: accent.blue)
    }
}

/// The continuous exhaustion-risk ramp: nil while the forecast is clean,
/// pure yellow where the projection touches the warning threshold, sliding
/// linearly to pure red where the limit is spent. Every risk surface — the
/// panel's meter bars and captions, the chart's projection curve and axis
/// label, the menu bar digits, the digest's resolved colors — blends
/// through this one function. The endpoints are the macOS dark-appearance
/// system yellow/red, pinned as data so every process and language renders
/// the same ramp.
public enum RiskRamp {
    public static let yellow = RGBColor(red: 1.0, green: 0.839, blue: 0.039)
    public static let red = RGBColor(red: 1.0, green: 0.271, blue: 0.227)

    public static func color(severity: Double) -> RGBColor? {
        guard severity > 0 else { return nil }
        let s = min(1, severity)
        return RGBColor(
            red: yellow.red + (red.red - yellow.red) * s,
            green: yellow.green + (red.green - yellow.green) * s,
            blue: yellow.blue + (red.blue - yellow.blue) * s)
    }
}
