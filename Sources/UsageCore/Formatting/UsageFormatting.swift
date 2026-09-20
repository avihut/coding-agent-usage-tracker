import Foundation

/// One menu bar position: a limit the account has, or its worst scoped one.
/// `tag` is the single-letter stat identifier shown before the number.
public struct MenuBarSegment: Sendable, Equatable {
    public let tag: String
    public let percent: Int?
    public let level: DisplayLevel
    /// The meter's exhaustion-risk scale (0…1) when a prediction exists —
    /// the renderer blends yellow→red by it, same as the panel's meter bar.
    /// Nil falls back to the discrete `level` palette.
    public let severity: Double?
    /// When the DISPLAYED forecast crosses the limit before the reset
    /// (0.98.0) — the smoothed verdict's red, never the raw one, so the
    /// bar's "Runs out" element can't pop in and out between two polls.
    /// Nil while the forecast is clean or merely yellow.
    public let exhaustsAt: Date?
    /// The meter's reset, for the spent case: once the limit is gone the
    /// countdown turns to when it comes back.
    public let resetsAt: Date?

    public init(
        tag: String, percent: Int?, level: DisplayLevel, severity: Double? = nil,
        exhaustsAt: Date? = nil, resetsAt: Date? = nil
    ) {
        self.tag = tag
        self.percent = percent
        self.level = level
        self.severity = severity
        self.exhaustsAt = exhaustsAt
        self.resetsAt = resetsAt
    }
}

public enum UsageFormatting {
    /// The menu bar's segments (spec §8): one per unscoped limit the account
    /// HAS, shortest window first, then the maximum of the scoped
    /// percentages carrying the worst scoped level. Tags come from each
    /// meter's own window (`tag(for:)` — S(ession), D(aily), W(eekly),
    /// M(onthly)) and the scoped model's initial (e.g. F for Fable). With
    /// predictions, each segment also carries its meter's exhaustion-risk
    /// severity (the scoped slot: the worst among its meters).
    public static func menuBarSegments(
        from meters: [Meter], predictions: [String: UsagePrediction] = [:]
    ) -> [MenuBarSegment] {
        func severity(_ meter: Meter?) -> Double? {
            meter.flatMap { predictions[$0.label]?.severity }
        }
        // The crossing only under the smoothed red verdict: a red verdict
        // always carries its date, and the two-refresh hysteresis is what
        // keeps a bar element from flickering.
        func exhaustsAt(_ meter: Meter?) -> Date? {
            guard let meter, let prediction = predictions[meter.label],
                  prediction.verdict == .red
            else { return nil }
            return prediction.exhaustsAt
        }
        // ONLY THE LIMITS THIS ACCOUNT HAS (0.101.0, user-reported: a Codex
        // account with one weekly limit drew `S35·W–·M–`). A segment stands
        // for a meter the provider reported — one with no number yet still
        // draws its dash, a limit that doesn't exist draws nothing — and its
        // letter comes from the meter's own window, never from the slot.
        let unscoped = meters.enumerated()
            .filter { $0.element.rank < 2 }
            .sorted {
                let (a, b) = ($0.element, $1.element)
                if a.rank != b.rank { return a.rank < b.rank }
                let (aWindow, bWindow) = (a.limitWindow ?? .infinity, b.limitWindow ?? .infinity)
                return aWindow != bWindow ? aWindow < bWindow : $0.offset < $1.offset
            }
            .map(\.element)
        var segments = unscoped.map { meter in
            MenuBarSegment(
                tag: tag(for: meter), percent: meter.percent, level: meter.level,
                severity: severity(meter), exhaustsAt: exhaustsAt(meter),
                resetsAt: meter.resetsAt)
        }
        let scoped = meters.filter { $0.rank == 2 }
        if let topScoped = scoped.max(by: { ($0.percent ?? -1) < ($1.percent ?? -1) }) {
            segments.append(MenuBarSegment(
                tag: scopedTag(for: topScoped),
                percent: scoped.compactMap(\.percent).max(),
                level: scoped.map(\.level).max() ?? .normal,
                severity: scoped.compactMap { severity($0) }.max(),
                exhaustsAt: scoped.compactMap { exhaustsAt($0) }.min(),
                resetsAt: topScoped.resetsAt))
        }
        return segments
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
        // Already crossed: the limit is spent and the only useful thing
        // left to say is when. Future-tense phrasing for a past crossing
        // ("runs out soon" at 100%) is the thing this branch exists to
        // prevent.
        guard exhaustsAt > now else {
            return "spent at \(stamp(exhaustsAt, now: now, timeZone: timeZone, locale: locale))"
        }
        return eventPhrase("runs out", exhaustsAt, now: now, timeZone: timeZone, locale: locale)
    }

