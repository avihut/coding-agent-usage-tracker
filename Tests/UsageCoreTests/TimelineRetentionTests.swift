import Foundation
import Testing
@testable import UsageCore

/// The per-minute slot timeline reaches as far back as the percent samples,
/// and a cache written under a shorter retention backfills on its own.
@Suite("Timeline retention")
struct TimelineRetentionTests {
    private struct Fixture {
        let scanner: TranscriptScanner
        let projectRoot: URL
        private let base: URL

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appending(path: "timeline-retention-tests-\(UUID().uuidString)")
            projectRoot = base.appending(path: "projects/demo")
            try FileManager.default.createDirectory(
                at: projectRoot, withIntermediateDirectories: true)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            scanner = TranscriptScanner(
                root: base.appending(path: "projects"),
                cacheDirectory: base.appending(path: "cache"),
                calendar: calendar)
        }

        func write(_ name: String, _ content: String) throws {
            try content.write(
                to: projectRoot.appending(path: name), atomically: true, encoding: .utf8)
        }

        func tearDown() { try? FileManager.default.removeItem(at: base) }
    }

    private func at(_ iso: String) -> Date { FlexibleISO8601.date(from: iso)! }

    private let transcript = """
    {"type":"assistant","timestamp":"2026-08-01T10:01:00.000Z","requestId":"r1","message":{"id":"m1","model":"claude-fable-5","usage":{"input_tokens":100,"output_tokens":50},"content":[{"type":"text","text":"working"}]}}
    {"type":"assistant","timestamp":"2026-08-01T10:02:00.000Z","requestId":"r2","message":{"id":"m2","model":"claude-fable-5","usage":{"input_tokens":200,"output_tokens":80},"content":[{"type":"text","text":"done"}]}}

    """

    /// Retention matches the sample history, so a window seven weeks back
    /// still has its model curves.
    @Test func retentionMatchesTheSampleHistory() {
        #expect(TranscriptScanner.timelineRetention == 56 * 86400)
    }

    /// Slots inside the retention survive; a scan whose cutoff has moved
    /// past them trims them — and a later scan under a cutoff that wants
    /// them back re-parses the UNCHANGED file to restore them, instead of
    /// waiting for a finished transcript to change (it never will).
    @Test func trimmedSlotsBackfillWhenRetentionReachesThemAgain() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.write("S.jsonl", transcript)

        let fresh = fixture.scanner.scan(now: at("2026-08-03T00:00:00.000Z"))
        #expect(fresh.timeline.count == 2)

        // A cutoff far past the activity: the cache entry keeps its days
        // but sheds every slot.
        let trimmed = fixture.scanner.scan(now: at("2027-06-01T00:00:00.000Z"))
        #expect(trimmed.timeline.isEmpty)
        #expect(trimmed.daily.reduce(0) { $0 + $1.messages } == 2)

        // Back under a cutoff that covers the activity — same file, same
        // mtime and size — the slots return.
        let restored = fixture.scanner.scan(now: at("2026-08-03T00:00:00.000Z"))
        #expect(restored.timeline.count == 2)
        #expect(restored.timeline.map(\.tally.total).reduce(0, +) == 430)
    }
}
