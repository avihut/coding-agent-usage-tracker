import Foundation
import Testing
@testable import UsageCore

@Suite("Dormancy")
struct DormancyTests {
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    @Test("thirty days without a write is dormant")
    func window() {
        let recent = now.addingTimeInterval(-29 * 86400)
        let stale = now.addingTimeInterval(-31 * 86400)
        #expect(!Dormancy.isDormant(lastActivity: recent, addedAt: nil, now: now))
        #expect(Dormancy.isDormant(lastActivity: stale, addedAt: nil, now: now))
    }

    @Test("a fresh enrolment gets the window even with an old last write")
    func enrolmentGrace() {
        let stale = now.addingTimeInterval(-90 * 86400)
        #expect(!Dormancy.isDormant(lastActivity: stale, addedAt: now.addingTimeInterval(-3600), now: now))
        #expect(Dormancy.isDormant(lastActivity: stale, addedAt: now.addingTimeInterval(-40 * 86400), now: now))
    }

    @Test("no write yet: the enrolment stamp stands in; nothing known is not dormant")
    func nilActivity() {
        #expect(!Dormancy.isDormant(lastActivity: nil, addedAt: now.addingTimeInterval(-86400), now: now))
        #expect(Dormancy.isDormant(lastActivity: nil, addedAt: now.addingTimeInterval(-31 * 86400), now: now))
        #expect(!Dormancy.isDormant(lastActivity: nil, addedAt: nil, now: now))
    }
}

@Suite("Focus rule")
struct FocusRuleTests {
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    private func candidate(
        _ id: String, order: Int = 0, ago: TimeInterval? = nil, eligible: Bool = true, shown: Bool = true
    ) -> FocusCandidate {
        FocusCandidate(
            id: id, order: order, lastActivity: ago.map { now.addingTimeInterval(-$0) },
            eligible: eligible, shown: shown)
    }

    @Test("the newest write wins")
    func newestWrite() {
        let focused = FocusRule.focused(
            [candidate("default", ago: 3600), candidate("c982130e", ago: 60)], pin: nil)
        #expect(focused == "c982130e")
    }

    @Test("a pin beats recency while it is eligible")
    func pinWins() {
        let candidates = [candidate("default", ago: 3600), candidate("c982130e", ago: 60)]
        #expect(FocusRule.focused(candidates, pin: "default") == "default")
        #expect(FocusRule.focused(candidates, pin: "unknown") == "c982130e")
    }

    @Test("a pin on a dormant or disabled profile is ignored")
    func pinOnIneligible() {
        let candidates = [
            candidate("default", ago: 3600),
            candidate("c982130e", ago: 60, eligible: false),
        ]
        #expect(FocusRule.focused(candidates, pin: "c982130e") == "default")
    }

    @Test("shown profiles are preferred over hidden ones")
    func shownPreferred() {
        let candidates = [
            candidate("default", ago: 3600, shown: true),
            candidate("c982130e", ago: 60, shown: false),
        ]
        #expect(FocusRule.focused(candidates, pin: nil) == "default")
        // Unless nothing shown exists.
        #expect(FocusRule.focused([candidate("c982130e", ago: 60, shown: false)], pin: nil) == "c982130e")
    }

    @Test("nothing ever written: lowest order; no eligible profile: nil")
    func fallbacks() {
        #expect(FocusRule.focused([candidate("b", order: 2), candidate("a", order: 1)], pin: nil) == "a")
        #expect(FocusRule.focused([candidate("a", eligible: false)], pin: "a") == nil)
        #expect(FocusRule.focused([], pin: nil) == nil)
    }
}

@Suite("Last-activity probe")
struct LastActivityProbeTests {
    @Test("the mtime walk reports presence, recent count, and the newest write")
    func mtimeWalk() throws {
        let root = try TempTree()
        defer { root.tearDown() }
        let now = Date()
        try root.file("a/one.jsonl", age: 3600, now: now)
        try root.file("a/two.jsonl", age: 20 * 86400, now: now)
        try root.file("b/deep/three.jsonl", age: 600, now: now)

        let signal = MTimeProbe.signal(
            directories: [root.url("a"), root.url("b")], recentSince: now.addingTimeInterval(-14 * 86400))
        #expect(signal.present)
        #expect(signal.recentFiles == 2)
        #expect(abs(signal.newest!.timeIntervalSince(now.addingTimeInterval(-600))) < 2)

        let missing = MTimeProbe.signal(directories: [root.url("nope")], recentSince: now)
        #expect(!missing.present && missing.newest == nil)
    }