    /// "~$38 extra (≈11% over)" — what a forecast overshoot would cost to
    /// buy at API list prices, the percent over beside it; "≈11% over"
    /// alone when nothing in the window carries a rate (absent is never
    /// $0). Both figures are approximations of a counterfactual — a
    /// subscription bills no tokens — hence the "~"/"≈" throughout.
    ///
    /// The percent floors at 1: an overshoot exists by construction here
    /// (it is what `ForecastOvershoot.estimate` refuses to return below
    /// 100), and "≈0% over" would read as no overshoot at all.
    ///
    /// `locale` rides along for parity with the other caption builders;
    /// `money` deliberately speaks one fixed dialect app-wide.
    public static func overshootCaption(
        _ overshoot: ForecastOvershoot, locale: Locale = .current
    ) -> String {
        let over = "≈\(max(1, Int(overshoot.percent.rounded())))% over"
        guard let cost = overshoot.cost else { return over }
        return "~\(money(cost)) extra (\(over))"
    }

    /// The forecast half of a meter's caption, for every surface that
    /// draws one: "runs out in 1h 05m" while the limit still has room,
    /// "spent at 15:32" once it's gone (or a bare "spent" when nothing
    /// witnessed the crossing), nil while the forecast is clean.
    ///
    /// An `overshoot` appends what the crossing would cost to cover —
    /// "runs out Mon 20:00 · ~$38 extra (≈11% over)" — and only on a
    /// FUTURE crossing: a limit already spent is a measurement, and the
    /// question there is when it comes back, not what it would have cost.
    /// Omitted, the caption is exactly what it always was.
    public static func forecastCaption(
        percent: Int?,
        exhaustsAt: Date?,
        overshoot: ForecastOvershoot? = nil,
        now: Date,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String? {
        if let percent, percent >= 100 {
            guard let exhaustsAt, exhaustsAt <= now else { return "spent" }
            return "spent at \(stamp(exhaustsAt, now: now, timeZone: timeZone, locale: locale))"
        }
        guard let exhaustsAt else { return nil }
        let text = exhaustText(exhaustsAt, now: now, timeZone: timeZone, locale: locale)
        guard exhaustsAt > now, let overshoot else { return text }
        return "\(text) · \(overshootCaption(overshoot, locale: locale))"
    }

    /// "9 days" / "1 day" / "5 hours" — countdown granularity that matches
    /// how slowly the sample history accumulates.
    public static func readinessText(_ remaining: TimeInterval) -> String {
        let days = Int((remaining / 86400).rounded(.up))
        if days > 1 { return "\(days) days" }
        let hours = max(1, Int((remaining / 3600).rounded(.up)))
        if hours >= 24 { return "1 day" }
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    /// The one sentence every face prints while the weekly rhythm is still
    /// being learned — under the app's 7D bars and under the pane's
    /// activity chart. Written here so both say it the same way.
    public static func forecastActivation(remaining: TimeInterval) -> String {
        "Personalized forecast activates in \(readinessText(remaining))"
            + " — learning your weekly rhythm."
    }

    /// A past instant: the clock alone today, the weekday too once the day
    /// has turned.
    public static func stamp(
        _ date: Date, now: Date, timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
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
