import Foundation

/// The macOS accent swatches, pinned as data so a host without AppKit (the
/// usaged daemon) can publish the same `systemAccent` the app would. Values
/// are `NSColor.controlAccentColor` resolved in the dark appearance's sRGB
/// space for each `AppleAccentColor` global — the control swatch, which is
/// deliberately more muted than the raw `systemPurple`-style colors —
/// captured 2026-08-16 on macOS 15 via a scratch AppKit run. The app host
/// converts the live NSColor instead and only agrees with this table; the
/// table's job is the AppKit-free path.
public enum SystemAccentPalette {
    /// `AppleAccentColor` int → dark-appearance control accent. Unset (or
    /// the multicolor sentinel, which has no single swatch) falls back to
    /// blue, matching how multicolor renders most controls.
    public static func color(appleAccentColor: Int?) -> RGBColor {
        switch appleAccentColor {
        case -1: RGBColor(red: 0.549, green: 0.549, blue: 0.549) // graphite
        case 0: RGBColor(red: 1.000, green: 0.322, blue: 0.341) // red
        case 1: RGBColor(red: 0.969, green: 0.510, blue: 0.106) // orange
        case 2: RGBColor(red: 1.000, green: 0.776, blue: 0.000) // yellow
        case 3: RGBColor(red: 0.384, green: 0.729, blue: 0.275) // green
        case 5: RGBColor(red: 0.647, green: 0.314, blue: 0.655) // purple
        case 6: RGBColor(red: 0.969, green: 0.310, blue: 0.620) // pink
        default: RGBColor(red: 0.000, green: 0.478, blue: 1.000) // blue
        }
    }

    /// Where the daemon reads the user's accent choice: the global defaults
    /// domain, visible through any process's standard search list.
    public static let defaultsKey = "AppleAccentColor"
}
