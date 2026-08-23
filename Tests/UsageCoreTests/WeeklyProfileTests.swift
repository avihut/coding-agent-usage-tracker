import Foundation
import Testing
@testable import UsageCore

@Suite("WeeklyProfile")
struct WeeklyProfileTests {
    static let gmt: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar
    }()

    /// Monday 1970-01-12 00:00 GMT plus whole days and (fractional) hours.
    static func at(_ day: Int, _ hour: Double) -> Date {
        Date(timeIntervalSince1970: 950_400 + Double(day) * 86400 + hour * 3600)
    }

    static func sample(
        _ t: Date, _ percent: Int, reset: Date? = nil, label: String = "W"
    ) -> UsageSample {
        UsageSample(
            t: t, percents: [label: percent],
            resets: reset.map { [label: $0] })
    }

    /// A uniform 2%/h profile for exercising the pure math paths.
    static func uniformProfile(spanDays: Double = 15) -> WeeklyProfile {
        WeeklyProfile(
            rates: [Double](repeating: 2, count: WeeklyProfile.bucketCount),
            observedHours: [Double](repeating: 12, count: WeeklyProfile.bucketCount),
            globalRatePerHour: 2, historySpan: spanDays * 86400, pairCount: 100,
            calendar: gmt)
    }

    @Test("consumption splits across the 4-hour blocks a pair spans")
    func attribution() {
        // Monday 10:00→14:00 gains 10% (blocks 08–12 and 12–16, 2h each);
        // Thursday 15:00→17:00 gains nothing; the 3-day gap between the two
        // pairs is dropped rather than smeared.
        let samples = [
            Self.sample(Self.at(0, 10), 10), Self.sample(Self.at(0, 14), 20),
            Self.sample(Self.at(3, 15), 20), Self.sample(Self.at(3, 17), 20),
        ]
        let profile = WeeklyProfile.build(samples: samples, label: "W", calendar: Self.gmt)
        #expect(profile != nil)
        guard let profile else { return }

        #expect(profile.pairCount == 2)
        // Monday buckets: weekday 2 → day index 1; blocks 2 and 3.
        #expect(profile.observedHours[8] == 2)
        #expect(profile.observedHours[9] == 2)
        // Thursday 12–16 and 16–20 saw one quiet hour each.
        #expect(profile.observedHours[27] == 1)
        #expect(profile.observedHours[28] == 1)
        #expect(abs(profile.globalRatePerHour - 10.0 / 6) < 0.0001)
        // Burning blocks sit above the global mean, quiet ones below.
        #expect(profile.rates[8] > profile.globalRatePerHour)
        #expect(profile.rates[27] < profile.globalRatePerHour)
        #expect(abs(profile.rates[8] - (5 + 8 * 10.0 / 6) / 10) < 0.0001)
        #expect(!profile.isReady)
        #expect(profile.remainingUntilReady > 0)
    }

    @Test("drops, moved resets, and long gaps teach nothing")
    func skippedPairs() {
        // A percent drop is a window rollover, not negative consumption.
        #expect(WeeklyProfile.build(
            samples: [Self.sample(Self.at(0, 10), 50), Self.sample(Self.at(0, 11), 10)],
            label: "W", calendar: Self.gmt) == nil)
        // A moved reset between two reads means the delta spans windows.
        let resetA = Self.at(2, 0)
        let resetB = Self.at(9, 0)
        #expect(WeeklyProfile.build(
            samples: [
                Self.sample(Self.at(0, 10), 10, reset: resetA),
                Self.sample(Self.at(0, 11), 20, reset: resetB),
            ],
            label: "W", calendar: Self.gmt) == nil)
        // A three-day gap can't inform hour-of-week structure.
        #expect(WeeklyProfile.build(
            samples: [Self.sample(Self.at(0, 10), 10), Self.sample(Self.at(3, 10), 40)],
            label: "W", calendar: Self.gmt) == nil)
        // But a valid pair beside a skipped one still builds.
        let mixed = WeeklyProfile.build(
            samples: [
                Self.sample(Self.at(0, 10), 50),
                Self.sample(Self.at(0, 11), 10),
                Self.sample(Self.at(0, 12), 12),
            ],
            label: "W", calendar: Self.gmt)
        #expect(mixed?.pairCount == 1)
        #expect(mixed?.observedHours.reduce(0, +) == 1)
    }

    @Test("sub-second reset jitter never drops a pair — the field failure mode")
    func jitteredResets() {
        // The API restates the same boundary with ±0.5s noise on every
        // poll; comparing stamps exactly dropped 92% of a fortnight's
        // pairs, leaving the prior's flat line as the whole profile.
        let boundary = Self.at(6, 22)
        let samples = [
            Self.sample(Self.at(0, 10), 10, reset: boundary.addingTimeInterval(-0.492)),
            Self.sample(Self.at(0, 11), 20, reset: boundary.addingTimeInterval(0.437)),
            Self.sample(Self.at(0, 12), 24, reset: boundary.addingTimeInterval(-0.113)),
        ]
        let profile = WeeklyProfile.build(samples: samples, label: "W", calendar: Self.gmt)
        #expect(profile?.pairCount == 2)
        #expect(profile?.observedHours.reduce(0, +) == 2)
    }

    @Test("expected percent integrates the rate across block boundaries")
    func expectedPercent() {
        let profile = Self.uniformProfile()
        // 10:00→15:00 crosses the 12:00 boundary: 5h × 2%/h.
        #expect(abs(profile.expectedPercent(
            from: Self.at(0, 10), to: Self.at(0, 15)) - 10) < 0.0001)
        // Across the week boundary too: Saturday 22:00 → Sunday 04:00.
        #expect(abs(profile.expectedPercent(
            from: Self.at(5, 22), to: Self.at(6, 4)) - 12) < 0.0001)
        #expect(profile.expectedPercent(from: Self.at(0, 10), to: Self.at(0, 10)) == 0)
    }

    @Test("pace factor compares actual to typical, shrunk and clamped")
    func paceFactor() {
        let profile = Self.uniformProfile()
        let now = Self.at(0, 10)
        let windowStart = now.addingTimeInterval(-10 * 3600) // expected 20%
        #expect(abs(profile.paceFactor(percent: 10, windowStart: windowStart, now: now) - 0.6) < 0.0001)
        #expect(abs(profile.paceFactor(percent: 60, windowStart: windowStart, now: now) - 2.6) < 0.0001)
        // A window that just reset divides shrink by shrink — pace 1.
        #expect(profile.paceFactor(percent: 0, windowStart: now, now: now) == 1)
        // And an absurd ratio clamps rather than exploding the forecast.
        #expect(profile.paceFactor(percent: 100, windowStart: now, now: now) == 4)
    }

    @Test("weekday shares sum to one and follow the burn")
    func weekdayShares() {
        let uniform = Self.uniformProfile()
        #expect(abs(uniform.weekdayShares().reduce(0, +) - 1) < 0.0001)
        #expect(uniform.weekdayShares().allSatisfy { abs($0 - 1.0 / 7) < 0.0001 })

        var rates = [Double](repeating: 0, count: WeeklyProfile.bucketCount)
        for block in 6..<12 { rates[block] = 4 } // Monday only
        let mondays = WeeklyProfile(
            rates: rates, observedHours: rates, globalRatePerHour: 1,
            historySpan: 15 * 86400, pairCount: 10, calendar: Self.gmt)
        let shares = mondays.weekdayShares()
        #expect(abs(shares[1] - 1) < 0.0001)
        #expect(shares[0] == 0)
        #expect(shares[6] == 0)
    }

    @Test("readiness gates on two weeks of history span")
    func readiness() {
        #expect(!Self.uniformProfile(spanDays: 10).isReady)
        #expect(Self.uniformProfile(spanDays: 10).remainingUntilReady == 4 * 86400)
        #expect(Self.uniformProfile(spanDays: 15).isReady)
        #expect(Self.uniformProfile(spanDays: 15).remainingUntilReady == 0)
    }

    @Test("bucket index and block boundaries are weekday-absolute")
    func buckets() {
        // Thursday 1970-01-01 00:30 GMT: weekday 5, block 0 → bucket 24.
        let thursday = Date(timeIntervalSince1970: 1800)
        #expect(WeeklyProfile.bucketIndex(for: thursday, calendar: Self.gmt) == 24)
        #expect(WeeklyProfile.blockEnd(after: thursday, calendar: Self.gmt)
            == Date(timeIntervalSince1970: 14400))
        // Exactly on a boundary advances to the NEXT boundary.
        let boundary = Date(timeIntervalSince1970: 14400)
        #expect(WeeklyProfile.blockEnd(after: boundary, calendar: Self.gmt)
            == Date(timeIntervalSince1970: 28800))
        // Monday 10:00 → day index 1, block 2 → bucket 8.
        #expect(WeeklyProfile.bucketIndex(for: Self.at(0, 10), calendar: Self.gmt) == 8)
    }
}
