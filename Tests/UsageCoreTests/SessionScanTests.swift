import Foundation
import Testing
@testable import UsageCore

/// Temp projects tree + scanner, with a writer that creates intermediate
/// directories so subagent fixtures (`S/subagents/workflows/wf_1/…`) are one
/// call.
private struct SessionFixture {
    let scanner: TranscriptScanner
    let projectRoot: URL
    private let base: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appending(path: "session-scan-tests-\(UUID().uuidString)")
        projectRoot = base.appending(path: "projects/demo")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        scanner = TranscriptScanner(
            root: base.appending(path: "projects"),
            cacheDirectory: base.appending(path: "cache"),
            calendar: calendar)
    }

    func write(_ relativePath: String, _ content: String) throws {
        let url = projectRoot.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }
}

private let scanNow = FlexibleISO8601.date(from: "2026-08-03T00:00:00.000Z")!

private func at(_ iso: String) -> Date {
    FlexibleISO8601.date(from: iso)!
}

/// A realistic interactive transcript: blank + real ai-titles, a slash
/// command, a typed prompt, one API call streamed across three lines (shared
/// requestId/usage, distinct tool_use blocks), tool_result plumbing, a second
/// call, a compaction marker, and a queue-operation that must not count.
private let mainTranscript = #"""
{"type":"ai-title","aiTitle":"   ","sessionId":"S"}
{"type":"user","timestamp":"2026-08-01T10:00:00.000Z","entrypoint":"cli","cwd":"/Users/dev/proj","gitBranch":"main","version":"2.1.231","message":{"role":"user","content":"<command-name>/model</command-name><command-args>fable</command-args>"}}
{"type":"user","timestamp":"2026-08-01T10:00:30.000Z","entrypoint":"cli","message":{"role":"user","content":"Build the session browser now"}}
{"type":"assistant","timestamp":"2026-08-01T10:01:00.000Z","requestId":"r1","message":{"id":"m1","model":"claude-fable-5","usage":{"input_tokens":100,"output_tokens":50},"content":[{"type":"text","text":"working"}]}}
{"type":"assistant","timestamp":"2026-08-01T10:01:05.000Z","requestId":"r1","message":{"id":"m1","model":"claude-fable-5","usage":{"input_tokens":100,"output_tokens":50},"content":[{"type":"tool_use","id":"tu1","name":"Bash"}]}}
{"type":"assistant","timestamp":"2026-08-01T10:01:10.000Z","requestId":"r1","message":{"id":"m1","model":"claude-fable-5","usage":{"input_tokens":100,"output_tokens":50},"content":[{"type":"tool_use","id":"tu2","name":"Read"}]}}
{"type":"user","timestamp":"2026-08-01T10:01:20.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"blob"}]}}
{"type":"assistant","timestamp":"2026-08-01T10:02:00.000Z","requestId":"r2","message":{"id":"m2","model":"claude-fable-5","usage":{"input_tokens":200,"output_tokens":80},"content":[{"type":"text","text":"done"}]}}
{"type":"user","timestamp":"2026-08-01T10:03:00.000Z","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued from a previous conversation"}}
{"type":"ai-title","aiTitle":"Session browser build","sessionId":"S"}
{"type":"queue-operation","content":"queued prompt that must not count","sessionId":"S","timestamp":"2026-08-01T10:03:30.000Z"}
"""#

private let subagentA = #"""
{"type":"user","timestamp":"2026-08-01T10:01:30.000Z","isSidechain":true,"entrypoint":"cli","message":{"role":"user","content":"explore the codebase"}}
{"type":"assistant","timestamp":"2026-08-01T10:04:00.000Z","isSidechain":true,"requestId":"sa1","message":{"id":"sm1","model":"claude-haiku-4-5","usage":{"input_tokens":10,"output_tokens":5},"content":[{"type":"tool_use","id":"stu1","name":"Grep"}]}}
"""#

private let subagentB = #"""
{"type":"assistant","timestamp":"2026-08-01T10:12:00.000Z","isSidechain":true,"requestId":"wa1","message":{"id":"wm1","model":"claude-haiku-4-5","usage":{"input_tokens":20,"output_tokens":10}}}
"""#

@Suite("Session scan")
struct SessionScanTests {
    @Test("one cli transcript rolls up: title chain, counts, models, span, kind")
    func summaryFields() throws {
        let fixture = try SessionFixture()
        defer { fixture.tearDown() }
        try fixture.write("S.jsonl", mainTranscript)

        let sessions = fixture.scanner.scan(now: scanNow).sessions
        #expect(sessions.count == 1)
        let s = try #require(sessions.first)
        #expect(s.id == "S")
        // Last non-blank ai-title wins; the blank first one is ignored.
        #expect(s.title == "Session browser build")
        #expect(s.kind == .interactive)
        #expect(s.projectPath == "/Users/dev/proj")
        #expect(s.gitBranch == "main")
        #expect(s.agentVersion == "2.1.231")
        #expect(s.prompts == 1)
        #expect(s.compactions == 1)
        // r1 streamed over three lines counts once; r2 is the second call.
        #expect(s.apiCalls == 2)
        // …but the streamed lines' distinct tool_use blocks all count.
        #expect(s.toolCalls == 2)
        #expect(s.models == ["claude-fable-5": TokenTally(input: 300, output: 130)])
        #expect(s.start == at("2026-08-01T10:00:30.000Z"))
        #expect(s.end == at("2026-08-01T10:03:00.000Z"))
        // Active minutes 10:01 and 10:02 stitch into one 120s stretch.
        #expect(s.activeSeconds == TimeInterval(120))
        #expect(s.subagentCount == 0)
    }

    @Test("subagent files join their parent by path — including workflows depth")
    func subagentJoin() throws {
        let fixture = try SessionFixture()
        defer { fixture.tearDown() }
        try fixture.write("S.jsonl", mainTranscript)
        try fixture.write("S/subagents/agent-a.jsonl", subagentA)
        try fixture.write("S/subagents/workflows/wf_1/agent-b.jsonl", subagentB)

        let sessions = fixture.scanner.scan(now: scanNow).sessions
        #expect(sessions.count == 1)
        let s = try #require(sessions.first)
        #expect(s.subagentCount == 2)
        #expect(s.apiCalls == 4)
        // The subagent's sidechain prompt is not a user prompt.
        #expect(s.prompts == 1)
        #expect(s.toolCalls == 3)
        #expect(s.models["claude-haiku-4-5"] == TokenTally(input: 30, output: 15))
        #expect(s.end == at("2026-08-01T10:12:00.000Z"))
    }

    @Test("active time is a union of stretches, never a sum of parts")
    func stretchUnion() throws {
        let fixture = try SessionFixture()
        defer { fixture.tearDown() }
        try fixture.write("U.jsonl", #"""
            {"type":"assistant","timestamp":"2026-08-01T10:00:00.000Z","requestId":"p1","message":{"id":"pm1","model":"claude-fable-5","usage":{"input_tokens":5,"output_tokens":5}}}
            """#)
        // Subagent overlaps the parent's minute, then runs again at 10:10 —
        // within grace, so its own stretch spans 10:00–10:11.
        try fixture.write("U/subagents/agent-a.jsonl", #"""
            {"type":"assistant","timestamp":"2026-08-01T10:00:30.000Z","isSidechain":true,"requestId":"q1","message":{"id":"qm1","model":"claude-fable-5","usage":{"input_tokens":5,"output_tokens":5}}}
            {"type":"assistant","timestamp":"2026-08-01T10:10:00.000Z","isSidechain":true,"requestId":"q2","message":{"id":"qm2","model":"claude-fable-5","usage":{"input_tokens":5,"output_tokens":5}}}
            """#)

        let s = try #require(fixture.scanner.scan(now: scanNow).sessions.first)
        // Union 10:00–10:11 = 660s; a sum would double the overlapped minute.
        #expect(s.activeSeconds == TimeInterval(660))
    }

    @Test("sdk entrypoints read as background; absent entrypoint as interactive")
    func backgroundKind() throws {
        let fixture = try SessionFixture()
        defer { fixture.tearDown() }
        try fixture.write("bg.jsonl", #"""
            {"type":"user","timestamp":"2026-08-01T09:00:00.000Z","entrypoint":"sdk-py","promptSource":"sdk","message":{"role":"user","content":"Review this change"}}
            {"type":"assistant","timestamp":"2026-08-01T09:00:30.000Z","requestId":"b1","message":{"id":"bm1","model":"claude-fable-5","usage":{"input_tokens":10,"output_tokens":5}}}
            """#)
        try fixture.write("old.jsonl", #"""
            {"type":"assistant","timestamp":"2026-08-01T08:00:00.000Z","requestId":"o1","message":{"id":"om1","model":"claude-fable-5","usage":{"input_tokens":1,"output_tokens":1}}}
            """#)

        let sessions = fixture.scanner.scan(now: scanNow).sessions
        #expect(sessions.first { $0.id == "bg" }?.kind == .background)
        #expect(sessions.first { $0.id == "old" }?.kind == .interactive)
    }

    @Test("title falls back: prompt preview, then the id itself")
    func titleChain() throws {
        let fixture = try SessionFixture()
        defer { fixture.tearDown() }
        try fixture.write("noTitle.jsonl", #"""
            {"type":"user","timestamp":"2026-08-01T09:00:00.000Z","message":{"role":"user","content":"fix the flaky test"}}
            {"type":"assistant","timestamp":"2026-08-01T09:01:00.000Z","requestId":"n1","message":{"id":"nm1","model":"claude-fable-5","usage":{"input_tokens":1,"output_tokens":1}}}
            """#)
        try fixture.write("cmdOnly.jsonl", #"""
            {"type":"user","timestamp":"2026-08-01T09:02:00.000Z","message":{"role":"user","content":"<command-name>/compact</command-name>"}}
            {"type":"assistant","timestamp":"2026-08-01T09:03:00.000Z","requestId":"c1","message":{"id":"cm1","model":"claude-fable-5","usage":{"input_tokens":1,"output_tokens":1}}}
            """#)

        let sessions = fixture.scanner.scan(now: scanNow).sessions
        #expect(sessions.first { $0.id == "noTitle" }?.title == "fix the flaky test")
        #expect(sessions.first { $0.id == "cmdOnly" }?.title == "cmdOnly")
    }

    @Test("orphan subagent trees and metadata-only stubs never list")
    func orphansAndStubs() throws {
        let fixture = try SessionFixture()
        defer { fixture.tearDown() }
        try fixture.write("S9/subagents/agent-x.jsonl", subagentA)
        try fixture.write("stub.jsonl", #"""
            {"type":"ai-title","aiTitle":"Ghost","sessionId":"stub"}
            {"type":"last-prompt","lastPrompt":"x","leafUuid":"u","sessionId":"stub"}
            """#)

        let sessions = fixture.scanner.scan(now: scanNow).sessions
        #expect(sessions.isEmpty)
    }

    @Test("synthetic zero-usage lines and queue operations produce no session")
    func syntheticAndQueue() throws {
        let fixture = try SessionFixture()
        defer { fixture.tearDown() }
        try fixture.write("synth.jsonl", #"""
            {"type":"assistant","timestamp":"2026-08-01T09:10:00.000Z","requestId":"s1","message":{"id":"sy1","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}
            {"type":"queue-operation","content":"do the thing","sessionId":"synth","timestamp":"2026-08-01T09:11:00.000Z"}
            """#)

        #expect(fixture.scanner.scan(now: scanNow).sessions.isEmpty)
    }

    @Test("sessions come out newest activity first")
    func endDescending() throws {
        let fixture = try SessionFixture()
        defer { fixture.tearDown() }
        try fixture.write("older.jsonl", #"""
            {"type":"assistant","timestamp":"2026-08-01T09:00:00.000Z","requestId":"a1","message":{"id":"am1","model":"claude-fable-5","usage":{"input_tokens":1,"output_tokens":1}}}
            """#)
        try fixture.write("newer.jsonl", #"""
            {"type":"assistant","timestamp":"2026-08-01T11:00:00.000Z","requestId":"z1","message":{"id":"zm1","model":"claude-fable-5","usage":{"input_tokens":1,"output_tokens":1}}}
            """#)

        let sessions = fixture.scanner.scan(now: scanNow).sessions
        #expect(sessions.map { $0.id } == ["newer", "older"])
    }

    @Test("a modified transcript re-summarizes")
    func modifiedResummarizes() throws {
        let fixture = try SessionFixture()
        defer { fixture.tearDown() }
        try fixture.write("S.jsonl", mainTranscript)
        _ = fixture.scanner.scan(now: scanNow)

        try fixture.write("S.jsonl", mainTranscript + "\n" + #"""
            {"type":"user","timestamp":"2026-08-01T10:05:00.000Z","message":{"role":"user","content":"one more thing"}}
            """#)

        let s = try #require(fixture.scanner.scan(now: scanNow).sessions.first)
        #expect(s.prompts == 2)
        #expect(s.end == at("2026-08-01T10:05:00.000Z"))
    }

    @Test("the cache persists the scrubbed preview and never the prompt body")
    func cacheBytes() throws {
        let fixture = try SessionFixture()
        defer { fixture.tearDown() }
        let filler = String(repeating: "lorem ipsum ", count: 12)
        let prompt = "PREVIEWHEADQQ \(filler)TAILMARKERQQ"
        try fixture.write("cb.jsonl", #"""
            {"type":"user","timestamp":"2026-08-01T09:00:00.000Z","message":{"role":"user","content":"\#(prompt)"}}
            """#)

        _ = fixture.scanner.scan(now: scanNow)

        let cacheData = try Data(contentsOf: fixture.scanner.cacheURL)
        let cacheText = String(decoding: cacheData, as: UTF8.self)
        #expect(cacheText.contains("PREVIEWHEADQQ"))
        // Beyond the 120-char cap: must not be materialized anywhere.
        #expect(!cacheText.contains("TAILMARKERQQ"))
    }
}

@Suite("Session detail")
struct SessionDetailTests {
    @Test("rows in file order: command, prompt, calls (streamed lines collapse), compaction")
    func rowOrder() throws {
        let fixture = try SessionFixture()
        defer { fixture.tearDown() }
        try fixture.write("S.jsonl", mainTranscript)
        _ = fixture.scanner.scan(now: scanNow)

        let detail = try #require(fixture.scanner.sessionDetail(id: "S"))
        #expect(detail.rows.count == 5)
        #expect(detail.rows.map { $0.id } == [0, 1, 2, 3, 4])
        #expect(detail.rows[0].kind == .command(name: "/model"))
        #expect(detail.rows[1].kind == .prompt(preview: "Build the session browser now"))
        // The streamed call keeps its first line's timestamp and gathers the
        // later lines' tool_use blocks.
        #expect(detail.rows[2].t == at("2026-08-01T10:01:00.000Z"))
        #expect(detail.rows[2].kind == .apiCall(
            model: "claude-fable-5",
            tally: TokenTally(input: 100, output: 50), toolUses: 2))
        #expect(detail.rows[3].kind == .apiCall(
            model: "claude-fable-5",
            tally: TokenTally(input: 200, output: 80), toolUses: 0))
        #expect(detail.rows[4].kind == .compaction)
    }

    @Test("sidechain lines in the main file: usage rows yes, prompt rows no")
    func sidechainInMain() throws {
        let fixture = try SessionFixture()
        defer { fixture.tearDown() }
        try fixture.write("side.jsonl", #"""
            {"type":"user","timestamp":"2026-08-01T09:00:00.000Z","message":{"role":"user","content":"real prompt"}}
            {"type":"user","timestamp":"2026-08-01T09:01:00.000Z","isSidechain":true,"message":{"role":"user","content":"sidechain prompt"}}
            {"type":"assistant","timestamp":"2026-08-01T09:02:00.000Z","isSidechain":true,"requestId":"sc1","message":{"id":"scm1","model":"claude-fable-5","usage":{"input_tokens":5,"output_tokens":5}}}
            """#)
        _ = fixture.scanner.scan(now: scanNow)

        let detail = try #require(fixture.scanner.sessionDetail(id: "side"))
        #expect(detail.summary.prompts == 1)
        #expect(detail.rows.count == 2)
        #expect(detail.rows[0].kind == .prompt(preview: "real prompt"))
        if case .apiCall = detail.rows[1].kind {} else {
            Issue.record("sidechain usage must still be a call row")
        }
    }

    @Test("command output, caveats, and task notifications produce no rows")
    func skipsNoise() throws {
        let fixture = try SessionFixture()
        defer { fixture.tearDown() }
        try fixture.write("noise.jsonl", #"""
            {"type":"user","timestamp":"2026-08-01T09:00:00.000Z","message":{"role":"user","content":"<local-command-stdout>Set model to Fable 5</local-command-stdout>"}}
            {"type":"user","timestamp":"2026-08-01T09:00:10.000Z","message":{"role":"user","content":"Caveat: the messages below were generated"}}
            {"type":"user","timestamp":"2026-08-01T09:00:20.000Z","message":{"role":"user","content":"[SYSTEM NOTIFICATION - NOT USER INPUT] <task-notification>done</task-notification>"}}
            {"type":"user","timestamp":"2026-08-01T09:00:30.000Z","promptSource":"system","message":{"role":"user","content":"synthetic system prompt"}}
            {"type":"assistant","timestamp":"2026-08-01T09:01:00.000Z","requestId":"n1","message":{"id":"nm1","model":"claude-fable-5","usage":{"input_tokens":1,"output_tokens":1}}}
            """#)
        _ = fixture.scanner.scan(now: scanNow)

        let detail = try #require(fixture.scanner.sessionDetail(id: "noise"))
        #expect(detail.summary.prompts == 0)
        #expect(detail.rows.count == 1)
        if case .apiCall = detail.rows[0].kind {} else {
            Issue.record("only the call row should remain")
        }
    }

    @Test("subagent calls join the rows flagged and time-interleaved")
    func subagentRollup() throws {
        let fixture = try SessionFixture()
        defer { fixture.tearDown() }
        try fixture.write("S.jsonl", mainTranscript)
        try fixture.write("S/subagents/agent-a.jsonl", subagentA)
        try fixture.write("S/subagents/workflows/wf_1/agent-b.jsonl", subagentB)
        _ = fixture.scanner.scan(now: scanNow)

        let detail = try #require(fixture.scanner.sessionDetail(id: "S"))
        #expect(detail.summary.apiCalls == 4)
        #expect(detail.summary.subagentCount == 2)
        #expect(detail.rows.count == 7)
        #expect(detail.rows.prefix(5).allSatisfy { !$0.subagent })
        #expect(detail.rows[5].subagent)
        #expect(detail.rows[5].t == at("2026-08-01T10:04:00.000Z"))
        #expect(detail.rows[5].kind == .apiCall(
            model: "claude-haiku-4-5",
            tally: TokenTally(input: 10, output: 5), toolUses: 1))
        #expect(detail.rows[6].subagent)
        // The reconciliation contract: the rows' spend reaches the summary's
        // — the chart must never trail the card by the subagents' share.
        let rowTokens = detail.rows.reduce(0) { sum, row in
            if case .apiCall(_, let tally, _) = row.kind { return sum + tally.total }
            return sum
        }
        #expect(rowTokens == detail.summary.totalTokens)
    }

    @Test("no cache needed: main and subagents resolve by directory walk")
    func coldCache() throws {
        let fixture = try SessionFixture()
        defer { fixture.tearDown() }
        try fixture.write("S.jsonl", mainTranscript)
        try fixture.write("S/subagents/agent-a.jsonl", subagentA)

        // No scan has run: the detail parse reads disk truth directly, so
        // the subagent's call is present all the same.
        let detail = try #require(fixture.scanner.sessionDetail(id: "S"))
        #expect(detail.summary.apiCalls == 3)
        #expect(detail.summary.subagentCount == 1)
        #expect(detail.rows.count == 6)
    }

    @Test("unknown ids and deleted transcripts return nil")
    func unknownAndDeleted() throws {
        let fixture = try SessionFixture()
        defer { fixture.tearDown() }
        try fixture.write("S.jsonl", mainTranscript)
        _ = fixture.scanner.scan(now: scanNow)

        #expect(fixture.scanner.sessionDetail(id: "nope") == nil)

        try FileManager.default.removeItem(at: fixture.projectRoot.appending(path: "S.jsonl"))
        #expect(fixture.scanner.sessionDetail(id: "S") == nil)
    }

    @Test("the row cap truncates pathological files with a marker row")
    func rowCap() throws {
        let fixture = try SessionFixture()
        defer { fixture.tearDown() }
        let lines = (0..<(TranscriptScanner.detailRowCap + 50)).map { index in
            let second = String(format: "%02d", index % 60)
            let minute = String(format: "%02d", (index / 60) % 60)
            let hour = String(format: "%02d", 9 + index / 3600)
            return #"{"type":"user","timestamp":"2026-08-01T\#(hour):\#(minute):\#(second).000Z","message":{"role":"user","content":"prompt \#(index)"}}"#
        }
        try fixture.write("big.jsonl", lines.joined(separator: "\n"))

        let detail = try #require(fixture.scanner.sessionDetail(id: "big"))
        #expect(detail.rows.count == TranscriptScanner.detailRowCap + 1)
        #expect(detail.rows.last?.kind == .command(name: "… breakdown truncated"))
        // The summary still covers every line, not just the capped rows.
        #expect(detail.summary.prompts == TranscriptScanner.detailRowCap + 50)
    }

    @Test("cancellation abandons a detail parse")
    func cancellation() async throws {
        let fixture = try SessionFixture()
        defer { fixture.tearDown() }
        let lines = (0..<4000).map { index in
            #"{"type":"user","timestamp":"2026-08-01T09:00:00.000Z","message":{"role":"user","content":"prompt \#(index)"}}"#
        }
        try fixture.write("big.jsonl", lines.joined(separator: "\n"))

        let scanner = fixture.scanner
        let task = Task { () -> SessionDetail? in
            // Let the cancellation land before the parse begins; the sleep
            // throws immediately once the task is cancelled.
            try? await Task.sleep(for: .milliseconds(50))
            return scanner.sessionDetail(id: "big")
        }
        task.cancel()
        let result = await task.value
        #expect(result == nil)
    }
}