    @Test("maxDepth bounds the descent")
    func depth() throws {
        let root = try TempTree()
        defer { root.tearDown() }
        let now = Date()
        try root.file("p/shallow.jsonl", age: 7200, now: now)
        try root.file("p/x/y/deep.jsonl", age: 60, now: now)

        let shallow = MTimeProbe.signal(directories: [root.url("p")], recentSince: .distantPast, maxDepth: 1)
        #expect(abs(shallow.newest!.timeIntervalSince(now.addingTimeInterval(-7200))) < 2)
        let full = MTimeProbe.signal(directories: [root.url("p")], recentSince: .distantPast)
        #expect(abs(full.newest!.timeIntervalSince(now.addingTimeInterval(-60))) < 2)
    }

    @Test("the seam default walks the watch directories")
    func seamDefault() throws {
        let root = try TempTree()
        defer { root.tearDown() }
        let now = Date()
        try root.file("sessions/2026/09/06/rollout-1.jsonl", age: 300, now: now)
        let source = CodexActivitySource(root: root.url("sessions"), cacheDirectory: root.url("cache"))
        let last = try #require(source.lastActivity(now: now))
        #expect(abs(last.timeIntervalSince(now.addingTimeInterval(-300))) < 2)
        let empty = CodexActivitySource(root: root.url("none"), cacheDirectory: root.url("cache"))
        #expect(empty.lastActivity(now: now) == nil)
    }

    @Test("Claude's probe takes the newest of the prompt history and recent project files")
    func claudeProbe() throws {
        let homes = try TempHomes()
        defer { homes.tearDown() }
        let now = Date()
        let home = homes.home(".claude-personal")
        let tree = TempTree(root: home.directory)
        try tree.file("history.jsonl", age: 5000, now: now)
        try tree.file("projects/-Users-x-old/s1.jsonl", age: 40 * 86400, now: now)
        try tree.file("projects/-Users-x-new/s2.jsonl", age: 900, now: now)
        try tree.file("projects/-Users-x-new/s2/subagents/agent.jsonl", age: 400, now: now)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-900)],
            ofItemAtPath: tree.url("projects/-Users-x-new").path)

        let source = ClaudeActivitySource(home: home, cacheDirectory: homes.userHome.appending(path: "cache"))
        let last = try #require(source.lastActivity(now: now))
        #expect(abs(last.timeIntervalSince(now.addingTimeInterval(-400))) < 2)

        // History alone, when the projects tree is absent.
        let quiet = homes.home(".claude-quiet")
        let quietTree = TempTree(root: quiet.directory)
        try quietTree.file("history.jsonl", age: 100, now: now)
        let quietSource = ClaudeActivitySource(home: quiet, cacheDirectory: homes.userHome.appending(path: "cache2"))
        let quietLast = try #require(quietSource.lastActivity(now: now))
        #expect(abs(quietLast.timeIntervalSince(now.addingTimeInterval(-100))) < 2)

        // Nothing at all.
        let bare = homes.home(".claude-bare")
        #expect(ClaudeActivitySource(home: bare, cacheDirectory: homes.userHome).lastActivity(now: now) == nil)
    }

    @Test("ProfileActivity.probe reads the identity record and the last write")
    func probe() throws {
        let homes = try TempHomes()
        defer { homes.tearDown() }
        let now = Date()
        let home = homes.home(".claude-personal")
        let tree = TempTree(root: home.directory)
        try tree.file("history.jsonl", age: 30, now: now)
        try tree.write(".claude.json", """
        {"oauthAccount":{"accountUuid":"u1","organizationUuid":"o1","emailAddress":"p@example.com"}}
        """)
        let provider = ClaudeProvider(home: home)
        let probe = ProfileActivity.probe(provider: provider, cacheDirectory: homes.userHome, now: now)
        #expect(probe.identity?.email == "p@example.com")
        #expect(abs(probe.lastActivityAt!.timeIntervalSince(now.addingTimeInterval(-30))) < 2)
    }
}

/// Files with chosen mtimes under a temp root.
struct TempTree {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "temp-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    init(root: URL) {
        self.root = root
    }

    func url(_ path: String) -> URL { root.appending(path: path) }

    func file(_ path: String, age: TimeInterval, now: Date) throws {
        let target = url(path)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: target)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: target.path)
    }

    func write(_ path: String, _ contents: String) throws {
        let target = url(path)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: target)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}
