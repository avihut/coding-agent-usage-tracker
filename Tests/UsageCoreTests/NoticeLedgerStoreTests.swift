import Foundation
import Testing
@testable import UsageCore

@Suite("Notice ledger store")
@MainActor
struct NoticeLedgerStoreTests {
    private func at(_ hours: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: hours * 3600)
    }

    private func reset(_ hours: Double, profileID: String = "default") -> Notice {
        Notice(
            id: Notice.resetID(profileID: profileID, at: at(hours)), kind: "reset",
            occurredAt: at(hours), endedAt: at(hours), recordedAt: at(hours + 0.1),
            meterLabel: "Weekly (all)", fromPercent: 71, profileID: profileID)
    }

    @Test("mutate reports the body's change and signals it once")
    func mutateSignals() {
        let store = NoticeLedgerStore(ledger: NoticeLedger())
        let changes = Box(0)
        store.onChange = { changes.value += 1 }

        let first = store.mutate { $0.record(self.reset(10)) }
        let repeat_ = store.mutate { $0.record(self.reset(10)) }
        let dismissed = store.mutate { $0.dismiss(id: self.reset(10).id, at: self.at(11)) }
        let refused = store.mutate { $0.dismiss(id: "nope", at: self.at(11)) }

        #expect(first && !repeat_ && dismissed && !refused)
        #expect(changes.value == 2)
        #expect(store.notices.count == 1)
        #expect(store.pending.isEmpty)
    }

    @Test("two profiles' resets in one minute both land, and the file follows")
    func twoProfilesPersist() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "notice-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoticeLedgerStore(directory: directory)
        store.mutate { $0.record(self.reset(10)) }
        store.mutate { $0.record(self.reset(10, profileID: "c982130e")) }
        #expect(store.ledger.hasReset(profileID: "default", near: at(10)))
        #expect(store.ledger.hasReset(profileID: "c982130e", near: at(10)))

        let reloaded = NoticeLedger(directory: directory)
        #expect(reloaded.notices.map(\.profileIDOrDefault).sorted() == ["c982130e", "default"])
    }

    @Test("the card carries the profile a reset belongs to")
    func cardProfile() {
        let card = NoticePhrasing.card(reset(10, profileID: "c982130e"), serviceName: "Claude", now: at(12))
        #expect(card.profile == "c982130e")
        let legacy = Notice(
            id: Notice.resetID(at: at(10)), kind: "reset", occurredAt: at(10), endedAt: at(10),
            recordedAt: at(10))
        #expect(NoticePhrasing.card(legacy, serviceName: "Claude", now: at(12)).profile == nil)
    }
}
