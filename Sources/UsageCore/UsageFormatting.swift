import Foundation

/// One of the three menu bar positions: session, weekly-all, worst-scoped.
public struct MenuBarSegment: Sendable, Equatable {
    public let percent: Int?
    public let level: DisplayLevel

    public init(percent: Int?, level: DisplayLevel) {
        self.percent = percent
        self.level = level
    }
}

public enum UsageFormatting {
    /// The menu bar triple (spec §8): rank-0, rank-1, then the maximum of the
    /// scoped percentages carrying the worst scoped level.
    public static func menuBarSegments(from meters: [Meter]) -> [MenuBarSegment] {
        let session = meters.first { $0.rank == 0 }
        let weekly = meters.first { $0.rank == 1 }
        let scoped = meters.filter { $0.rank == 2 }
        return [
            MenuBarSegment(percent: session?.percent, level: session?.level ?? .normal),
            MenuBarSegment(percent: weekly?.percent, level: weekly?.level ?? .normal),
            MenuBarSegment(
                percent: scoped.compactMap(\.percent).max(),
                level: scoped.map(\.level).max() ?? .normal
            ),
        ]
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

    /// "09:45" — for "Updated …" and "cached …" annotations.
    public static func clockTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
