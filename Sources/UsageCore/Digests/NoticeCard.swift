import Foundation

/// The digest's notifications block. Nil on `LiveState` means the writer
/// emits no notices (a build before 0.93.0); an empty `items` means nothing
/// is pending. Consumers render, never compute: the menu bar indicator,
/// the dismissable flag and every line of copy are decided here.
public struct NoticesCard: Codable, Sendable, Equatable {
    /// Light the menu bar's pending-notice dot: some pending notice has no
    /// menu bar surface of its own. An active outage alone does not — the
    /// glyph capsule already says it.
    public let indicator: Bool
    public let pendingCount: Int
    /// Pending notices, ongoing first, then newest first.
    public let items: [NoticeCard]

    public init(indicator: Bool, pendingCount: Int, items: [NoticeCard]) {
        self.indicator = indicator
        self.pendingCount = pendingCount
        self.items = items
    }
}

public struct NoticeCard: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    /// `Notice.Kind.rawValue` — "reset" | "outage"; unknown kinds render
    /// generically by title.
    public let kind: String
    /// Incident impact for outages ("minor" | "major" | "critical"); nil
    /// for kinds without a severity (the reset wears the vendor's accent).
    public let severity: String?
    public let title: String
    public let detail: String?
    /// The time line, pre-phrased: "~21:10 yesterday", "Ongoing · 30 min",
    /// "01:10 – 03:20 · 2 hr 10 min".
    public let when: String
    public let occurredAt: Date
    public let endedAt: Date?
    public let ongoing: Bool
    public let dismissable: Bool
    public let seen: Bool
    /// The notice already shows in the menu bar by other means (the
    /// ongoing outage's glyph capsule) — it does not light the dot.
    public let ownsMenuBarSurface: Bool
    public let url: String?
    public let components: [String]
    /// The meter that voiced a reset (the one that stood highest going in)
    /// — where a click lands when no official record exists. Nil for
    /// outages, and absent from digests written before it existed.
    public let meterLabel: String?

    public init(
        id: String, kind: String, severity: String?, title: String, detail: String?,
        when: String, occurredAt: Date, endedAt: Date?, ongoing: Bool, dismissable: Bool,
        seen: Bool, ownsMenuBarSurface: Bool, url: String?, components: [String],
        meterLabel: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
        self.when = when
        self.occurredAt = occurredAt
        self.endedAt = endedAt
        self.ongoing = ongoing
        self.dismissable = dismissable
        self.seen = seen
        self.ownsMenuBarSurface = ownsMenuBarSurface
        self.url = url
        self.components = components
        self.meterLabel = meterLabel
    }
}

