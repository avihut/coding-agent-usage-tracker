import Foundation

/// One countdown the menu bar's "Runs out" element draws (0.98.0): which
/// limit, and the time in the bar's own compact dialect. Phrased HERE, in
/// core, so the renderer only lays glyphs out and a test can pin every
/// tier — and so a TUI cell could print the same words one day.
public struct MenuBarCountdown: Sendable, Equatable {
    public let tag: String
    /// "31m" / "1h 05m" / "Sat 14:00" — `resetText`'s tiers without the
    /// verb the bar has no room for.
    public let text: String
    /// True once the limit is gone and the countdown runs to its reset
    /// (drawn quiet with a ↺ rather than as the alarm capsule).
    public let spent: Bool
    /// The instant counted down to, for ordering and for the tick.
    public let at: Date

    public init(tag: String, text: String, spent: Bool, at: Date) {
        self.tag = tag
        self.text = text
        self.spent = spent
        self.at = at
    }
}

extension UsageFormatting {
    /// The countdowns a scope yields from the bar's segments, in meter
    /// order — EMPTY whenever no limit is forecast to run out before it
    /// resets and none is spent, which is the element's whole contract:
    /// quiet bars carry nothing.
    ///
    /// A segment at 100% counts down to its reset (the crossing is behind
    /// it); one whose displayed forecast crosses counts down to the
    /// crossing. `.earliest` keeps the one whose instant comes first.
    public static func menuBarCountdowns(
        _ segments: [MenuBarSegment], scope: RunsOutScope, now: Date,
        timeZone: TimeZone = .current, locale: Locale = .current
    ) -> [MenuBarCountdown] {
        let candidates: [MenuBarCountdown] = segments.enumerated().compactMap { index, segment in
            if let rank = scope.rank, rank != index { return nil }
            return countdown(for: segment, now: now, timeZone: timeZone, locale: locale)
        }
        guard scope == .earliest else { return candidates }
        return candidates.min { $0.at < $1.at }.map { [$0] } ?? []
    }

    static func countdown(
        for segment: MenuBarSegment, now: Date, timeZone: TimeZone, locale: Locale
    ) -> MenuBarCountdown? {
        if let percent = segment.percent, percent >= 100 {
            guard let resetsAt = segment.resetsAt, resetsAt > now else { return nil }
            return MenuBarCountdown(
                tag: segment.tag,
                text: compactEvent(resetsAt, now: now, timeZone: timeZone, locale: locale),
                spent: true, at: resetsAt)
        }
        guard let exhaustsAt = segment.exhaustsAt, exhaustsAt > now else { return nil }
        return MenuBarCountdown(
            tag: segment.tag,
            text: compactEvent(exhaustsAt, now: now, timeZone: timeZone, locale: locale),
            spent: false, at: exhaustsAt)
    }

    /// `eventPhrase` without its verb: "31m", "2h", "1h 05m" inside a day,
    /// "Sat 14:00" beyond. Minutes are zero-padded after an hour so the
    /// monospaced digits hold their width from one minute to the next.
    static func compactEvent(_ date: Date, now: Date, timeZone: TimeZone, locale: Locale) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "now" }
        if interval < 24 * 3600 {
            let minutes = Int((interval / 60).rounded(.up))
            let (hours, remainder) = (minutes / 60, minutes % 60)
            if hours == 0 { return "\(remainder)m" }
            if remainder == 0 { return "\(hours)h" }
            return "\(hours)h \(String(format: "%02d", remainder))m"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: date)
    }
}
