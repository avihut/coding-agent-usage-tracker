import Foundation

/// Dotted-integer release versions — "0.87.0", or the tag form "v0.87.0".
/// Anything that doesn't parse compares as not-newer: a malformed or
/// hijacked feed must never be able to raise the update flag.
public struct AppVersion: Equatable, Comparable, Sendable {
    public let parts: [Int]

    public init?(_ string: String) {
        var body = string.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("v") || body.hasPrefix("V") { body.removeFirst() }
        guard !body.isEmpty else { return nil }
        var parsed: [Int] = []
        for piece in body.split(separator: ".", omittingEmptySubsequences: false) {
            guard let value = Int(piece), value >= 0 else { return nil }
            parsed.append(value)
        }
        parts = parsed
    }

    /// Lexicographic over components, shorter side padded with zeros —
    /// "1.0" == "1.0.0", "0.10.0" > "0.9.9".
    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let width = max(a.parts.count, b.parts.count)
        for i in 0..<width {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    /// Equality pads exactly as `<` does — Comparable's total order and
    /// Equatable must agree, and a synthesized parts-array == would call
    /// "1.0" and "1.0.0" different versions.
    public static func == (a: AppVersion, b: AppVersion) -> Bool {
        !(a < b) && !(b < a)
    }

    /// The one question the updater asks. False unless BOTH sides parse and
    /// the candidate is strictly greater — equal, older, and unparseable all
    /// stay quiet.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidate = AppVersion(candidate), let current = AppVersion(current)
        else { return false }
        return current < candidate
    }
}
