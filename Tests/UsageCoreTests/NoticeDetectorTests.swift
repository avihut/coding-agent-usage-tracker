import Foundation
import Testing

@testable import UsageCore

@Suite("Notice detector")
struct NoticeDetectorTests {
    private func at(_ hours: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: hours * 3600)
    }

    private func sample(_ t: Double, _ percents: [String: Int], reset: Double? = 100) -> UsageSample {
        UsageSample(
            t: at(t), percents: percents,
            resets: reset.map { stamp in percents.mapValues { _ in at(stamp) } })
    }

    // MARK: Resets

    /// The 2026-09-04 shape: two weekly meters zero under an unmoved stamp
    /// (the zeroed poll stampless, healed by ResetCarry), the session meter
    /// already at zero. ONE notice, voiced by the meter that stood highest.
    @Test func oneGrantAcrossMetersVoicedByTheHighest() {
        let samples = [
            sample(1, ["S": 0, "W": 71, "O": 40]),
            sample(2, ["S": 0, "W": 0, "O": 0], reset: nil),
            sample(3, ["S": 2, "W": 1, "O": 1]),
        ]
        let notices = NoticeDetector.grants(samples: samples, since: nil, now: at(4))
        #expect(notices.count == 1)
        #expect(notices.first?.kindValue == .reset)
        #expect(notices.first?.occurredAt == at(1.5))
        #expect(notices.first?.meterLabel == "W")
        #expect(notices.first?.fromPercent == 71)
        #expect(notices.first?.id == Notice.resetID(at: at(1.5)))
        #expect(notices.first?.isDismissable == true)
    }

    @Test func aWindowEndIsNotAGrant() {
        let samples = [
            UsageSample(t: at(1), percents: ["W": 71], resets: ["W": at(2)]),
            UsageSample(t: at(3), percents: ["W": 0], resets: ["W": at(170)]),
        ]
        #expect(NoticeDetector.grants(samples: samples, since: nil, now: at(4)).isEmpty)
    }

    @Test func sinceBoundsTheSearch() {
        let samples = [
            sample(1, ["W": 71]), sample(2, ["W": 0]), sample(50, ["W": 30]), sample(51, ["W": 0]),
        ]
        let recent = NoticeDetector.grants(samples: samples, since: at(40), now: at(52))
        #expect(recent.map(\.occurredAt) == [at(50.5)])
        let all = NoticeDetector.grants(samples: samples, since: nil, now: at(52))
        #expect(all.map(\.occurredAt) == [at(1.5), at(50.5)])
    }

    @Test func noteGrantsSkipsWhatTheLedgerKnows() {
        var ledger = NoticeLedger()
        let samples = [sample(1, ["W": 71]), sample(2, ["W": 0])]
        let changed1 = NoticeDetector.noteGrants(samples: samples, since: nil, now: at(3), into: &ledger)
        #expect(changed1)
        let changed2 = NoticeDetector.noteGrants(samples: samples, since: nil, now: at(3), into: &ledger)
        #expect(!changed2)
        // The same event read a minute later off a sibling's samples.
        let sibling = [sample(1, ["O": 40]), sample(2.03, ["O": 0])]
        let changed3 = NoticeDetector.noteGrants(samples: sibling, since: nil, now: at(3), into: &ledger)
        #expect(!changed3)
        #expect(ledger.notices.count == 1)
    }

    // MARK: Outages

    private func incident(
        _ id: String, phase: String = "investigating", start: Double = 1,
        resolved: Double? = nil, message: String? = "Looking into it."
    ) -> StatusIncident {
        StatusIncident(
            id: id, name: "Elevated errors", impact: "major", phase: phase,
            startedAt: at(start), lastUpdateAt: at(start), lastMessage: message,
            url: "https://stspg.io/x", componentNames: ["Claude Code"],
            resolvedAt: resolved.map(at))
    }

    private func card(
        open: [StatusIncident] = [], resolved: [StatusIncident] = [], indicator: String = "none"
    ) -> ServiceStatusCard {
        ServiceStatusCard(
            providerID: "claude", pageName: "Claude", pageURL: "https://status.claude.com",
            indicator: open.isEmpty ? indicator : "major", descriptionText: "",
            checkedAt: at(2), okAt: at(2), stale: false, components: [],
            incidents: open, recentlyResolved: resolved)
    }

    @Test func anOpenIncidentBecomesAnOngoingNotice() {
        var ledger = NoticeLedger()
        let changed4 = NoticeDetector.apply(card: card(open: [incident("a")]), now: at(2), into: &ledger)
        #expect(changed4)
        let notice = ledger.notice(id: Notice.outageID(incidentID: "a"))
        #expect(notice?.ongoing == true)
        #expect(notice?.isDismissable == false)
        #expect(notice?.subject == "Elevated errors")
        #expect(notice?.impact == "major")
        #expect(notice?.occurredAt == at(1))
        // The same card again: nothing new.
        let changed5 = NoticeDetector.apply(card: card(open: [incident("a")]), now: at(2.1), into: &ledger)
        #expect(!changed5)
    }

    @Test func anUpdateRefreshesPhaseAndMessage() {
        var ledger = NoticeLedger()
        NoticeDetector.apply(card: card(open: [incident("a")]), now: at(2), into: &ledger)
        let changed = NoticeDetector.apply(
            card: card(open: [incident("a", phase: "monitoring", message: "Fix is out.")]),
            now: at(3), into: &ledger)
        #expect(changed)
        let notice = ledger.notice(id: Notice.outageID(incidentID: "a"))
        #expect(notice?.phase == "monitoring")
        #expect(notice?.message == "Fix is out.")
        #expect(notice?.ongoing == true)
    }

    /// Resolution closes the ongoing notice at the page's own resolved time,
    /// and the epilogue knows whether it was watched.
    @Test func leavingTheOpenListClosesTheNotice() {
        var ledger = NoticeLedger()
        NoticeDetector.apply(card: card(open: [incident("a")]), now: at(2), into: &ledger)
        ledger.markSeen(ids: [Notice.outageID(incidentID: "a")], at: at(2.5))
        let changed = NoticeDetector.apply(
            card: card(resolved: [incident("a", phase: "resolved", resolved: 3)]),
            now: at(3.2), into: &ledger)
        #expect(changed)
        let notice = ledger.notice(id: Notice.outageID(incidentID: "a"))
        #expect(notice?.ongoing == false)
        #expect(notice?.endedAt == at(3))
        #expect(notice?.seenWhileOngoing == true)
        #expect(notice?.seenAt == nil)
        #expect(notice?.isDismissable == true)
    }

    /// An incident that came and went between two polls — only in the
    /// page's hour-long resolved memory — is recorded already closed.
    @Test func aRecentlyResolvedIncidentNeverSeenOpenIsRecordedClosed() {
        var ledger = NoticeLedger()
        let changed = NoticeDetector.apply(
            card: card(resolved: [incident("b", phase: "resolved", start: 1, resolved: 1.5)]),
            now: at(2), into: &ledger)
        #expect(changed)
        let notice = ledger.notice(id: Notice.outageID(incidentID: "b"))
        #expect(notice?.ongoing == false)
        #expect(notice?.endedAt == at(1.5))
        #expect(notice?.seenWhileOngoing == false)
    }

    /// Losing the feed is not the incident ending.
    @Test func anUnknownCardClosesNothing() {
        var ledger = NoticeLedger()
        NoticeDetector.apply(card: card(open: [incident("a")]), now: at(2), into: &ledger)
        let unknown = ServiceStatusCard(
            providerID: "claude", pageName: "claude", pageURL: "", indicator: "unknown",
            descriptionText: "", checkedAt: at(3), okAt: nil, stale: true,
            components: [], incidents: [])
        let changed6 = NoticeDetector.apply(card: unknown, now: at(3), into: &ledger)
        #expect(!changed6)
        #expect(ledger.notice(id: Notice.outageID(incidentID: "a"))?.ongoing == true)
    }

    // MARK: Wake-time backfill

    @Test func backfillRecordsIncidentsResolvedSinceTheCutoffOnly() {
        var ledger = NoticeLedger()
        let history = [
            incident("old", phase: "resolved", start: -30, resolved: -28),
            incident("night", phase: "resolved", start: 1, resolved: 3),
            incident("open", phase: "investigating", start: 4),
        ]
        let changed = NoticeDetector.backfill(
            history: history, since: at(0), now: at(8), into: &ledger)
        #expect(changed)
        #expect(ledger.notices.map(\.id) == [Notice.outageID(incidentID: "night")])
        let notice = ledger.notices.first
        #expect(notice?.ongoing == false)
        #expect(notice?.endedAt == at(3))
        #expect(notice?.seenWhileOngoing == false)
        // Re-reading the same history is silent.
        let changed7 = NoticeDetector.backfill(history: history, since: at(0), now: at(9), into: &ledger)
        #expect(!changed7)
    }

    @Test func backfillNeverTouchesAnIncidentTheLedgerAlreadyHolds() {
        var ledger = NoticeLedger()
        NoticeDetector.apply(card: card(open: [incident("a")]), now: at(2), into: &ledger)
        ledger.markSeen(ids: [Notice.outageID(incidentID: "a")], at: at(2.5))
        let changed = NoticeDetector.backfill(
            history: [incident("a", phase: "resolved", resolved: 3)],
            since: at(0), now: at(8), into: &ledger)
        #expect(!changed)
        // Still the summary poll's business to close it.
        #expect(ledger.notice(id: Notice.outageID(incidentID: "a"))?.ongoing == true)
    }
}
