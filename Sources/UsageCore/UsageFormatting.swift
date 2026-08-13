import Foundation

/// One of the three menu bar positions: session, weekly-all, worst-scoped.
/// `tag` is the single-letter stat identifier shown before the number.
public struct MenuBarSegment: Sendable, Equatable {
    public let tag: String
    public let percent: Int?
    public let level: DisplayLevel

    public init(tag: String, percent: Int?, level: DisplayLevel) {
        self.tag = tag
        self.percent = percent
        self.level = level
    }
}

public enum UsageFormatting {
    /// The menu bar triple (spec §8): rank-0, rank-1, then the maximum of the
    /// scoped percentages carrying the worst scoped level. Tags: S(ession),
    /// W(eekly), and the scoped model's initial (e.g. F for Fable).
    public static func menuBarSegments(from meters: [Meter]) -> [MenuBarSegment] {
        let session = meters.first { $0.rank == 0 }
        let weekly = meters.first { $0.rank == 1 }
        let scoped = meters.filter { $0.rank == 2 }
        let topScoped = scoped.max { ($0.percent ?? -1) < ($1.percent ?? -1) }
        return [
            MenuBarSegment(tag: "S", percent: session?.percent, level: session?.level ?? .normal),
            MenuBarSegment(tag: "W", percent: weekly?.percent, level: weekly?.level ?? .normal),
            MenuBarSegment(
                tag: scopedTag(for: topScoped?.label),
                percent: scoped.compactMap(\.percent).max(),
                level: scoped.map(\.level).max() ?? .normal
            ),
        ]
    }

    /// "Weekly · Fable" → "F"; any other label → its first letter.
    static func scopedTag(for label: String?) -> String {
        guard let label else { return "M" }
        let name = label.hasPrefix("Weekly · ") ? String(label.dropFirst("Weekly · ".count)) : label
        return name.first.map { String($0).uppercased() } ?? "M"
    }

    /// "resets in 3h 20m" under 24 hours, "resets Sat 14:00" beyond (spec §8).
    public static func resetText(
        _ resetsAt: Date,
        now: Date,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        let interval = resetsAt.timeIntervalSince(now)
        guard interval > 0 else { return "resets soon" }
        if interval < 24 * 3600 {
            let minutes = Int((interval / 60).rounded(.up))
            let (hours, remainder) = (minutes / 60, minutes % 60)
            if hours == 0 { return "resets in \(remainder)m" }
            if remainder == 0 { return "resets in \(hours)h" }
            return "resets in \(hours)h \(remainder)m"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE HH:mm"
        return "resets \(formatter.string(from: resetsAt))"
    }

    /// "next in 4m 32s" — live countdown to the scheduled refresh.
    public static func countdownText(to date: Date, now: Date) -> String {
        let remaining = Int(date.timeIntervalSince(now).rounded())
        guard remaining > 0 else { return "next any moment" }
        let (minutes, seconds) = (remaining / 60, remaining % 60)
        if minutes >= 60 { return "next in \(minutes / 60)h \(minutes % 60)m" }
        if minutes == 0 { return "next in \(seconds)s" }
        return "next in \(minutes)m \(seconds)s"
    }

    /// "1.4M in · 84K out · 96% cached" — input side folds cache reads and
    /// writes together; the cached share says how much of it was discounted.
    /// Pass `cachedShare: false` where width is tighter than curiosity.
    public static func tallyText(_ tally: TokenTally, cachedShare: Bool = true) -> String {
        var text = "\(TokenFormat.compact(tally.inputSide)) in · \(TokenFormat.compact(tally.output)) out"
        if cachedShare, let share = tally.cachedShare {
            text += " · \(Int((share * 100).rounded()))% cached"
        }
        return text
    }

    /// "$4.20", "$1,234", "<$0.01" — cost estimates at API list prices.
    public static func money(_ dollars: Double) -> String {
        if dollars > 0 && dollars < 0.01 { return "<$0.01" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.roundingMode = .halfUp
        let digits = dollars >= 100 ? 0 : 2
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        let text = formatter.string(from: NSNumber(value: dollars)) ?? String(format: "%.2f", dollars)
        return "$\(text)"
    }

    /// "09:45" — for "Updated …" and "cached …" annotations.
    public static func clockTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
