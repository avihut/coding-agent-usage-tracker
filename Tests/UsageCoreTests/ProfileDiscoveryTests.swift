import Foundation
import Testing
@testable import UsageCore

@Suite("Profile discovery")
struct ProfileDiscoveryTests {
    private let identityJSON = """
    {"oauthAccount":{"accountUuid":"u1","organizationUuid":"o1","emailAddress":"p@example.com"}}
    """

    /// A standard home plus a used, signed-in personal one.
    private func machine() throws -> (TempHomes, ClaudeProvider, Date) {
        let homes = try TempHomes()
        let now = Date()
        try homes.make(".claude", with: ["projects/"])
        let personal = TempTree(root: homes.userHome.appending(path: ".claude-personal"))
        try personal.file("history.jsonl", age: 600, now: now)
        try personal.write(".claude.json", identityJSON)
        return (homes, ClaudeProvider(home: homes.home(".claude")), now)
    }

    private func discover(
        _ provider: ClaudeProvider, known: [Profile], homes: TempHomes, now: Date
    ) -> [DiscoveredHome] {
        ProfileDiscovery.discover(
            provider: provider, known: known, bundleID: "com.test",
            roots: StorageScope.Roots(
                support: homes.userHome.appending(path: "support"),
                caches: homes.userHome.appending(path: "caches")),
            now: now, userHome: homes.userHome)
    }

    @Test("a used, signed-in sibling is discovered with its identity and last write")
    func discoversSibling() throws {
        let (homes, provider, now) = try machine()
        defer { homes.tearDown() }
        let found = discover(provider, known: [], homes: homes, now: now)
        #expect(found.count == 1)
        let home = try #require(found.first)
        #expect(home.displayPath == "~/.claude-personal")
        #expect(home.profileID == ProfileID.derive(homePath: homes.userHome.appending(path: ".claude-personal").path))
        #expect(home.identity?.email == "p@example.com")
        #expect(abs(home.lastActivityAt!.timeIntervalSince(now.addingTimeInterval(-600))) < 2)
        // Nothing was written under the would-be profile directory.
        #expect(!FileManager.default.fileExists(atPath: homes.userHome.appending(path: "support").path))
    }

    @Test("an enrolled home is not offered again")
    func enrolledSkipped() throws {
        let (homes, provider, now) = try machine()
        defer { homes.tearDown() }
        let id = ProfileID.derive(homePath: homes.userHome.appending(path: ".claude-personal").path)
        let enrolled = Profile(
            id: id, providerID: "claude", home: homes.userHome.appending(path: ".claude-personal"),
            addedAt: now)
        #expect(discover(provider, known: [enrolled], homes: homes, now: now).isEmpty)
    }

    @Test("a dismissed home stays silent until its sign-in changes")
    func dismissedUntilIdentityChanges() throws {
        let (homes, provider, now) = try machine()
        defer { homes.tearDown() }
        let id = ProfileID.derive(homePath: homes.userHome.appending(path: ".claude-personal").path)
        var dismissed = Profile(
            id: id, providerID: "claude", home: homes.userHome.appending(path: ".claude-personal"),
            enabled: false, addedAt: now, ignoredIdentityKey: "u1|o1")
        #expect(discover(provider, known: [dismissed], homes: homes, now: now).isEmpty)

        dismissed.ignoredIdentityKey = "someone-else|o9"
        let found = discover(provider, known: [dismissed], homes: homes, now: now)
        #expect(found.map(\.profileID) == [id])
    }

    @Test("a dormant home is never offered; an unused one only with a sign-in")
    func dormantAndUnused() throws {
        let homes = try TempHomes()
        defer { homes.tearDown() }
        let now = Date()
        try homes.make(".claude", with: ["projects/"])
        let dormant = TempTree(root: homes.userHome.appending(path: ".claude-dormant"))
        try dormant.file("history.jsonl", age: 45 * 86400, now: now)
        try dormant.write(".claude.json", identityJSON)
        let unusedSignedIn = TempTree(root: homes.userHome.appending(path: ".claude-fresh"))
        try unusedSignedIn.write(".claude.json", identityJSON)
        try homes.make(".claude-unused", with: ["projects/"])

        let provider = ClaudeProvider(home: homes.home(".claude"))
        let found = discover(provider, known: [], homes: homes, now: now)
        #expect(found.map(\.displayPath) == ["~/.claude-fresh"])
    }

    @Test("providers without homes discover nothing")
    func singleHomeProvider() {
        let found = ProfileDiscovery.discover(
            provider: CodexProvider(), known: [], bundleID: "com.test", now: Date())
        #expect(found.isEmpty)
    }

    @Test("offers are born ended, dismissable, keyed by the profile id, phrased with path and email")
    func offers() {
        let now = Date()
        let home = DiscoveredHome(
            home: URL(filePath: "/Users/x/.claude-personal"), profileID: "c982130e",
            displayPath: "~/.claude-personal",
            identity: AccountIdentity(accountUuid: "u", organizationUuid: "o", email: "p@example.com"),
            lastActivityAt: now)
        let notices = ProfileDiscovery.offers([home], providerID: "claude", now: now)
        let notice = try! #require(notices.first)
        #expect(notice.id == "profile|c982130e")
        #expect(notice.kindValue == .profileFound)
        #expect(notice.isDismissable && !notice.ongoing)
        #expect(notice.endedAt == now && notice.occurredAt == now)
        #expect(notice.subject == "~/.claude-personal")
        #expect(notice.message == "p@example.com")

        // A ledger records it once; the same offer again is a no-op.
        var ledger = NoticeLedger()
        let first = ledger.record(notice, now: now)
        let second = ledger.record(notice, now: now)
        #expect(first && !second)
        #expect(ledger.pending.map(\.id) == ["profile|c982130e"])
    }
}
