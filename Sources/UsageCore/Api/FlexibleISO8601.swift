import Foundation

/// Parses the timestamps this app meets: the usage endpoint's `resets_at`
/// and every line of every local transcript.
///
/// The live API emits six fractional digits and a numeric offset
/// (`2026-08-07T10:39:59.137024+00:00`), which both `ISO8601DateFormatter`
/// variants reject; transcripts write three digits and `Z`; spec fixtures
/// use plain `Z` forms.
///
/// HOT PATH, by the numbers: a corpus re-parse calls this once per
/// transcript line — hundreds of thousands of times — and the pre-v0.91.0
/// version built three fresh formatters per call (ICU allocates a
/// `TimeZoneFormat` each time). A daemon re-parsing the corpus under the
/// longer slot retention sat in that allocation for its entire runtime
/// (sampled 2026-09-04: 100% of frames under `-[NSDateFormatter
/// dateFromString:]`). So the canonical shape — `yyyy-MM-ddTHH:mm:ss`, an
/// optional fraction of any length, then `Z` or `±HH[:]MM` — is parsed by
/// hand with integer arithmetic (days-from-civil, no calendar object), and
/// only a string outside that grammar falls through to formatters, which
/// are now built once. Equivalence with the formatter path is pinned by
/// FlexibleISO8601Tests.
enum FlexibleISO8601 {
    static func date(from string: String) -> Date? {
        if let fast = fastPath(string) { return fast }
        return slowPath(string)
    }

    // MARK: - Fast path

    /// `2026-08-01T10:01:00.000Z`, `…00Z`, `…00.137024+00:00`, `…00+0200`.
    /// Returns nil for anything it doesn't fully understand, so the
    /// formatters keep the last word on unusual input.
    static func fastPath(_ string: String) -> Date? {
        let s = Array(string.utf8)
        // Minimum: yyyy-MM-ddTHH:mm:ssZ = 20 bytes.
        guard s.count >= 20 else { return nil }
        func digit(_ i: Int) -> Int? {
            let c = s[i]
            return c >= 48 && c <= 57 ? Int(c - 48) : nil
        }
        func number(_ from: Int, _ count: Int) -> Int? {
            var value = 0
            for i in from..<(from + count) {
                guard let d = digit(i) else { return nil }
                value = value * 10 + d
            }
            return value
        }
        guard s[4] == 45, s[7] == 45, s[10] == 84 || s[10] == 116,  // - - T/t
              s[13] == 58, s[16] == 58,                              // : :
              let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2)
        else { return nil }
        guard (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second < 60
        else { return nil }

        var index = 19
        var fraction = 0.0
        if index < s.count, s[index] == 46 {  // .
            index += 1
            var scale = 0.1
            var digits = 0
            while index < s.count, let d = digit(index) {
                fraction += Double(d) * scale
                scale /= 10
                digits += 1
                index += 1
            }
            guard digits > 0 else { return nil }
        }

        guard index < s.count else { return nil }
        var offsetSeconds = 0
        switch s[index] {
        case 90, 122:  // Z / z
            index += 1
        case 43, 45:  // + / -
            let sign = s[index] == 45 ? -1 : 1
            index += 1
            guard let oh = number(index, 2) else { return nil }
            index += 2
            if index < s.count, s[index] == 58 { index += 1 }  // optional :
            guard let om = number(index, 2), oh < 24, om < 60 else { return nil }
            index += 2
            offsetSeconds = sign * (oh * 3600 + om * 60)
        default:
            return nil
        }
        guard index == s.count else { return nil }

        // Days from civil (Howard Hinnant's algorithm), proleptic Gregorian.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let seconds = Double(days) * 86_400 + Double(hour * 3600 + minute * 60 + second)
        return Date(timeIntervalSince1970: seconds + fraction - Double(offsetSeconds))
    }

    // MARK: - Slow path (built once)

    static func slowPath(_ string: String) -> Date? {
        if let date = microsecondsFormatter.date(from: string) { return date }
        if let date = fractionalFormatter.date(from: string) { return date }
        return plainFormatter.date(from: string)
    }

    // nonisolated(unsafe): DateFormatter and ISO8601DateFormatter are
    // documented thread-safe for formatting and parsing once configured
    // (Foundation release notes, macOS 10.9+), and nothing mutates these
    // after construction. Sharing them is the point — see the header.
    nonisolated(unsafe) private static let microsecondsFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        return formatter
    }()

    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plainFormatter = ISO8601DateFormatter()
}
