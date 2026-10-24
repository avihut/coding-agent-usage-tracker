import Foundation
import Testing
@testable import UsageCore

/// The engine's transcript-scan spacing: at most one scan a minute, and a
/// write inside that minute is owed a catch-up — never dropped, which is
/// what left a live transcript unscanned for five minutes on 2026-10-23.
@Suite("Activity scan throttle")
struct ActivityScanThrottleTests {
    private let t0 = Date(timeIntervalSince1970: 1_792_740_000)

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    @Test("the first reason scans; a write inside the minute schedules one catch-up at its end")
    func writeInsideTheSpacingIsOwed() {
        var throttle = ActivityScanThrottle()
        #expect(throttle.request(at: at(0)) == .scan)
        #expect(throttle.finish(at: at(3)) == .nothing)
        // The final write of a turn, 21 s after the scan: owed, not dropped.
        #expect(throttle.request(at: at(21)) == .schedule(at(60)))
        // More writes in the same minute ride the same catch-up.
        #expect(throttle.request(at: at(40)) == .nothing)
        #expect(throttle.request(at: at(55)) == .nothing)
        #expect(throttle.catchUpDue(at: at(60)) == .scan)
        #expect(throttle.lastStart == at(60))
        #expect(throttle.finish(at: at(62)) == .nothing)
    }

    @Test("a write while a scan runs gets one catch-up after it, spaced from the scan's start")
    func writeDuringAScanIsOwed() {
        var throttle = ActivityScanThrottle()
        #expect(throttle.request(at: at(0)) == .scan)
        #expect(throttle.request(at: at(5)) == .nothing)
        #expect(throttle.finish(at: at(8)) == .schedule(at(60)))
        #expect(throttle.catchUpDue(at: at(60)) == .scan)
    }

    @Test("a scan that outlasts the spacing schedules its catch-up for when it lands")
    func longScanCatchesUpAtOnce() {
        var throttle = ActivityScanThrottle()
        #expect(throttle.request(at: at(0)) == .scan)
        #expect(throttle.request(at: at(30)) == .nothing)
        #expect(throttle.finish(at: at(75)) == .schedule(at(75)))
    }

    @Test("nothing owed, nothing scheduled: a quiet minute costs no scan")
    func quietMinuteSchedulesNothing() {
        var throttle = ActivityScanThrottle()
        #expect(throttle.request(at: at(0)) == .scan)
        #expect(throttle.finish(at: at(2)) == .nothing)
        #expect(throttle.catchUpAt == nil)
        // A write after the spacing scans directly.
        #expect(throttle.request(at: at(61)) == .scan)
    }

    @Test("a forced rescan never waits out the spacing — not even behind a scan in flight")
    func forcedRescans() {
        var throttle = ActivityScanThrottle()
        #expect(throttle.request(at: at(0)) == .scan)
        #expect(throttle.finish(at: at(1)) == .nothing)
        #expect(throttle.request(at: at(10), force: true) == .scan)
        #expect(throttle.request(at: at(11), force: true) == .nothing)
        #expect(throttle.finish(at: at(14)) == .schedule(at(14)))
        #expect(throttle.catchUpDue(at: at(14)) == .scan)
    }

    @Test("a catch-up that comes due with nothing owed does nothing")
    func staleCatchUpIsHarmless() {
        var throttle = ActivityScanThrottle()
        #expect(throttle.request(at: at(0)) == .scan)
        #expect(throttle.finish(at: at(1)) == .nothing)
        #expect(throttle.catchUpDue(at: at(60)) == .nothing)
    }
}
