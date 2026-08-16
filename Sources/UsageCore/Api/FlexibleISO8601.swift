import Foundation

/// Parses the `resets_at` timestamps the usage endpoint actually sends.
///
/// The live API emits six fractional digits and a numeric offset
/// (`2026-08-07T10:39:59.137024+00:00`), which both `ISO8601DateFormatter`
/// variants reject. Spec fixtures use plain `Z` forms. Try the permissive
/// shape first, then the standard ones.
enum FlexibleISO8601 {
    static func date(from string: String) -> Date? {
        if let date = microsecondsFormatter().date(from: string) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        return plain.date(from: string)
    }

    private static func microsecondsFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        return formatter
    }
}
