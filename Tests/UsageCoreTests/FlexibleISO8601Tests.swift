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
    }
}
