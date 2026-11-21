import Foundation
import Testing

@testable import UsageCore

/// A SYNTHETIC Antigravity CLI home — the layout the CLI writes
/// (`conversations/<id>.db`, `brain/<id>/.system_generated/logs/
/// transcript.jsonl`), with rows built here. Never a real conversation.
struct AntigravityFixture {
    let root: URL
    var home: URL { root.appending(path: "antigravity-cli") }
    var cache: URL { root.appending(path: "cache") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "antigravity-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appending(path: "antigravity-cli/conversations"),
            withIntermediateDirectories: true)
    }

    func tearDown() { try? FileManager.default.removeItem(at: root) }

    static func newID() -> String { UUID().uuidString.lowercased() }

    /// A conversation file (never opened by the code under test, so any
    /// bytes do) aged `age` seconds, and — unless `rows` is nil — its
    /// transcript.
    @discardableResult
    func conversation(
        _ id: String = AntigravityFixture.newID(), rows: [String]?, age: TimeInterval = 60,
        now: Date = Date()
    ) throws -> String {
        let db = home.appending(path: "conversations/\(id).db")
        try Data("SQLite format 3\u{0}".utf8).write(to: db)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: db.path)
        if let rows { try transcript(id, rows: rows) }
        return id
    }

    func transcriptURL(_ id: String) -> URL {
        home.appending(path: "brain/\(id)/.system_generated/logs/transcript.jsonl")
    }

    func transcript(_ id: String, rows: [String], trailing: String = "\n") throws {
        let url = transcriptURL(id)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((rows.joined(separator: "\n") + trailing).utf8).write(to: url)
    }

    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// A model call, with the body fields the real rows carry so the tests
    /// prove they are ignored.
    static func call(
        at date: Date, model: String = "gemini-4-neon-xhigh", input: Int, cacheRead: Int = 0,
        output: Int, step: Int = 1
    ) -> String {
        """
        {"step_index":\(step),"created_at":"\(stamp(date))","source":"MODEL","type":"PLANNER_RESPONSE",\
        "status":"DONE","model":"\(model)","input_tokens":\(input),"cache_read_tokens":\(cacheRead),\
        "output_tokens":\(output),"thinking":"SECRET-THINKING",\
        "tool_calls":[{"name":"run_command","args":{"CommandLine":"SECRET-COMMAND"}}]}
        """
    }

    static func prompt(at date: Date, source: String = "USER_EXPLICIT", step: Int = 0) -> String {
        """
        {"step_index":\(step),"created_at":"\(stamp(date))","source":"\(source)","type":"USER_INPUT",\
        "status":"DONE","content":"SECRET-PROMPT"}
        """
    }

    static func tool(at date: Date, step: Int = 2) -> String {
        """
        {"step_index":\(step),"created_at":"\(stamp(date))","source":"MODEL","type":"GENERIC",\
        "status":"DONE","content":"SECRET-OUTPUT","truncated_fields":["content"]}
        """
    }

    func source(calendar: Calendar = .current) -> AntigravityActivitySource {
        AntigravityActivitySource(home: home, cacheDirectory: cache, calendar: calendar)
    }

    func provider() -> AntigravityProvider {
        AntigravityProvider(home: home, userHome: root, agyCandidates: [])
    }

    /// Every file under the home with its mtime — what "nothing was written
    /// there" is checked against.
    func homeSnapshot() -> [String: Date] {
        var files: [String: Date] = [:]
        let enumerator = FileManager.default.enumerator(
            at: home, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = enumerator?.nextObject() as? URL {
            files[url.path] = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        return files
    }
}

@Suite("Antigravity activity")
struct AntigravityActivitySourceTests {
    private let now = Date()

    @Test("calls become tokens per model and minute; only typed prompts count")
    func tokenMapping() throws {
        let fixture = try AntigravityFixture()
        defer { fixture.tearDown() }
        // On a minute boundary, so the two calls share one timeline slot.
        let t0 = Date(timeIntervalSince1970: ((now.timeIntervalSince1970 - 3600) / 60)
            .rounded(.down) * 60)
        try fixture.conversation(rows: [
            AntigravityFixture.prompt(at: t0),
            AntigravityFixture.call(at: t0, input: 17222, output: 1053),
            AntigravityFixture.tool(at: t0.addingTimeInterval(5)),
            AntigravityFixture.call(
                at: t0.addingTimeInterval(20), input: 290, cacheRead: 17223, output: 728, step: 3),
            AntigravityFixture.prompt(at: t0.addingTimeInterval(30), source: "SYSTEM", step: 4),
        ])
        let scan = fixture.source().scanTranscriptsReadOnly(now: now)
        let day = try #require(scan.daily.first)
        #expect(scan.daily.count == 1)
        #expect(day.messages == 2)
        #expect(day.prompts == 1)
        #expect(day.tokens == 17222 + 1053 + 290 + 17223 + 728)
        let tally = try #require(day.models["gemini-4-neon"])
        #expect(tally.input == 17222 + 290)
        #expect(tally.cacheRead == 17223)
        #expect(tally.output == 1053 + 728)
        #expect(tally.cacheCreation == 0)
        #expect(day.models.count == 1)
        #expect(scan.timeline.count == 1)
        #expect(scan.timeline.first?.model == "gemini-4-neon")
    }

    @Test("the effort suffix is stripped from an allowlist, never guessed")
    func effortAllowlist() {
        #expect(AntigravityModels.baseID("gemini-4-neon-xhigh") == "gemini-4-neon")
        #expect(AntigravityModels.baseID("gemini-4-argon-low") == "gemini-4-argon")
        // "max" is a model-name word (`gpt-5.1-codex-max`), not an effort.
        #expect(AntigravityModels.baseID("gemini-4-neon-max") == "gemini-4-neon-max")
        #expect(AntigravityModels.baseID("gpt-5.1-codex-max") == "gpt-5.1-codex-max")
        #expect(AntigravityModels.baseID("gemini-4-argon-trial") == "gemini-4-argon-trial")
        #expect(AntigravityModels.baseID("gemini-3.1-flash-lite") == "gemini-3.1-flash-lite")
        #expect(AntigravityModels.baseID("gemini-3-flash-preview") == "gemini-3-flash-preview")
        #expect(AntigravityModels.baseID("gemini-4-neon-turbo") == "gemini-4-neon-turbo")
        #expect(AntigravityModels.baseID("high") == "high")
    }

    @Test("a call lands on the local day it happened, wherever that is")
    func localDays() throws {
        let fixture = try AntigravityFixture()
        defer { fixture.tearDown() }
        let stamp = try #require(ISO8601DateFormatter().date(from: "2026-11-21T06:30:00Z"))
        try fixture.conversation(rows: [AntigravityFixture.call(at: stamp, input: 10, output: 5)])
        func day(in zone: String) throws -> DateComponents {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: zone))
            let scan = fixture.source(calendar: calendar).scanTranscriptsReadOnly(now: now)
            return calendar.dateComponents([.month, .day], from: try #require(scan.daily.first).day)
        }
        #expect(try day(in: "America/Los_Angeles").day == 20)
        #expect(try day(in: "Asia/Tokyo").day == 21)
    }

    @Test("a half-written last line is skipped until the file grows")
    func partialLastLine() throws {
        let fixture = try AntigravityFixture()
        defer { fixture.tearDown() }
        let t0 = now.addingTimeInterval(-600)
        let id = try fixture.conversation(rows: nil)
        let first = AntigravityFixture.call(at: t0, input: 100, output: 10)
        let second = AntigravityFixture.call(at: t0.addingTimeInterval(9), input: 200, output: 20)
        try fixture.transcript(id, rows: [first, String(second.prefix(40))], trailing: "")
        let source = fixture.source()
        #expect(source.scanTranscripts(now: now).daily.first?.messages == 1)
        try fixture.transcript(id, rows: [first, second])
        #expect(source.scanTranscripts(now: now).daily.first?.messages == 2)
    }

    @Test("only listed conversations are read; brain/ is never walked")
    func discovery() throws {
        let fixture = try AntigravityFixture()
        defer { fixture.tearDown() }
        let t0 = now.addingTimeInterval(-600)
        // Listed, no transcript: contributes nothing.
        try fixture.conversation(rows: nil)
        // A transcript with no conversation file beside it: never read.
        try fixture.transcript(
            AntigravityFixture.newID(), rows: [AntigravityFixture.call(at: t0, input: 1, output: 1)])
        // A listed one, plus a decoy transcript inside its own worktree.
        let id = try fixture.conversation(rows: [
            AntigravityFixture.call(at: t0, input: 40, output: 4),
        ])
        let decoy = fixture.home.appending(
            path: "brain/\(id)/.system_generated/worktrees/w/.system_generated/logs/transcript.jsonl")
        try FileManager.default.createDirectory(
            at: decoy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(AntigravityFixture.call(at: t0, input: 9999, output: 9999).utf8).write(to: decoy)
        // A name that isn't a conversation id is never turned into a path.
        try Data().write(to: fixture.home.appending(path: "conversations/not an id!.db"))

        let scan = fixture.source().scanTranscriptsReadOnly(now: now)
        #expect(scan.daily.first?.tokens == 44)
        #expect(scan.daily.first?.messages == 1)
        #expect(AntigravityHome.isConversationID(id))
        #expect(!AntigravityHome.isConversationID("../escape"))
    }

    @Test("a forked conversation's copied calls and prompts count once")
    func forkDedup() throws {
        let fixture = try AntigravityFixture()
        defer { fixture.tearDown() }
        let t0 = now.addingTimeInterval(-3600)
        let shared = [
            AntigravityFixture.prompt(at: t0),
            AntigravityFixture.call(at: t0, input: 500, output: 50),
        ]
        let original = try fixture.conversation(rows: shared)
        let fork = try fixture.conversation(
            rows: shared + [AntigravityFixture.call(at: t0.addingTimeInterval(60), input: 7, output: 3)])
        let source = fixture.source()
        let scan = source.scanTranscripts(now: now)
        #expect(scan.daily.first?.messages == 2)
        #expect(scan.daily.first?.prompts == 1)
        #expect(scan.daily.first?.tokens == 550 + 10)
        // Warm cache: the same answer, recomputed from the cache alone.
        #expect(source.scanTranscripts(now: now).daily == scan.daily)
        // Whichever file goes, the shared call is still counted once.
        let gone = [original, fork].min { fixture.transcriptURL($0).path < fixture.transcriptURL($1).path }!
        try FileManager.default.removeItem(at: fixture.home.appending(path: "conversations/\(gone).db"))
        let after = source.scanTranscripts(now: now)
        #expect(after.daily.first?.prompts == 1)
        #expect(after.daily.first?.tokens == (gone == original ? 560 : 550))
    }

    @Test("prompts in the same second are distinct unless their files are forks")
    func concurrentPrompts() throws {
        let fixture = try AntigravityFixture()
        defer { fixture.tearDown() }
        let t0 = Date(timeIntervalSince1970: ((now.timeIntervalSince1970 - 3600) / 60)
            .rounded(.down) * 60)
        // Three `agy -p` runs started in the same second: three prompts.
        for tokens in [100, 200, 300] {
            try fixture.conversation(rows: [
                AntigravityFixture.prompt(at: t0),
                AntigravityFixture.call(at: t0.addingTimeInterval(2), input: tokens, output: 1),
            ])
        }
        // One file stating the same call twice counts it twice.
        try fixture.conversation(rows: [
            AntigravityFixture.call(at: t0.addingTimeInterval(9), input: 7, output: 1),
            AntigravityFixture.call(at: t0.addingTimeInterval(9), input: 7, output: 1, step: 2),
        ])
        let scan = fixture.source().scanTranscriptsReadOnly(now: now)
        #expect(scan.daily.first?.prompts == 3)
        #expect(scan.daily.first?.messages == 5)
    }

    @Test("a transcript that can't be read keeps what it had, and is read again")
    func unreadableKeepsRecord() throws {
        let fixture = try AntigravityFixture()
        defer { fixture.tearDown() }
        let t0 = now.addingTimeInterval(-600)
        let id = try fixture.conversation(rows: [
            AntigravityFixture.call(at: t0, input: 40, output: 4),
        ])
        let source = fixture.source()
        #expect(source.scanTranscripts(now: now).daily.first?.tokens == 44)
        // The file grows, then can't be read while it's scanned.
        try fixture.transcript(id, rows: [
            AntigravityFixture.call(at: t0, input: 40, output: 4),
            AntigravityFixture.call(at: t0.addingTimeInterval(5), input: 50, output: 5),
        ])
        let url = fixture.transcriptURL(id)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        #expect(source.scanTranscripts(now: now).daily.first?.tokens == 44)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(source.scanTranscripts(now: now).daily.first?.tokens == 99)
    }

    @Test("rows that don't state both counts are not calls; unknown keys are fine")
    func malformedRows() throws {
        let fixture = try AntigravityFixture()
        defer { fixture.tearDown() }
        let stamp = AntigravityFixture.stamp(now.addingTimeInterval(-60))
        try fixture.conversation(rows: [
            #"{"created_at":"\#(stamp)","type":"PLANNER_RESPONSE","model":"gemini-4-neon","input_tokens":5}"#,
            #"{"created_at":"\#(stamp)","type":"PLANNER_RESPONSE","output_tokens":5}"#,
            #"{"created_at":"nonsense","type":"PLANNER_RESPONSE","model":"m","input_tokens":5,"output_tokens":5}"#,
            "not json at all",
            #"{"created_at":"\#(stamp)","model":"gemini-4-neon","input_tokens":9000000000000000000,"output_tokens":9000000000000000000}"#,
            #"{"created_at":"\#(stamp)","model":"gemini-4-neon","input_tokens":3,"output_tokens":2,"brand_new":{"x":[1]}}"#,
        ])
        let scan = fixture.source().scanTranscriptsReadOnly(now: now)
        #expect(scan.daily.first?.messages == 1)
        #expect(scan.daily.first?.tokens == 5)
    }

    @Test("the minute timeline keeps 56 days; the daily totals keep everything")
    func timelineRetention() throws {
        let fixture = try AntigravityFixture()
        defer { fixture.tearDown() }
        try fixture.conversation(rows: [
            AntigravityFixture.call(at: now.addingTimeInterval(-60 * 86400), input: 10, output: 1),
            AntigravityFixture.call(at: now.addingTimeInterval(-3600), input: 20, output: 2),
        ])
        let scan = fixture.source().scanTranscriptsReadOnly(now: now)
        #expect(scan.daily.count == 2)
        #expect(scan.timeline.count == 1)
    }

    @Test("reading writes nothing in the home; the read-only scan writes no cache")
    func readOnly() throws {
        let fixture = try AntigravityFixture()
        defer { fixture.tearDown() }
        try fixture.conversation(rows: [
            AntigravityFixture.call(at: now.addingTimeInterval(-60), input: 1, output: 1),
        ])
        let before = fixture.homeSnapshot()
        _ = fixture.source().scanTranscriptsReadOnly(now: now)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.cache.appending(path: "activity-cache.json").path))
        _ = fixture.source().scanTranscripts(now: now)
        #expect(FileManager.default.fileExists(
            atPath: fixture.cache.appending(path: "activity-cache.json").path))
        #expect(fixture.homeSnapshot() == before)
    }

    @Test("the source declares what it reads and nothing more")
    func declarations() throws {
        let fixture = try AntigravityFixture()
        defer { fixture.tearDown() }
        let source = fixture.source()
        #expect(source.watchDirectories == [fixture.home.appending(path: "conversations")])
        #expect(source.diskUsage(now: now) == nil)
        #expect(!source.providesSessions)
        #expect(source.scanPromptDays().isEmpty)
        #expect(source.displayPaths.count == 2)
    }
}
