import Foundation
import Testing
@testable import UsageCore

@Suite("Harness detection")
struct HarnessDetectionTests {
    @Test("the harness with the most recent session files wins")
    func busiestWins() throws {
        let fixture = try DetectionFixture()
        defer { fixture.tearDown() }
        let now = Date()
        try fixture.addSessions("claude", count: 3, age: 3600, now: now)
        try fixture.addSessions("codex", count: 1, age: 3600, now: now)

        let ranked = HarnessDetector.rank(candidates: fixture.candidates, now: now)

        #expect(ranked.map(\.id) == ["claude", "codex", "gemini"])
        #expect(HarnessDetector.activeID(in: ranked) == "claude")
        let gemini = try #require(ranked.first { $0.id == "gemini" })
        #expect(gemini.present == false)
    }

    @Test("old sessions don't count toward the score but do break ties")
    func staleSessionsTieBreak() throws {
        let fixture = try DetectionFixture()
        defer { fixture.tearDown() }
        let now = Date()
        fixture.makeDirectory("claude")
        // Outside the 14-day window: score 0, but newer than nothing.
        try fixture.addSessions("codex", count: 2, age: 30 * 86400, now: now)

        let ranked = HarnessDetector.rank(candidates: fixture.candidates, now: now)

        #expect(ranked.first?.id == "codex")
        let codex = try #require(ranked.first)
        #expect(codex.recentFiles == 0)
        #expect(codex.newestActivity != nil)
    }

    @Test("all-quiet resolves by candidate order")
    func quietFallsBackToOrder() throws {
        let fixture = try DetectionFixture()
        defer { fixture.tearDown() }
        fixture.makeDirectory("claude")
        fixture.makeDirectory("codex")

        let ranked = HarnessDetector.rank(candidates: fixture.candidates, now: Date())

        #expect(HarnessDetector.activeID(in: ranked) == "claude")
    }

    @Test("nothing present yields no active harness")
    func nothingPresent() throws {
        let fixture = try DetectionFixture()
        defer { fixture.tearDown() }
        let ranked = HarnessDetector.rank(candidates: fixture.candidates, now: Date())
        #expect(HarnessDetector.activeID(in: ranked) == nil)
        #expect(ranked.allSatisfy { !$0.present })
    }

    @Test("session files in nested date-sharded directories count")
    func nestedFilesCount() throws {
        let fixture = try DetectionFixture()
        defer { fixture.tearDown() }
        let now = Date()
        try fixture.addSessions("codex", count: 2, age: 3600, now: now, subpath: "2026/08/15")

        let ranked = HarnessDetector.rank(candidates: fixture.candidates, now: now)

        let codex = try #require(ranked.first { $0.id == "codex" })
        #expect(codex.recentFiles == 2)
    }
}

/// Temp session trees for three fake harnesses.
private struct DetectionFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "harness-detection-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var candidates: [(id: String, directories: [URL])] {
        ["claude", "codex", "gemini"].map { ($0, [root.appending(path: $0)]) }
    }

    func makeDirectory(_ id: String) {
        try? FileManager.default.createDirectory(
            at: root.appending(path: id), withIntermediateDirectories: true)
    }

    func addSessions(
        _ id: String, count: Int, age: TimeInterval, now: Date, subpath: String? = nil
    ) throws {
        var directory = root.appending(path: id)
        if let subpath { directory.append(path: subpath) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let modified = now.addingTimeInterval(-age)
        for index in 0..<count {
            let url = directory.appending(path: "session-\(index).jsonl")
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}
