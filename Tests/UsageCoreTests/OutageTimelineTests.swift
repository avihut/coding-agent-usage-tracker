import Foundation
import Testing

@testable import UsageCore

/// The outage floor's data: ledger outage rows → spans, the retention that
/// keeps them, the backfill split between news and facts, and the audit
/// model's clipping.
@Suite("Outage timeline")
struct OutageTimelineTests {
    private func at(_ hours: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: hours * 3600)
    }

    private func outage(
        _ id: String, start: Double, end: Double?, dismissed: Double? = nil,
        impact: String? = "major", components: [String] = ["Claude Code"]
    ) -> Notice {
        Notice(
            id: Notice.outageID(incidentID: id), kind: "outage", occurredAt: at(start),
            endedAt: end.map(at), ongoing: end == nil, dismissedAt: dismissed.map(at),
            recordedAt: at(start),
            subject: "Elevated errors", impact: impact, phase: end == nil ? "identified" : "resolved",
            components: components, url: "https://stspg.io/x")
    }

    private func reset(_ hours: Double, dismissed: Double? = nil) -> Notice {
        Notice(
            id: Notice.resetID(at: at(hours)), kind: "reset", occurredAt: at(hours),
            endedAt: at(hours), dismissedAt: dismissed.map(at), recordedAt: at(hours),
            meterLabel: "Weekly (all)", fromPercent: 71)
    }

    // MARK: Spans

    @Test func outageRowsBecomeSpansOldestFirstAndResetsStayOut() {
        let spans = OutageTimeline.spans(
            from: [reset(5), outage("b", start: 10, end: 12), outage("a", start: 1, end: 3, dismissed: 4)],
            now: at(20))
        #expect(spans.map(\.id) == ["a", "b"])
        #expect(spans[0].start == at(1) && spans[0].end == at(3) && !spans[0].ongoing)
        #expect(spans[0].severity == "major")
        #expect(spans[0].components == ["Claude Code"])
        #expect(spans[0].url == "https://stspg.io/x")
        #expect(spans[0].title == "Elevated errors")
    }

    /// Statuspage posts informational incidents with impact "none" (an
    /// add-in's availability, trouble reaching the status page itself).
    /// Nothing was down, and their color would be the healthy green.
    @Test func impactNoneIsNotAnOutage() {
        let spans = OutageTimeline.spans(
            from: [
                outage("info", start: 1, end: 3, impact: "none"),
                outage("real", start: 5, end: 6, impact: "minor"),
                outage("unrated", start: 7, end: 8, impact: nil),
            ],
            now: at(10))
        #expect(spans.map(\.id) == ["real", "unrated"])
    }

    @Test func anOngoingOutageHasNoEndAndReachesNow() {
        let spans = OutageTimeline.spans(from: [outage("live", start: 10, end: nil)], now: at(12))
        #expect(spans.count == 1)
        #expect(spans[0].end == nil && spans[0].ongoing)
        #expect(spans[0].interval(now: at(12)) == DateInterval(start: at(10), end: at(12)))
    }

    @Test func retentionDropsOutagesThatEndedBeforeTheCutoffButNeverOngoingOnes() {
        let retention = 56.0 * 24
        let spans = OutageTimeline.spans(
            from: [
                outage("ancient", start: -retention - 30, end: -retention - 28),
                outage("edge", start: -retention - 3, end: -retention + 1),
                outage("forever", start: -retention - 100, end: nil),
            ],
            now: at(0))
        #expect(spans.map(\.id) == ["forever", "edge"])
    }

    @Test func clippingKeepsTheOverlapAndDropsTheRest() {
        let span = OutageSpan(
            id: "x", title: "x", severity: "minor", start: at(1), end: at(5), ongoing: false)
        let domain = DateInterval(start: at(3), end: at(10))
        #expect(span.clipped(to: domain, now: at(20)) == DateInterval(start: at(3), end: at(5)))
        #expect(span.clipped(to: DateInterval(start: at(6), end: at(8)), now: at(20)) == nil)
        let live = OutageSpan(
            id: "y", title: "y", severity: "major", start: at(4), end: nil, ongoing: true)
        #expect(live.clipped(to: domain, now: at(7)) == DateInterval(start: at(4), end: at(7)))
    }

    // MARK: Ledger retention

    @Test func theLedgerKeepsDismissedOutagesForTheRetentionAndDismissedResetsForAMonth() {
        var ledger = NoticeLedger()
        let day = 24.0
        ledger.record(reset(-40 * day, dismissed: -39 * day), now: at(-39 * day))
        ledger.record(outage("kept", start: -50 * day, end: -50 * day + 2, dismissed: -49 * day), now: at(-49 * day))
        ledger.record(outage("gone", start: -60 * day, end: -60 * day + 2, dismissed: -59 * day), now: at(-59 * day))
        // Any record prunes.
        ledger.record(reset(0), now: at(0))
        #expect(ledger.notices.map(\.id).sorted() == [
            Notice.outageID(incidentID: "kept"), Notice.resetID(at: at(0)),
        ].sorted())
    }

    // MARK: Backfill split

    private func incident(_ id: String, start: Double, resolved: Double) -> StatusIncident {
        StatusIncident(
            id: id, name: "Elevated errors", impact: "major", phase: "resolved",
            startedAt: at(start), lastUpdateAt: at(resolved), lastMessage: "Resolved.",
            url: "https://stspg.io/\(id)", componentNames: ["Claude Code"], resolvedAt: at(resolved))
    }

    @Test func backfillRecordsOlderIncidentsAsDismissedFactsAndRecentOnesAsNews() {
        var ledger = NoticeLedger()
        let changed = NoticeDetector.backfill(
            history: [
                incident("news", start: -10, resolved: -8),
                incident("fact", start: -300, resolved: -298),
                incident("beyond", start: -2000, resolved: -1998),
            ],
            since: at(-48), factsSince: at(-1000), now: at(0), into: &ledger)
        #expect(changed)
        #expect(ledger.notices.map(\.id).sorted() == [
            Notice.outageID(incidentID: "fact"), Notice.outageID(incidentID: "news"),
        ].sorted())
        #expect(ledger.pending.map(\.id) == [Notice.outageID(incidentID: "news")])
        let fact = ledger.notice(id: Notice.outageID(incidentID: "fact"))
        #expect(fact?.dismissedAt == at(0) && fact?.seenAt == at(0))
        // Both still draw.
        #expect(OutageTimeline.spans(from: ledger.notices, now: at(0)).map(\.id) == ["fact", "news"])
    }

    // MARK: Audit model

    @Test func theAuditModelKeepsOnlyOutagesOverlappingTheSpan() {
        let domain = DateInterval(start: at(0), end: at(24))
        let model = AuditWindow.build(
            domain: domain, meterLabel: "Session (5h)", window: 5 * 3600,
            samples: [], sessions: [], outcomes: [],
            outages: [
                OutageSpan(id: "before", title: "a", severity: "minor", start: at(-5), end: at(-2), ongoing: false),
                OutageSpan(id: "edge", title: "b", severity: "major", start: at(-1), end: at(2), ongoing: false),
                OutageSpan(id: "live", title: "c", severity: "critical", start: at(20), end: nil, ongoing: true),
            ],
            now: at(22))
        #expect(model.outages.map(\.id) == ["edge", "live"])
    }
}
