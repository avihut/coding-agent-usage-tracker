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

    @Test("aggregates per day, sums all token kinds, dedups repeated requestIds")
    func aggregates() throws {
        let (scanner, root) = try makeScanner()
        try Self.transcript.write(to: root.appending(path: "a.jsonl"), atomically: true, encoding: .utf8)

        let activity = scanner.scan()

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

        let first = scanner.scan()
        let second = scanner.scan()
        #expect(first == second)
    }

    @Test("modified files are re-parsed")
    func modifiedFile() throws {
        let (scanner, root) = try makeScanner()
        let file = root.appending(path: "a.jsonl")
        try Self.transcript.write(to: file, atomically: true, encoding: .utf8)
        _ = scanner.scan()

        let extra = Self.transcript + "\n" +
            #"{"timestamp":"2026-08-03T08:00:00.000Z","requestId":"r9","message":{"id":"m9","usage":{"input_tokens":10,"output_tokens":5}}}"#
        try extra.write(to: file, atomically: true, encoding: .utf8)

        let activity = scanner.scan()
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
        #expect(scanner.scan().isEmpty)
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
