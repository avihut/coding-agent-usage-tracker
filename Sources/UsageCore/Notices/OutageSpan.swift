import Foundation

/// One incident on the provider's status page as a span of time — the
/// chart's second floor (v0.94.0, user-directed): the outage floor below the
/// session strip, so "was I working while it was down" is a vertical read.
/// Facts only; the faces decide color (by `severity`) and words.
///
/// Rides the digest as `LiveState.outages` (additive; nil = the writer
/// records no outages, [] = none within retention — nil ≠ empty). Also the
/// hosting app's own type, so the two hosts draw one shape.
public struct OutageSpan: Codable, Sendable, Equatable, Identifiable {
    /// The incident's id — `Notice.outageID(incidentID:)` without the prefix.
    public let id: String
    public let title: String
    /// Statuspage impact: "minor" | "major" | "critical" (nil when the page
    /// gave none — the faces fall back to the unknown grey).
    public let severity: String?
    public let start: Date
    /// Nil while `ongoing` — the faces hold the nub open to now.
    public let end: Date?
    public let ongoing: Bool
    public let components: [String]
    /// The incident's report; the click-through when present.
    public let url: String?

    public init(
        id: String, title: String, severity: String?, start: Date, end: Date?,
        ongoing: Bool, components: [String] = [], url: String? = nil
    ) {
        self.id = id
        self.title = title
        self.severity = severity
        self.start = start
        self.end = end
        self.ongoing = ongoing
        self.components = components
        self.url = url
    }

    /// The span as drawn: an ongoing incident reaches `now`.
    public func interval(now: Date) -> DateInterval {
        let finish = max(start, end ?? now)
        return DateInterval(start: start, end: finish)
    }

    /// The part of the span inside `domain`, ongoing ones ending at `now`;
    /// nil when it lies outside. Sub-second slivers are still returned —
    /// the chart decides what is drawable.
    public func clipped(to domain: DateInterval, now: Date) -> DateInterval? {
        let span = interval(now: now)
        let start = max(span.start, domain.start)
        let end = min(span.end, domain.end)
        guard start <= end, span.end >= domain.start, span.start <= domain.end else { return nil }
        return DateInterval(start: start, end: end)
    }
}

/// Outage notices → drawable spans. Pure; the engine passes the ledger's
/// whole record (pending AND dismissed — a dismissed notice is still a fact
/// the chart owes), and the retention here is why `NoticeLedger` keeps
/// outage rows past the dismissed-row month.
public enum OutageTimeline {
    /// Matches the sample history and the token timeline: every window the
    /// popover can page back to has its outages, like its curves.
    public static let retention: TimeInterval = 56 * 86400

    /// Chronological by start. Maintenance never reaches here — the status
    /// card keeps it apart and the detector records incidents only.
    public static func spans(
        from notices: [Notice], now: Date, retention: TimeInterval = retention
    ) -> [OutageSpan] {
        let cutoff = now.addingTimeInterval(-retention)
        return notices
            .filter { notice in
                guard notice.kindValue == .outage else { return false }
                return notice.ongoing || (notice.endedAt ?? notice.occurredAt) >= cutoff
            }
            .sorted { $0.occurredAt < $1.occurredAt }
            .map { notice in
                OutageSpan(
                    id: String(notice.id.dropFirst("outage|".count)),
                    title: notice.subject ?? "Incident",
                    severity: notice.impact,
                    start: notice.occurredAt,
                    end: notice.ongoing ? nil : (notice.endedAt ?? notice.occurredAt),
                    ongoing: notice.ongoing,
                    components: notice.components,
                    url: notice.url)
            }
    }
}
