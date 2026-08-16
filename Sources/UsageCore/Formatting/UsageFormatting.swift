import Foundation

/// One of the three menu bar positions: session, weekly-all, worst-scoped.
/// `tag` is the single-letter stat identifier shown before the number.
public struct MenuBarSegment: Sendable, Equatable {
    public let tag: String
    public let percent: Int?
    public let level: DisplayLevel
    /// The meter's exhaustion-risk scale (0…1) when a prediction exists —
    /// the renderer blends yellow→red by it, same as the panel's meter bar.
    /// Nil falls back to the discrete `level` palette.
    public let severity: Double?

    public init(tag: String, percent: Int?, level: DisplayLevel, severity: Double? = nil) {
        self.tag = tag
        self.percent = percent
        self.level = level
        self.severity = severity
    }
}

public enum UsageFormatting {
    /// The menu bar triple (spec §8): rank-0, rank-1, then the maximum of the
    /// scoped percentages carrying the worst scoped level. Tags: S(ession),
    /// W(eekly), and the scoped model's initial (e.g. F for Fable). With
    /// predictions, each segment also carries its meter's exhaustion-risk
    /// severity (the scoped slot: the worst among its meters).
    public static func menuBarSegments(
        from meters: [Meter], predictions: [String: UsagePrediction] = [:]
    ) -> [MenuBarSegment] {
        func severity(_ meter: Meter?) -> Double? {
            meter.flatMap { predictions[$0.label]?.severity }
        }
        let session = meters.first { $0.rank == 0 }
        let weekly = meters.first { $0.rank == 1 }
        let scoped = meters.filter { $0.rank == 2 }
        let topScoped = scoped.max { ($0.percent ?? -1) < ($1.percent ?? -1) }
        return [
            MenuBarSegment(
                tag: "S", percent: session?.percent, level: session?.level ?? .normal,
                severity: severity(session)),
            MenuBarSegment(
                tag: "W", percent: weekly?.percent, level: weekly?.level ?? .normal,
                severity: severity(weekly)),
            MenuBarSegment(
                tag: scopedTag(for: topScoped),
                percent: scoped.compactMap(\.percent).max(),
                level: scoped.map(\.level).max() ?? .normal,
                severity: scoped.compactMap { severity($0) }.max()
            ),
        ]
    }

    /// The scoped meter's one-letter menu bar tag, from its model name as
    /// DATA (`scopedModelName`) — never parsed out of the display label.
    public static func scopedTag(for meter: Meter?) -> String {
        guard let meter else { return "M" }
        let name = meter.scopedModelName ?? meter.label
        return name.first.map { String($0).uppercased() } ?? "M"
    }

    /// "resets in 3h 20m" under 24 hours, "resets Sat 14:00" beyond (spec §8).
    public static func resetText(
        _ resetsAt: Date,
        now: Date,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        eventPhrase("resets", resetsAt, now: now, timeZone: timeZone, locale: locale)
    }

    /// "runs out in 2h 10m" / "runs out Sat 14:00" — the predicted limit
    /// crossing, in resetText's exact tiers so both halves of a caption
    /// line always speak the same dialect.
    public static func exhaustText(
        _ exhaustsAt: Date,
        now: Date,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        eventPhrase("runs out", exhaustsAt, now: now, timeZone: timeZone, locale: locale)
    }

    /// The shared future-event vocabulary: relative "in 3h 20m" inside a
    /// day, weekday-absolute "Sat 14:00" beyond, "soon" once it's due.
    private static func eventPhrase(
        _ verb: String, _ date: Date, now: Date, timeZone: TimeZone, locale: Locale
    ) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "\(verb) soon" }
        if interval < 24 * 3600 {
            let minutes = Int((interval / 60).rounded(.up))
            let (hours, remainder) = (minutes / 60, minutes % 60)
            if hours == 0 { return "\(verb) in \(remainder)m" }
            if remainder == 0 { return "\(verb) in \(hours)h" }
            return "\(verb) in \(hours)h \(remainder)m"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE HH:mm"
        return "\(verb) \(formatter.string(from: date))"
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

    /// "$15", "$6.25", "$0.50" — a per-token rate spoken per million tokens,
    /// the unit Anthropic's price list uses. Sub-dollar rates keep two
    /// decimals so "$0.50" doesn't clip to "$0.5".
    public static func ratePerMTok(_ perToken: Double) -> String {
        let value = perToken * 1_000_000
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.roundingMode = .halfUp
        formatter.minimumFractionDigits = value < 1 ? 2 : 0
        formatter.maximumFractionDigits = 2
        let text = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        return "$\(text)"
    }

    /// "3 min", "45 min", "1 hr 30 min", "7 days" — the refresh-pace dial's
    /// vocabulary, stretched to day scale for limit windows. Sub-minute
    /// precision is deliberately absent; so are minutes at day scale.
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        let (hours, restMinutes) = (minutes / 60, minutes % 60)
        if hours < 24 {
            return restMinutes == 0 ? "\(hours) hr" : "\(hours) hr \(restMinutes) min"
        }
        let (days, restHours) = (hours / 24, hours % 24)
        let dayText = days == 1 ? "1 day" : "\(days) days"
        return restHours == 0 ? dayText : "\(dayText) \(restHours) hr"
    }

    /// "09:45" — for "Updated …" and "cached …" annotations.
    /// The status line's "Updated …" stamp, day-aware: bare clock today,
    /// weekday-qualified within a week, date-qualified beyond — a local
    /// provider's data is only as fresh as the agent's last session, and a
    /// bare "14:32" from three days ago would read as today.
    public static func updatedStamp(
        _ date: Date, now: Date, calendar: Calendar = .current,
        timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return clockTime(date, timeZone: timeZone)
        }
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = locale
        formatter.dateFormat =
            now.timeIntervalSince(date) < 7 * 86400 ? "EEE HH:mm" : "MMM d HH:mm"
        return formatter.string(from: date)
    }

    public static func clockTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
