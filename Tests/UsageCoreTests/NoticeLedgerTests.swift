import Foundation
import Testing

@testable import UsageCore

@Suite("Notice ledger")
struct NoticeLedgerTests {
    private func at(_ hours: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: hours * 3600)
    }

    private func reset(_ hours: Double) -> Notice {
        Notice(
            id: Notice.resetID(at: at(hours)), kind: "reset", occurredAt: at(hours),
            endedAt: at(hours), recordedAt: at(hours + 0.1),
            meterLabel: "Weekly (all)", fromPercent: 71)
    }

    private func outage(_ id: String, start: Double, ongoing: Bool = true) -> Notice {
        Notice(
            id: Notice.outageID(incidentID: id), kind: "outage", occurredAt: at(start),
            endedAt: ongoing ? nil : at(start + 2), ongoing: ongoing, recordedAt: at(start),
            subject: "Elevated errors", impact: "major", phase: "identified")
    }

    @Test func pendingPutsOngoingFirstThenNewest() {
        var ledger = NoticeLedger()
        ledger.record(reset(10))
        ledger.record(outage("a", start: 5))
        ledger.record(reset(20))
        #expect(ledger.pending.map(\.id) == [
            Notice.outageID(incidentID: "a"), Notice.resetID(at: at(20)), Notice.resetID(at: at(10)),
        ])
    }

    @Test func recordingTheSameIDTwiceIsSilent() {
        var ledger = NoticeLedger()
        let changed1 = ledger.record(reset(10))
        #expect(changed1)
        let changed2 = ledger.record(reset(10))
        #expect(!changed2)
        #expect(ledger.notices.count == 1)
    }

    @Test func aNearbyResetIsTheSameEvent() {
        var ledger = NoticeLedger()
        ledger.record(reset(10))
        #expect(ledger.hasReset(near: at(10).addingTimeInterval(90)))
        #expect(!ledger.hasReset(near: at(10).addingTimeInterval(600)))
    }

    @Test func seenIsNotDismissed() {
        var ledger = NoticeLedger()
        ledger.record(reset(10))
        let id = Notice.resetID(at: at(10))
        let changed3 = ledger.markSeen(ids: [id], at: at(11))
        #expect(changed3)
        #expect(ledger.notice(id: id)?.seenAt == at(11))
        #expect(ledger.pending.count == 1)
        // Marking again changes nothing.
        let changed4 = ledger.markSeen(ids: [id], at: at(12))
        #expect(!changed4)
    }

    @Test func dismissRemovesFromPendingAndImpliesSeen() {
        var ledger = NoticeLedger()
        ledger.record(reset(10))
        let id = Notice.resetID(at: at(10))
        let changed5 = ledger.dismiss(id: id, at: at(11))
        #expect(changed5)
        #expect(ledger.pending.isEmpty)
        #expect(ledger.notice(id: id)?.seenAt == at(11))
        let changed6 = ledger.dismiss(id: id, at: at(12))
        #expect(!changed6)
    }

    @Test func anOngoingNoticeRefusesDismissal() {
        var ledger = NoticeLedger()
        ledger.record(outage("a", start: 5))
        let changed7 = ledger.dismiss(id: Notice.outageID(incidentID: "a"))
        #expect(!changed7)
        let changed8 = ledger.dismissAll()
        #expect(!changed8)
        #expect(ledger.pending.count == 1)
    }

    /// Closing an ongoing notice makes it its own epilogue: pending again,
    /// unseen again, and remembering whether it was watched.
    @Test func closingRemembersWhetherItWasSeen() {
        var ledger = NoticeLedger()
        ledger.record(outage("a", start: 5))
        ledger.record(outage("b", start: 6))
        ledger.markSeen(ids: [Notice.outageID(incidentID: "a")], at: at(6))

        let changed9 = ledger.close(id: Notice.outageID(incidentID: "a"), endedAt: at(7))
        #expect(changed9)
        let changed10 = ledger.close(id: Notice.outageID(incidentID: "b"), endedAt: at(7))
        #expect(changed10)
        let a = ledger.notice(id: Notice.outageID(incidentID: "a"))
        let b = ledger.notice(id: Notice.outageID(incidentID: "b"))
        #expect(a?.ongoing == false && a?.endedAt == at(7))
        #expect(a?.seenWhileOngoing == true && a?.seenAt == nil)
        #expect(b?.seenWhileOngoing == false)
        // Now dismissable.
        let changed11 = ledger.dismissAll(at: at(8))
        #expect(changed11)
        #expect(ledger.pending.isEmpty)
    }

    @Test func dismissedNoticesAgeOut() {
        var ledger = NoticeLedger()
        ledger.record(reset(10))
        ledger.dismiss(id: Notice.resetID(at: at(10)), at: at(11))
        // A later record prunes at its own `now`.
        ledger.record(reset(11 + 31 * 24), now: at(11 + 31 * 24))
        #expect(ledger.notices.count == 1)
        #expect(ledger.notices.first?.id == Notice.resetID(at: at(11 + 31 * 24)))
    }

    @Test func persistsAndReloads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "notice-ledger-\(UUID().uuidString)")
        var ledger = NoticeLedger(directory: directory)
        ledger.record(reset(10))
        ledger.record(outage("a", start: 5))
        ledger.markSeen(ids: [Notice.resetID(at: at(10))], at: at(11))

        let reloaded = NoticeLedger(directory: directory)
        #expect(reloaded.notices == ledger.notices)
        #expect(reloaded.notice(id: Notice.resetID(at: at(10)))?.seenAt == at(11))
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func anUnknownKindStillDecodes() throws {
        let json = """
        {"version":1,"notices":[{"id":"quota|x","kind":"quota","occurredAt":"2026-09-04T21:10:00Z",
        "ongoing":false,"seenWhileOngoing":false,"recordedAt":"2026-09-04T21:12:00Z","components":[]}]}
        """
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "notice-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try json.data(using: .utf8)!.write(to: directory.appending(path: "notices.json"))
        let ledger = NoticeLedger(directory: directory)
        #expect(ledger.notices.count == 1)
        #expect(ledger.notices.first?.kindValue == nil)
        #expect(ledger.pending.count == 1)
        try? FileManager.default.removeItem(at: directory)
    }
}
