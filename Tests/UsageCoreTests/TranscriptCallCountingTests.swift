import Foundation
import Testing

@testable import UsageCore

/// How a transcript's API calls are counted — the 0.85.0 rules, each pinned
/// against the shape Claude Code actually writes.
///
/// Measured against ccusage 20.0.20 over 2,239 real transcripts before these
/// rules landed: keeping a streamed call's FIRST line lost 18.8M output tokens
/// (31% of the corpus's output), and never reading `usage.iterations` lost
/// every advisor sub-call. Both were pure under-counts.
@Suite("transcript call counting")
struct TranscriptCallCountingTests {
    func makeScanner() throws -> (TranscriptScanner, URL) {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "call-counting-\(UUID().uuidString)")
        let root = base.appending(path: "projects/demo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return (
            TranscriptScanner(
                root: base.appending(path: "projects"),
                cacheDirectory: base.appending(path: "cache"), calendar: calendar),
            root
        )
    }

    static let now = FlexibleISO8601.date(from: "2026-08-03T00:00:00.000Z")!

    func scan(_ lines: String, file: String = "a.jsonl") throws -> TranscriptScan {
        let (scanner, root) = try makeScanner()
        try lines.write(to: root.appending(path: file), atomically: true, encoding: .utf8)
        return scanner.scan(now: Self.now)
    }

    // MARK: - A streamed call counts once, at its finished size

    @Test("the finished line of a streamed group wins, however late it arrives")
    func streamedGroupKeepsTheLargest() throws {
        // Five lines, one call — exactly the shape on disk:
        // req_011CdBsEWMzVitz4hBfxaJdV carried output_tokens 4,4,4,4,739.
        let lines = (0..<5).map { index in
            let output = index == 4 ? 739 : 4
            return """
                {"timestamp":"2026-08-02T09:0\(index):00.000Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":2,"output_tokens":\(output),"cache_creation_input_tokens":16574}}}
                """
        }.joined(separator: "\n")

        let scan = try scan(lines)
        #expect(scan.daily.count == 1)
        #expect(scan.daily[0].messages == 1)
        #expect(scan.daily[0].models == [
            "claude-opus-4-8": TokenTally(input: 2, output: 739, cacheCreation: 16574),
        ])
    }

    @Test("a group whose lines never grow still counts exactly once")
    func identicalLinesCollapse() throws {
        let line = """
            {"timestamp":"2026-08-02T09:00:00.000Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":7}}}
            """
        let scan = try scan([line, line, line].joined(separator: "\n"))
        #expect(scan.daily[0].messages == 1)
        #expect(scan.daily[0].tokens == 12)
    }

    @Test("the winner's own timestamp buckets the call, even across midnight")
    func winnerCarriesTheDay() throws {
        // Mid-stream at 23:59, finished at 00:00 the next day: the finished
        // record is the call, so the call lands on the second day.
        let lines = """
            {"timestamp":"2026-08-01T23:59:59.000Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":1}}}
            {"timestamp":"2026-08-02T00:00:01.000Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":900}}}
            """
        let scan = try scan(lines)
        #expect(scan.daily.count == 1)
        #expect(scan.daily[0].tokens == 1000)
    }

    // MARK: - Advisor sub-calls

    /// The advisor's own call: a different model, no cache at all (it re-sends
    /// the transcript fresh), and ADDITIVE to the turn that spawned it — the
    /// parent's `usage` never mentions those tokens.
    static let withAdvisor = """
        {"timestamp":"2026-08-02T09:00:00.000Z","requestId":"r1","message":{"id":"m1","model":"claude-fable-5","usage":{"input_tokens":6,"output_tokens":3206,"cache_creation_input_tokens":33825,"cache_read_input_tokens":26053,"cache_creation":{"ephemeral_5m_input_tokens":33825,"ephemeral_1h_input_tokens":0},"iterations":[{"input_tokens":6,"output_tokens":3206,"cache_read_input_tokens":26053,"cache_creation_input_tokens":33825,"type":"message"},{"input_tokens":120000,"output_tokens":900,"model":"claude-opus-5","type":"advisor_message"}]}}}
        """

    @Test("an advisor_message iteration is billed as its own call, on its own model")
    func advisorCountsSeparately() throws {
        let scan = try scan(Self.withAdvisor)
        #expect(scan.daily[0].models == [
            "claude-fable-5": TokenTally(
                input: 6, output: 3206, cacheCreation: 33825, cacheRead: 26053),
            "claude-opus-5": TokenTally(input: 120_000, output: 900),
        ])
        // Two calls, not one: the sub-call is a real API round trip.
        #expect(scan.daily[0].messages == 2)
    }

    @Test("a `message` iteration is the turn restating itself and must NOT double it")
    func messageIterationIsNotDoubleCounted() throws {
        let scan = try scan(Self.withAdvisor)
        let parent = scan.daily[0].models["claude-fable-5"]
        // Exactly the parent's own usage — the mirroring iteration adds nothing.
        #expect(parent?.output == 3206)
        #expect(parent?.cacheCreation == 33825)
    }

    @Test("the sibling lines that each restate the iterations array collapse to one advisor call")
    func advisorSurvivesStreaming() throws {
        // The advisor rides the finished line; an earlier line of the same
        // call carries it too. One sub-call, not two.
        let lines = """
            {"timestamp":"2026-08-02T09:00:00.000Z","requestId":"r1","message":{"id":"m1","model":"claude-fable-5","usage":{"input_tokens":6,"output_tokens":10,"iterations":[{"input_tokens":120000,"output_tokens":900,"model":"claude-opus-5","type":"advisor_message"}]}}}
            {"timestamp":"2026-08-02T09:00:05.000Z","requestId":"r1","message":{"id":"m1","model":"claude-fable-5","usage":{"input_tokens":6,"output_tokens":500,"iterations":[{"input_tokens":120000,"output_tokens":900,"model":"claude-opus-5","type":"advisor_message"}]}}}
            """
        let scan = try scan(lines)
        #expect(scan.daily[0].models["claude-opus-5"] == TokenTally(input: 120_000, output: 900))
        #expect(scan.daily[0].models["claude-fable-5"] == TokenTally(input: 6, output: 500))
        #expect(scan.daily[0].messages == 2)
    }

    @Test("two advisor calls on one turn stay distinct; an unmodelled iteration is ignored")
    func advisorIndexing() throws {
        let lines = """
            {"timestamp":"2026-08-02T09:00:00.000Z","requestId":"r1","message":{"id":"m1","model":"claude-fable-5","usage":{"input_tokens":1,"output_tokens":1,"iterations":[{"input_tokens":10,"output_tokens":2,"model":"claude-opus-5","type":"advisor_message"},{"input_tokens":30,"output_tokens":4,"model":"claude-opus-5","type":"advisor_message"},{"input_tokens":99,"output_tokens":99,"type":"advisor_message"}]}}}
            """
        let scan = try scan(lines)
        // 10+2 and 30+4 both land; the model-less third can't be priced and
        // is not invented into existence.
        #expect(scan.daily[0].models["claude-opus-5"] == TokenTally(input: 40, output: 6))
        #expect(scan.daily[0].messages == 3)
    }

    @Test("a turn whose own usage is empty still surrenders its advisor call")
    func advisorSurvivesAnEmptyParent() throws {
        let lines = """
            {"timestamp":"2026-08-02T09:00:00.000Z","requestId":"r1","message":{"id":"m1","model":"claude-fable-5","usage":{"input_tokens":0,"output_tokens":0,"iterations":[{"input_tokens":500,"output_tokens":20,"model":"claude-opus-5","type":"advisor_message"}]}}}
            """
        let scan = try scan(lines)
        #expect(scan.daily[0].models == ["claude-opus-5": TokenTally(input: 500, output: 20)])
        #expect(scan.daily[0].messages == 1)
    }

    // MARK: - Tool-use blocks still ride the whole group

    @Test("tool_use blocks accumulate across a group's lines onto the one row")
    func toolUsesAccumulate() throws {
        let (scanner, root) = try makeScanner()
        let id = "11111111-2222-3333-4444-555555555555"
        let lines = """
            {"type":"assistant","timestamp":"2026-08-02T09:00:00.000Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"tool_use","id":"tu1"}]}}
            {"type":"assistant","timestamp":"2026-08-02T09:00:01.000Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":50},"content":[{"type":"tool_use","id":"tu2"}]}}
            """
        try lines.write(
            to: root.appending(path: "\(id).jsonl"), atomically: true, encoding: .utf8)
        let detail = scanner.sessionDetail(id: id)
        let rows = try #require(detail?.rows)
        #expect(rows.count == 1)
        guard case .apiCall(let model, let tally, let toolUses) = rows[0].kind else {
            Issue.record("expected an apiCall row")
            return
        }
        #expect(model == "claude-opus-5")
        // The winner's tally, but BOTH lines' tool_use blocks.
        #expect(tally == TokenTally(input: 1, output: 50))
        #expect(toolUses == 2)
        #expect(detail?.summary.toolCalls == 2)
    }
}
