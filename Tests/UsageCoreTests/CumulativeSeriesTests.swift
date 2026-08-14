import Foundation
import Testing

@testable import UsageCore

@Suite("CumulativeSeries")
struct CumulativeSeriesTests {
    private func date(_ t: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: t)
    }

    // A day-long domain with 180 buckets → 480s buckets.
    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private let end = Date(timeIntervalSinceReferenceDate: 86400)

    @Test("an idle gap holds flat — no phantom ramp across quiet stretches")
    func idleGapHoldsFlat() {
        // Activity in the first hour, then nothing until the last hour.
        let moments = [
            (t: date(600), amount: 100), (t: date(1200), amount: 50),
            (t: date(82800), amount: 25),
        ]
        let curve = CumulativeSeries.build(moments: moments, start: start, end: end)
        // A hold point must carry the pre-gap total to just before the
        // late activity's bucket, keeping the whole gap flat.
        let resume = curve.last { $0.total == 150 }
        #expect(resume != nil)
        #expect((resume?.t.timeIntervalSinceReferenceDate ?? 0) >= 82800 - 480)
        // And every point across the gap sits at 150 — nothing rises.
        for point in curve where point.t > date(1200) && point.t < date(82320) {
            #expect(point.total == 150)
        }
    }

    @Test("a leading idle stretch stays at zero until activity begins")
    func leadingIdleFlat() {
        let moments = [(t: date(82800), amount: 40)]
        let curve = CumulativeSeries.build(moments: moments, start: start, end: end)
        let lastZero = curve.last { $0.total == 0 }
        #expect((lastZero?.t.timeIntervalSinceReferenceDate ?? -1) >= 82800 - 480)
        #expect(curve.first == CumulativePoint(t: start, total: 0))
    }

    @Test("a trailing idle stretch keeps the final total flat to the end")
    func trailingIdleFlat() {
        let moments = [(t: date(600), amount: 70)]
        let curve = CumulativeSeries.build(moments: moments, start: start, end: end)
        #expect(curve.last == CumulativePoint(t: end, total: 70))
    }

    @Test("contiguous activity accumulates without duplicate hold points")
    func contiguous() {
        // A moment every minute for the first two hours.
        let moments = (0..<120).map { (t: date(Double($0) * 60), amount: 1) }
        let curve = CumulativeSeries.build(moments: moments, start: start, end: end)
        #expect(curve.last?.total == 120)
        let times = curve.map(\.t)
        #expect(times == times.sorted())
        #expect(Set(times).count == times.count)
        let totals = curve.map(\.total)
        #expect(totals == totals.sorted())
    }

    @Test("no moments draw a flat zero line")
    func empty() {
        let curve = CumulativeSeries.build(moments: [], start: start, end: end)
        #expect(curve == [
            CumulativePoint(t: start, total: 0), CumulativePoint(t: end, total: 0),
        ])
    }

    @Test("moments outside the domain are ignored")
    func outOfRange() {
        let moments = [
            (t: date(-600), amount: 10), (t: date(600), amount: 5),
            (t: date(90000), amount: 10),
        ]
        let curve = CumulativeSeries.build(moments: moments, start: start, end: end)
        #expect(curve.last?.total == 5)
    }

    @Test("a degenerate domain yields nothing")
    func degenerate() {
        #expect(CumulativeSeries.build(moments: [], start: start, end: start).isEmpty)
    }
}
