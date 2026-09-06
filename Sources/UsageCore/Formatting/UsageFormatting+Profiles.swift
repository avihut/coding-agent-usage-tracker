import Foundation

/// The two lines a profile wears in the account strip and its Settings
/// card, phrased once so the panel, the CLI's `accounts` table and the
/// digest agree.
extension UsageFormatting {
    /// "S resets in 2h 10m · W runs out Sat 14:00" — the session and weekly
    /// meters' next event each, in `resetText`/`exhaustText`'s tiers; a
    /// predicted crossing outranks the routine reset. Nil when neither
    /// meter has anything to say.
    public static func accountStripCaption(
        meters: [Meter], predictions: [String: UsagePrediction], now: Date,
        timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String? {
        let parts: [String] = [(0, "S"), (1, "W")].compactMap { rank, tag in
            guard let meter = meters.first(where: { $0.rank == rank }) else { return nil }
            if let exhaustsAt = predictions[meter.label]?.exhaustsAt {
                return "\(tag) \(exhaustText(exhaustsAt, now: now, timeZone: timeZone, locale: locale))"
            }
            if let resetsAt = meter.resetsAt {
                return "\(tag) \(resetText(resetsAt, now: now, timeZone: timeZone, locale: locale))"
            }
            return nil
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Active · last used 12 min ago · Updated 15:02" — the state word by
    /// the last session write (Active within the hour, Quiet inside the
    /// dormancy window, Dormant beyond, "No sessions yet" without one), the
    /// write's age, and the meters' freshness when known.
    public static func profileStateLine(
        lastWrite: Date?, fetchedAt: Date?, now: Date,
        calendar: Calendar = .current, timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        var parts: [String] = []
        if let lastWrite {
            let age = now.timeIntervalSince(lastWrite)
            if age <= 3600 {
                parts.append("Active")
            } else if age <= Dormancy.window {
                parts.append("Quiet")
            } else {
                parts.append("Dormant")
            }
            parts.append("last used " + lastUsedText(lastWrite, now: now, timeZone: timeZone, locale: locale))
        } else {
            parts.append("No sessions yet")
        }
        if let fetchedAt {
            parts.append("Updated " + updatedStamp(
                fetchedAt, now: now, calendar: calendar, timeZone: timeZone, locale: locale))
        }
        return parts.joined(separator: " · ")
    }

    /// "just now" / "12 min ago" / "3 hr ago" / "2 days ago" inside a week,
    /// "Aug 2" beyond.
    static func lastUsedText(
        _ date: Date, now: Date, timeZone: TimeZone, locale: Locale
    ) -> String {
        let age = max(0, now.timeIntervalSince(date))
        if age < 60 { return "just now" }
        if age < 3600 { return "\(Int(age / 60)) min ago" }
        if age < 86400 { return "\(Int(age / 3600)) hr ago" }
        if age < 7 * 86400 {
            let days = Int(age / 86400)
            return days == 1 ? "yesterday" : "\(days) days ago"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
