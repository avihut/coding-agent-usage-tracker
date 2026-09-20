import Foundation

/// What KIND of limit a window is, read off its own length (0.101.0,
/// user-reported: Codex began reporting ONE window of 10080 minutes in the
/// slot that used to hold its 5-hour session, and every face called a week
/// "Session (168h)" and tagged it `S`).
///
/// The rule this exists for: a limit's type is what its window SAYS, never
/// the slot a vendor's payload happened to carry it in. A provider whose
/// vocabulary names its limits outright (Claude's `session` / `weekly_all`)
/// keeps its own word; one that reports bare windows classifies them here,
/// and the menu bar's one-letter tag reads the same classification so the
/// letter can't disagree with the label beside it.
public enum LimitWindowKind: String, Sendable, Equatable, CaseIterable {
    case session, daily, weekly, monthly

    /// Boundaries sit well clear of the windows vendors actually use (5 h,
    /// 24 h, 7 d, 30 d), so a window a little off its round number — a
    /// 25-hour "day", an 8-day "week" — still lands where a person would
    /// put it. The session bound is `Meter.defaultRateWindow`'s own tier.
    public init(window: TimeInterval) {
        switch window {
        case ...(6 * 3600): self = .session
        case ...(36 * 3600): self = .daily
        case ...(8 * 86400): self = .weekly
        default: self = .monthly
        }
    }

    /// The menu bar's letter for this kind of limit.
    public var tag: String {
        switch self {
        case .session: "S"
        case .daily: "D"
        case .weekly: "W"
        case .monthly: "M"
        }
    }

    /// The normalized rank: 0 is the short rolling window a burst spends, 1
    /// every longer one. Rank 2 stays the scoped meters', which no bare
    /// window can claim.
    public var rank: Int { self == .session ? 0 : 1 }

    /// The label a bare window wears. The round windows take their everyday
    /// name; anything else says its length in the largest unit that fits.
    public func label(window: TimeInterval) -> String {
        switch self {
        case .session: "Session (\(UsageFormatting.windowName(window)))"
        case .daily: window == 86400 ? "Daily" : "Window (\(UsageFormatting.windowName(window)))"
        case .weekly: window == 7 * 86400 ? "Weekly" : "Window (\(UsageFormatting.windowName(window)))"
        case .monthly: window == 30 * 86400 ? "Monthly" : "Window (\(UsageFormatting.windowName(window)))"
        }
    }
}

extension UsageFormatting {
    /// A window's length the way a person says it: "45m", "5h", "1h 30m",
    /// "7d", "2d 12h" — days from 48 hours up, so a day still reads "24h"
    /// and a week never reads "168h".
    public static func windowName(_ window: TimeInterval) -> String {
        let minutes = max(0, Int((window / 60).rounded()))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 48 * 60 {
            let (hours, rest) = (minutes / 60, minutes % 60)
            return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        }
        let hours = Int((Double(minutes) / 60).rounded())
        let (days, rest) = (hours / 24, hours % 24)
        return rest == 0 ? "\(days)d" : "\(days)d \(rest)h"
    }

    /// A meter's one-letter menu bar tag. A scoped meter wears its model's
    /// initial; every other meter wears its WINDOW's letter, falling back to
    /// the rank's historical letter only when the window is unknown.
    public static func tag(for meter: Meter) -> String {
        if meter.rank >= 2 { return scopedTag(for: meter) }
        if let window = meter.limitWindow { return LimitWindowKind(window: window).tag }
        return meter.rank == 0 ? "S" : "W"
    }
}
