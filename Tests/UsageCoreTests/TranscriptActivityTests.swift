import Foundation
import Testing
@testable import UsageCore

@Suite("TranscriptScanner")
struct TranscriptScannerTests {
    static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func makeScanner() throws -> (TranscriptScanner, URL) {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "scanner-tests-\(UUID().uuidString)")
        let root = base.appending(path: "projects/demo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scanner = TranscriptScanner(
            root: base.appending(path: "projects"),
            cacheDirectory: base.appending(path: "cache"),
            calendar: Self.utcCalendar()
        )
        return (scanner, root)
    }

    static let transcript = """
        {"timestamp":"2026-08-01T10:00:00.000Z","requestId":"r1","message":{"id":"m1","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":10,"cache_read_input_tokens":40}}}
        {"timestamp":"2026-08-01T11:00:00.000Z","requestId":"r1","message":{"id":"m1b","usage":{"input_tokens":999,"output_tokens":999}}}
        {"timestamp":"2026-08-01T12:00:00.000Z","requestId":"r2","message":{"id":"m2","usage":{"input_tokens":300,"output_tokens":100}}}
        {"timestamp":"2026-08-02T09:00:00.000Z","requestId":"r3","message":{"id":"m3","usage":{"input_tokens":1000,"output_tokens":500}}}
        {"timestamp":"2026-08-02T09:05:00.000Z","type":"user-message-no-usage"}
        not json at all
        """

    /// A `now` that keeps the fixture timestamps inside timeline retention.
    static let scanNow = utcCalendar().date(
        from: DateComponents(year: 2026, month: 8, day: 3))!

    static func minute(_ iso: String) -> Date {
        FlexibleISO8601.date(from: iso)!
    }

    @Test("aggregates per day, sums all token kinds, dedups repeated requestIds")
    func aggregates() throws {
        let (scanner, root) = try makeScanner()
        try Self.transcript.write(to: root.appending(path: "a.jsonl"), atomically: true, encoding: .utf8)

        let activity = scanner.scan(now: Self.scanNow).daily

        #expect(activity.count == 2)
        // Day 1: r1 counted once (200 total incl. cache tokens), r2 = 400.
        #expect(activity[0].tokens == 600)
        #expect(activity[0].messages == 2)
        #expect(activity[1].tokens == 1500)
        #expect(activity[1].messages == 1)
    }

    @Test("second scan with unchanged files returns identical results from cache")
    func cacheStability() throws {
        let (scanner, root) = try makeScanner()
        try Self.transcript.write(to: root.appending(path: "a.jsonl"), atomically: true, encoding: .utf8)

        let first = scanner.scan(now: Self.scanNow)
        let second = scanner.scan(now: Self.scanNow)
        #expect(first == second)
        #expect(!first.timeline.isEmpty)
    }

    @Test("modified files are re-parsed")
    func modifiedFile() throws {
        let (scanner, root) = try makeScanner()
        let file = root.appending(path: "a.jsonl")
        try Self.transcript.write(to: file, atomically: true, encoding: .utf8)
        _ = scanner.scan(now: Self.scanNow)

        let extra = Self.transcript + "\n" +
            #"{"timestamp":"2026-08-03T08:00:00.000Z","requestId":"r9","message":{"id":"m9","usage":{"input_tokens":10,"output_tokens":5}}}"#
        try extra.write(to: file, atomically: true, encoding: .utf8)

        let activity = scanner.scan(now: Self.scanNow).daily
        #expect(activity.count == 3)
        #expect(activity[2].tokens == 15)
    }

    @Test("missing root yields empty activity, not an error")
    func missingRoot() {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "scanner-missing-\(UUID().uuidString)")
        let scanner = TranscriptScanner(
            root: base.appending(path: "nope"),
            cacheDirectory: base.appending(path: "cache"),
            calendar: Self.utcCalendar()
        )
        let scan = scanner.scan()
        #expect(scan.daily.isEmpty)
        #expect(scan.timeline.isEmpty)
    }

    @Test("timeline: minute buckets per model, merged across files, dedup honored")
    func timeline() throws {
        let (scanner, root) = try makeScanner()
        let a = """
            {"timestamp":"2026-08-02T09:00:10.000Z","requestId":"t1","message":{"id":"n1","model":"claude-fable-5","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000}}}
            {"timestamp":"2026-08-02T09:00:40.000Z","requestId":"t2","message":{"id":"n2","model":"claude-fable-5","usage":{"input_tokens":1,"output_tokens":2}}}
            {"timestamp":"2026-08-02T09:00:50.000Z","requestId":"t3","message":{"id":"n3","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":7,"output_tokens":3}}}
            {"timestamp":"2026-08-02T09:01:10.000Z","requestId":"t1","message":{"id":"n4","model":"claude-fable-5","usage":{"input_tokens":999,"output_tokens":999}}}
            {"timestamp":"2026-08-02T10:30:00.000Z","requestId":"t5","message":{"id":"n6","usage":{"input_tokens":4,"output_tokens":4}}}
            """
        let b = """
            {"timestamp":"2026-08-02T09:00:55.000Z","requestId":"u1","message":{"id":"p1","model":"claude-fable-5","usage":{"input_tokens":2,"output_tokens":1}}}
            """
        try a.write(to: root.appending(path: "a.jsonl"), atomically: true, encoding: .utf8)
        try b.write(to: root.appending(path: "b.jsonl"), atomically: true, encoding: .utf8)

        let scan = scanner.scan(now: Self.scanNow)

        // The same records also attribute the day's tokens per model.
        #expect(scan.daily[0].models == [
            "claude-fable-5": TokenTally(input: 13, output: 8, cacheCreation: 100, cacheRead: 1000),
            "claude-haiku-4-5-20251001": TokenTally(input: 7, output: 3),
            "unknown": TokenTally(input: 4, output: 4),
        ])

        #expect(scan.timeline == [
            // Same minute: t1 + t2 from file a, u1 from file b; the duplicate
            // t1 retry is dropped.
            TokenSlot(
                t: Self.minute("2026-08-02T09:00:00.000Z"), model: "claude-fable-5",
                tally: TokenTally(input: 13, output: 8, cacheCreation: 100, cacheRead: 1000)),
            TokenSlot(
                t: Self.minute("2026-08-02T09:00:00.000Z"), model: "claude-haiku-4-5-20251001",
                tally: TokenTally(input: 7, output: 3)),
            // A record without a model still counts, bucketed as "unknown".
            TokenSlot(
                t: Self.minute("2026-08-02T10:30:00.000Z"), model: "unknown",
                tally: TokenTally(input: 4, output: 4)),
        ])
    }

    @Test("slots age out of the timeline after retention; daily totals never do")
    func retention() throws {
        let (scanner, root) = try makeScanner()
        let content = """
            {"timestamp":"2026-07-20T09:00:00.000Z","requestId":"old","message":{"id":"o1","model":"claude-fable-5","usage":{"input_tokens":50,"output_tokens":50}}}
            {"timestamp":"2026-08-02T09:00:00.000Z","requestId":"new","message":{"id":"o2","model":"claude-fable-5","usage":{"input_tokens":5,"output_tokens":5}}}
            """
        try content.write(to: root.appending(path: "a.jsonl"), atomically: true, encoding: .utf8)

        let scan = scanner.scan(now: Self.scanNow)

        #expect(scan.daily.count == 2) // July 20 still feeds the heatmap
        #expect(scan.timeline.count == 1)
        #expect(scan.timeline[0].t == Self.minute("2026-08-02T09:00:00.000Z"))

        // The same trim applies to cached entries on later scans.
        let later = scanner.scan(now: Self.utcCalendar().date(
            from: DateComponents(year: 2026, month: 8, day: 11))!)
        #expect(later.timeline.isEmpty)
        #expect(later.daily.count == 2)
    }

    @Test("a stale cache version is discarded, not misread")
    func staleCacheVersion() throws {
        let (scanner, root) = try makeScanner()
        try Self.transcript.write(to: root.appending(path: "a.jsonl"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: scanner.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"version":1,"files":{"bogus":{"mtime":0,"size":0,"days":{}}}}"#
            .write(to: scanner.cacheURL, atomically: true, encoding: .utf8)

        let scan = scanner.scan(now: Self.scanNow)
        #expect(scan.daily.count == 2)
        #expect(!scan.timeline.isEmpty)
    }
}