/// Facts → words, once. Copy pinned by NoticePhrasingTests; the faces
/// print these strings verbatim.
public enum NoticePhrasing {
    public static func card(
        pending notices: [Notice], serviceName: String, now: Date,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> NoticesCard {
        let items = notices.map {
            card($0, serviceName: serviceName, now: now, calendar: calendar, locale: locale)
        }
        return NoticesCard(
            indicator: items.contains { !$0.ownsMenuBarSurface },
            pendingCount: items.count,
            items: items)
    }

    public static func card(
        _ notice: Notice, serviceName: String, now: Date,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> NoticeCard {
        let words = phrase(notice, serviceName: serviceName, now: now, calendar: calendar, locale: locale)
        return NoticeCard(
            id: notice.id, kind: notice.kind,
            severity: notice.kindValue == .outage ? notice.impact : nil,
            title: words.title, detail: words.detail, when: words.when,
            occurredAt: notice.occurredAt, endedAt: notice.endedAt,
            ongoing: notice.ongoing, dismissable: notice.isDismissable,
            seen: notice.seenAt != nil,
            // The ongoing outage IS the glyph capsule (`alarmingImpact`).
            ownsMenuBarSurface: notice.kindValue == .outage && notice.ongoing,
            url: notice.url, components: notice.components,
            meterLabel: notice.meterLabel)
    }

    struct Words: Equatable {
        let title: String
        let detail: String?
        let when: String
    }

    static func phrase(
        _ notice: Notice, serviceName: String, now: Date, calendar: Calendar, locale: Locale
    ) -> Words {
        switch notice.kindValue {
        case .reset:
            let detail: String
            if let label = notice.meterLabel, let from = notice.fromPercent, from > 0 {
                detail = "\(label) fell from \(from)% ahead of its reset."
            } else {
                detail = "Limits emptied ahead of their reset."
            }
            return Words(
                title: "Limit reset · \(serviceName)", detail: detail,
                when: "~" + dayClock(notice.occurredAt, now: now, calendar: calendar, locale: locale))

        case .outage:
            let name = notice.subject ?? "Incident"
            if notice.ongoing {
                var detail = phaseLabel(notice.phase)
                if let message = notice.message, !message.isEmpty {
                    detail += " · “\(message)”"
                }
                return Words(
                    title: name, detail: detail,
                    when: "Ongoing · " + UsageFormatting.duration(
                        max(0, now.timeIntervalSince(notice.occurredAt))))
            }
            let end = notice.endedAt ?? now
            let length = UsageFormatting.duration(max(0, end.timeIntervalSince(notice.occurredAt)))
            if notice.seenWhileOngoing {
                return Words(
                    title: "Outage ended", detail: "\(name) · resolved",
                    when: dayClock(end, now: now, calendar: calendar, locale: locale)
                        + " · lasted \(length)")
            }
            let title = isOvernight(notice.occurredAt, end, calendar: calendar)
                ? "Outage overnight" : "Outage while away"
            return Words(
                title: title, detail: "\(name) · resolved",
                when: dayRange(notice.occurredAt, end, now: now, calendar: calendar, locale: locale)
                    + " · \(length)")

        case nil:
            return Words(
                title: notice.subject ?? notice.kind, detail: notice.message,
                when: dayClock(notice.occurredAt, now: now, calendar: calendar, locale: locale))
        }
    }

    /// "Monitoring" from "monitoring".
    static func phaseLabel(_ phase: String?) -> String {
        guard let phase, !phase.isEmpty else { return "Ongoing" }
        return phase.prefix(1).uppercased() + phase.dropFirst()
    }

    /// "21:10" today, "21:10 yesterday", "Thu 21:10" within the week, else
    /// "Sep 4, 21:10".
    static func dayClock(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let clock = clockTime(date, calendar: calendar, locale: locale)
        switch dayWord(date, now: now, calendar: calendar, locale: locale) {
        case .today: return clock
        case .yesterday: return "\(clock) yesterday"
        case .named(let day): return "\(day) \(clock)"
        }
    }

    /// "01:10 – 03:20", prefixed with the START's day word when it isn't
    /// today: "yesterday 01:10 – 03:20", "Thu 01:10 – 03:20".
    static func dayRange(
        _ start: Date, _ end: Date, now: Date, calendar: Calendar, locale: Locale
    ) -> String {
        let range = "\(clockTime(start, calendar: calendar, locale: locale)) – "
            + clockTime(end, calendar: calendar, locale: locale)
        switch dayWord(start, now: now, calendar: calendar, locale: locale) {
        case .today: return range
        case .yesterday: return "yesterday \(range)"
        case .named(let day): return "\(day) \(range)"
        }
    }

    /// Any part of the span inside 22:00–08:00 local reads as overnight.
    static func isOvernight(_ start: Date, _ end: Date, calendar: Calendar) -> Bool {
        var probe = start
        while probe <= end {
            let hour = calendar.component(.hour, from: probe)
            if hour >= 22 || hour < 8 { return true }
            probe = probe.addingTimeInterval(1800)
        }
        let hour = calendar.component(.hour, from: end)
        return hour >= 22 || hour < 8
    }

    private enum DayWord { case today, yesterday, named(String) }

    private static func dayWord(
        _ date: Date, now: Date, calendar: Calendar, locale: Locale
    ) -> DayWord {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = now.timeIntervalSince(date) < 6 * 86400 ? "EEE" : "MMM d,"
        return .named(formatter.string(from: date))
    }

    private static func clockTime(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        UsageFormatting.clockTime(date, timeZone: calendar.timeZone)
    }
}
