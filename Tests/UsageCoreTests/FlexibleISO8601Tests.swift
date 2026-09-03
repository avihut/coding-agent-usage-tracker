import Foundation
import Testing
@testable import UsageCore

@Suite("Flexible ISO-8601 parsing")
struct FlexibleISO8601Tests {
    @Test("live API shape: six fractional digits + numeric offset")
    func microsecondsWithOffset() throws {
        let date = try #require(FlexibleISO8601.date(from: "1970-01-01T00:00:01.500000+00:00"))
        #expect(abs(date.timeIntervalSince1970 - 1.5) < 0.001)
    }

    @Test("three fractional digits with Z")
    func millisecondsZulu() throws {
        let date = try #require(FlexibleISO8601.date(from: "1970-01-01T00:00:01.500Z"))
        #expect(abs(date.timeIntervalSince1970 - 1.5) < 0.001)
    }

    @Test("no fraction with Z")
    func plainZulu() throws {
        let date = try #require(FlexibleISO8601.date(from: "2030-01-01T12:00:00Z"))
        #expect(date.timeIntervalSince1970 == 1_893_499_200)
    }

    @Test("no fraction with numeric offset")
    func plainOffset() throws {
        let date = try #require(FlexibleISO8601.date(from: "2030-01-01T12:00:00+00:00"))
        #expect(date.timeIntervalSince1970 == 1_893_499_200)
    }

    @Test("non-UTC offset resolves to the same instant")
    func nonUTCOffset() throws {
        let date = try #require(FlexibleISO8601.date(from: "2030-01-01T14:00:00+02:00"))
        #expect(date.timeIntervalSince1970 == 1_893_499_200)
    }

    @Test("garbage returns nil")
    func garbage() {
        #expect(FlexibleISO8601.date(from: "not-a-date") == nil)
        #expect(FlexibleISO8601.date(from: "") == nil)
        #expect(FlexibleISO8601.fastPath("2030-13-01T12:00:00Z") == nil)
        #expect(FlexibleISO8601.fastPath("2030-01-01T12:00:00") == nil)
        #expect(FlexibleISO8601.fastPath("2030-01-01T12:00:00.Z") == nil)
        #expect(FlexibleISO8601.fastPath("2030-01-01T12:00:00Zjunk") == nil)
        #expect(FlexibleISO8601.fastPath("1999-12-31T23:59:60Z") == nil)  // as the formatters
    }

    /// The hand-rolled fast path answers every shape the corpus and the API
    /// use, and agrees with the formatters to well under a millisecond (the
    /// formatters themselves round sub-millisecond fractions) — the
    /// formatters are the reference, the arithmetic the speed.
    @Test("fast path matches the formatter path on every shape it accepts")
    func fastPathAgreesWithFormatters() throws {
        let shapes = [
            "2026-08-07T10:39:59.137024+00:00",  // live API
            "2026-08-01T10:01:00.000Z",          // transcripts
            "2026-08-01T10:01:00Z",
            "2030-01-01T14:00:00+02:00",
            "2030-01-01T14:00:00-0530",
            "2024-02-29T23:59:59.9Z",            // leap day, one fractional digit
            "1999-12-31T23:59:59Z",
            "2000-03-01T00:00:00.5-00:00",
        ]
        for shape in shapes {
            let fast = try #require(FlexibleISO8601.fastPath(shape), "fast path rejected \(shape)")
            let slow = try #require(FlexibleISO8601.slowPath(shape), "formatters rejected \(shape)")
            #expect(abs(fast.timeIntervalSince(slow)) < 0.001, "\(shape)")
        }
    }

    /// The whole point: a corpus line must not cost a formatter allocation.
    @Test("the fast path parses a transcript line in microseconds")
    func fastPathIsFast() {
        let line = "2026-08-01T10:01:00.000Z"
        let start = Date()
        var hits = 0
        for _ in 0..<20_000 where FlexibleISO8601.date(from: line) != nil { hits += 1 }
        let elapsed = Date().timeIntervalSince(start)
        #expect(hits == 20_000)
        #expect(elapsed < 0.5, "20k parses took \(elapsed)s")
    }
}
