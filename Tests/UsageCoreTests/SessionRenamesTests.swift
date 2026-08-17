import Foundation
import Testing
@testable import UsageCore

@Suite("Session renames store")
struct SessionRenamesTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "session-renames-tests-\(UUID().uuidString)")
    }

    @Test("missing file loads as empty")
    func missingFile() {
        #expect(SessionRenames(directory: tempDir()).load().isEmpty)
    }

    @Test("save/load round-trips, and a second save replaces whole")
    func roundTrip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionRenames(directory: dir)
        try store.save(["s1": "Meter fix", "s2": "CLI plan"])
        #expect(store.load() == ["s1": "Meter fix", "s2": "CLI plan"])
        try store.save(["s1": "Renamed again"])
        #expect(store.load() == ["s1": "Renamed again"])
    }

    @Test("an unparseable file degrades to empty instead of failing")
    func corruptFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appending(path: "session-renames.json"))
        #expect(SessionRenames(directory: dir).load().isEmpty)
    }

    @Test("renamed(_:) swaps the title and nothing else")
    func renamedCopy() {
        let base = SessionSummary(
            id: "s", title: "derived", projectPath: "/p", gitBranch: "main",
            agentVersion: "2.1", kind: .background,
            start: Date(timeIntervalSinceReferenceDate: 0),
            end: Date(timeIntervalSinceReferenceDate: 60),
            activeSeconds: 60, prompts: 2, apiCalls: 3, toolCalls: 4,
            subagentCount: 1, compactions: 1,
            models: ["m": TokenTally(input: 10, output: 5)],
            stretches: [DateInterval(
                start: Date(timeIntervalSinceReferenceDate: 0), duration: 60)])
        let renamed = base.renamed("custom")
        #expect(renamed.title == "custom")
        #expect(renamed.renamed("derived") == base)
    }
}
