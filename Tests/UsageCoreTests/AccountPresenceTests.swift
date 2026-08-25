import Foundation
import Testing

@testable import UsageCore

/// The presence core: the identity source's tolerant read, the ledger's
/// epoch algebra, and the pure attribution rule every surface trusts.
@Suite("AccountPresence")
struct AccountPresenceTests {
    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func identity(_ tag: String, org: String? = nil) -> AccountIdentity {
        AccountIdentity(
            accountUuid: "acct-\(tag)", organizationUuid: org ?? "org-\(tag)",
            email: "\(tag)@example.com", displayName: "Person \(tag.capitalized)",
            organizationName: "\(tag.capitalized)'s Organization",
            tier: "default_claude_max_20x")
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "presence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Identity source

    @Test("a full oauthAccount maps; broken records degrade to nil, never throw")
    func identitySourceReads() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "claude.json")

        let full = """
        {"oauthAccount": {"accountUuid": "2c1f", "organizationUuid": "c30b",
         "emailAddress": "someone@example.com", "fullName": "Some One",
         "organizationName": "Some Org", "organizationRateLimitTier": "default_claude_max_20x"},
         "unrelatedCache": {"x": 1}}
        """
        try Data(full.utf8).write(to: file)
        let read = ClaudeAccountIdentitySource(fileURL: file).currentIdentity()
        #expect(read == AccountIdentity(
            accountUuid: "2c1f", organizationUuid: "c30b",
            email: "someone@example.com", displayName: "Some One",
            organizationName: "Some Org", tier: "default_claude_max_20x"))

        // Signed out / key missing / malformed / uuid missing / file gone:
        // each is an observation of nothing.
        try Data(#"{"projects": {}}"#.utf8).write(to: file)
        #expect(ClaudeAccountIdentitySource(fileURL: file).currentIdentity() == nil)
        try Data("not json".utf8).write(to: file)
        #expect(ClaudeAccountIdentitySource(fileURL: file).currentIdentity() == nil)
        try Data(#"{"oauthAccount": {"emailAddress": "x@y.z"}}"#.utf8).write(to: file)
        #expect(ClaudeAccountIdentitySource(fileURL: file).currentIdentity() == nil)
        let missing = dir.appending(path: "nope.json")
        #expect(ClaudeAccountIdentitySource(fileURL: missing).currentIdentity() == nil)
    }

    // MARK: - Ledger

    @Test("observations coalesce into epochs; only changes report as such")
    func ledgerEpochAlgebra() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var ledger = AccountPresenceLedger(directory: dir)
        let a = identity("primary"), b = identity("work")
        let t0 = date("2026-08-25T08:00:00Z")

        // First sighting opens an epoch — a change.
        let opened = ledger.observe(a, at: t0)
        #expect(opened)
        #expect(ledger.epochs.count == 1)

        // Inside the floor: dropped entirely, the edge doesn't move.
        let floored = ledger.observe(a, at: t0.addingTimeInterval(10))
        #expect(!floored)
        #expect(ledger.epochs[0].lastObservedAt == t0)

        // A heartbeat extends the open epoch, silently.
        let beat = ledger.observe(a, at: t0.addingTimeInterval(60))
        #expect(!beat)
        #expect(ledger.epochs.count == 1)
        #expect(ledger.epochs[0].lastObservedAt == t0.addingTimeInterval(60))

        // A switch closes A (observed ending) and opens B — a change.
        let switched = ledger.observe(b, at: t0.addingTimeInterval(120))
        #expect(switched)
        #expect(ledger.epochs.count == 2)
        #expect(ledger.epochs[0].closedAt == t0.addingTimeInterval(120))
        #expect(ledger.epochs[1].account.key == b.key)

        // A sign-out closes B; observing nothing twice reports once.
        let signedOut = ledger.observe(nil, at: t0.addingTimeInterval(180))
        #expect(signedOut)
        #expect(ledger.epochs[1].closedAt == t0.addingTimeInterval(180))
        let repeated = ledger.observe(nil, at: t0.addingTimeInterval(240))
        #expect(!repeated)

        // Re-login after an OBSERVED sign-out is a new epoch, never a rejoin.
        let relogin = ledger.observe(b, at: t0.addingTimeInterval(300))
        #expect(relogin)
        #expect(ledger.epochs.count == 3)
    }

    @Test("an unobserved stop rejoins; the ledger survives its own file")
    func ledgerPersistenceAndRejoin() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = identity("primary")
        let t0 = date("2026-08-25T08:00:00Z")

        var first = AccountPresenceLedger(directory: dir)
        first.observe(a, at: t0)
        first.observe(a, at: t0.addingTimeInterval(600))
        first.flush(now: t0.addingTimeInterval(600))

        // A new host loads the file; the same identity hours later extends
        // the epoch (the gap attributes to it either way), no new row.
        var second = AccountPresenceLedger(directory: dir)
        #expect(second.epochs.count == 1)
        #expect(second.epochs[0].lastObservedAt == t0.addingTimeInterval(600))
        let rejoined = second.observe(a, at: t0.addingTimeInterval(7200))
        #expect(!rejoined)
        #expect(second.epochs.count == 1)
        #expect(second.epochs[0].lastObservedAt == t0.addingTimeInterval(7200))

        // A corrupt file starts empty rather than failing.
        try Data("garbage".utf8).write(to: second.fileURL)
        let third = AccountPresenceLedger(directory: dir)
        #expect(third.epochs.isEmpty)
    }

    // MARK: - Attribution rule

    private var craftedTimeline: AccountTimeline {
        AccountTimeline(epochs: [
            AccountEpoch(
                account: identity("primary"),
                firstObservedAt: date("2026-08-25T08:00:00Z"),
                lastObservedAt: date("2026-08-25T10:00:00Z")),
            AccountEpoch(
                account: identity("primary"),
                firstObservedAt: date("2026-08-25T11:00:00Z"),
                lastObservedAt: date("2026-08-25T12:00:00Z")),
            AccountEpoch(
                account: identity("work"),
                firstObservedAt: date("2026-08-25T13:00:00Z"),
                lastObservedAt: date("2026-08-25T14:00:00Z")),
        ])
    }

    @Test("the rule: epoch exact, agreeing gap owned, differing gap ambiguous, pre-history never guessed")
    func attributionRule() {
        let timeline = craftedTimeline
        let primary = identity("primary"), work = identity("work")

        #expect(timeline.attribute(date("2026-08-25T07:59:00Z")) == .unattributed)
        #expect(timeline.attribute(date("2026-08-25T09:00:00Z")) == .account(primary))
        // Gap with agreeing edges → owned by that account.
        #expect(timeline.attribute(date("2026-08-25T10:30:00Z")) == .account(primary))
        // Gap with differing edges → ambiguous, permanently.
        #expect(timeline.attribute(date("2026-08-25T12:30:00Z")) == .ambiguous)
        // The open final epoch owns the present…
        #expect(timeline.attribute(date("2026-08-25T15:00:00Z")) == .account(work))
        // …but an observed ending returns the ledger to knowing nothing.
        var closed = craftedTimeline.epochs
        closed[2].closedAt = date("2026-08-25T14:00:00Z")
        let ended = AccountTimeline(epochs: closed)
        #expect(ended.attribute(date("2026-08-25T15:00:00Z")) == .unattributed)
    }

    @Test("a session's stretches yield its chronological account list")
    func accountsInIntervals() {
        let timeline = craftedTimeline
        // A span crossing the switch names both, in order.
        let both = timeline.accounts(in: [
            DateInterval(
                start: date("2026-08-25T09:00:00Z"), end: date("2026-08-25T13:30:00Z"))
        ])
        #expect(both.map(\.email) == ["primary@example.com", "work@example.com"])
        // Disjoint stretches skip what happened between them.
        let stretched = timeline.accounts(in: [
            DateInterval(
                start: date("2026-08-25T09:00:00Z"), end: date("2026-08-25T09:30:00Z")),
            DateInterval(
                start: date("2026-08-25T13:10:00Z"), end: date("2026-08-25T13:20:00Z")),
        ])
        #expect(stretched.map(\.email) == ["primary@example.com", "work@example.com"])
        // Entirely pre-tracking names nobody.
        let before = timeline.accounts(in: [
            DateInterval(
                start: date("2026-08-25T06:00:00Z"), end: date("2026-08-25T07:00:00Z"))
        ])
        #expect(before.isEmpty)
    }

    @Test("labels stay plain until they collide, then carry the org")
    func labelDisambiguation() {
        let plain = LiveStateBuilder.disambiguatedLabels(
            [identity("primary"), identity("work")])
        #expect(plain == ["primary@example.com", "work@example.com"])
        // Same email in two orgs: both rows say which org they mean.
        let personal = identity("primary", org: "org-personal")
        let corporate = AccountIdentity(
            accountUuid: "acct-primary", organizationUuid: "org-corp",
            email: "primary@example.com", displayName: nil,
            organizationName: "Corp Inc", tier: nil)
        let collided = LiveStateBuilder.disambiguatedLabels([personal, corporate])
        #expect(collided == [
            "primary@example.com (Primary's Organization)",
            "primary@example.com (Corp Inc)",
        ])
    }
}