@Suite("PromptHistory")
struct PromptHistoryTests {
    static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utcCalendar().date(from: DateComponents(year: year, month: month, day: day))!
    }

    // Epoch ms except where noted: two prompts on 2026-08-01 (10:00Z and
    // 10:43Z), two on 2026-08-02 — one in plain seconds, which real files
    // don't use but the parser tolerates.
    static let history = """
        {"display":"a","project":"/tmp/p","timestamp":1785578400000}
        {"display":"b","project":"/tmp/p","timestamp":1785581000000}
        {"display":"c","project":"/tmp/p","timestamp":1785661200000}
        {"display":"d","project":"/tmp/p","timestamp":1785661300}
        {"display":"missing timestamp","project":"/tmp/p"}
        not json at all
        """

    func makeScanner(contents: String?) throws -> PromptHistoryScanner {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "history-tests-\(UUID().uuidString).jsonl")
        if let contents {
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        return PromptHistoryScanner(fileURL: file, calendar: Self.utcCalendar())
    }

    @Test("counts prompts per day; tolerates seconds, missing fields, garbage")
    func counts() throws {
        let scanner = try makeScanner(contents: Self.history)
        #expect(scanner.scan() == [Self.day(2026, 8, 1): 2, Self.day(2026, 8, 2): 2])
    }

    @Test("missing file yields empty counts, not an error")
    func missingFile() throws {
        let scanner = try makeScanner(contents: nil)
        #expect(scanner.scan().isEmpty)
    }

    @Test("merge keeps token days and adds prompt-only days, sorted")
    func merge() {
        let aug1 = Self.day(2026, 8, 1)
        let jul30 = Self.day(2026, 7, 30)
        let merged = ActivityMerge.merge(
            transcripts: [DailyActivity(day: aug1, tokens: 600, messages: 2)],
            prompts: [aug1: 5, jul30: 3])

        #expect(merged == [
            DailyActivity(day: jul30, tokens: 0, messages: 0, prompts: 3),
            DailyActivity(day: aug1, tokens: 600, messages: 2, prompts: 5),
        ])
    }
}

@Suite("TokenFormat")
struct TokenFormatTests {
    @Test("compact formatting")
    func compact() {
        #expect(TokenFormat.compact(999) == "999")
        #expect(TokenFormat.compact(12_345) == "12.3K")
        #expect(TokenFormat.compact(1_234_567) == "1.2M")
        #expect(TokenFormat.compact(2_500_000_000) == "2.5B")
        #expect(TokenFormat.compact(0) == "0")
    }
}
