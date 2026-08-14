import Foundation
import Testing

@testable import UsageCore

@Suite("ActivityGrace stitching")
struct ActivityGraceStitchTests {
    private func interval(_ start: TimeInterval, _ end: TimeInterval) -> DateInterval {
        DateInterval(
            start: Date(timeIntervalSinceReferenceDate: start),
            end: Date(timeIntervalSinceReferenceDate: end))
    }

    @Test("empty input stays empty")
    func empty() {
        #expect(ActivityGrace.stitch([], grace: 900).isEmpty)
    }

    @Test("a gap within grace merges into one stretch")
    func merges() {
        let stitched = ActivityGrace.stitch(
            [interval(0, 600), interval(1200, 1800)], grace: 900)
        #expect(stitched == [interval(0, 1800)])
    }

    @Test("a gap beyond grace stays split")
    func staysSplit() {
        let stretches = [interval(0, 600), interval(1600, 1800)]
        #expect(ActivityGrace.stitch(stretches, grace: 900) == stretches)
    }

    @Test("a gap of exactly grace merges — the boundary is inclusive")
    func boundary() {
        let stitched = ActivityGrace.stitch(
            [interval(0, 600), interval(1500, 1800)], grace: 900)
        #expect(stitched == [interval(0, 1800)])
    }

    @Test("chained short gaps collapse to a single session")
    func chains() {
        let stitched = ActivityGrace.stitch(
            [interval(0, 300), interval(500, 800), interval(1000, 1300)], grace: 300)
        #expect(stitched == [interval(0, 1300)])
    }

    @Test("zero grace preserves every stretch")
    func zeroGrace() {
        let stretches = [interval(0, 300), interval(400, 800), interval(900, 1300)]
        #expect(ActivityGrace.stitch(stretches, grace: 0) == stretches)
    }

    @Test("touching stretches merge even at zero grace")
    func touching() {
        let stitched = ActivityGrace.stitch(
            [interval(0, 300), interval(300, 600)], grace: 0)
        #expect(stitched == [interval(0, 600)])
    }
}

@Suite("ActivityGrace live tail")
struct ActivityGraceHoldOpenTests {
    private func interval(_ start: TimeInterval, _ end: TimeInterval) -> DateInterval {
        DateInterval(
            start: Date(timeIntervalSinceReferenceDate: start),
            end: Date(timeIntervalSinceReferenceDate: end))
    }

    private func date(_ t: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: t)
    }

    @Test("an idle gap within grace holds the newest stretch open to now")
    func holds() {
        let held = ActivityGrace.holdOpen(
            [interval(0, 600), interval(1200, 1800)], until: date(2280), grace: 900)
        #expect(held == [interval(0, 600), interval(1200, 2280)])
    }

    @Test("a gap of exactly grace still holds — the boundary is inclusive")
    func boundary() {
        let held = ActivityGrace.holdOpen([interval(0, 600)], until: date(1500), grace: 900)
        #expect(held == [interval(0, 1500)])
    }

    @Test("once the gap outgrows grace the stretch shows its true end")
    func releases() {
        let stretches = [interval(0, 600)]
        #expect(ActivityGrace.holdOpen(stretches, until: date(1501), grace: 900) == stretches)
    }

    @Test("zero grace never holds")
    func zeroGrace() {
        let stretches = [interval(0, 600)]
        #expect(ActivityGrace.holdOpen(stretches, until: date(601), grace: 0) == stretches)
    }

    @Test("a stretch already reaching or passing now is left alone")
    func alreadyLive() {
        let stretches = [interval(0, 600)]
        #expect(ActivityGrace.holdOpen(stretches, until: date(600), grace: 900) == stretches)
        #expect(ActivityGrace.holdOpen(stretches, until: date(300), grace: 900) == stretches)
    }

    @Test("empty input stays empty")
    func empty() {
        #expect(ActivityGrace.holdOpen([], until: date(0), grace: 900).isEmpty)
    }
}

@Suite("ActivityGraceScale")
struct ActivityGraceScaleTests {
    @Test("zero sits at the left stop and round-trips")
    func zeroStop() {
        #expect(ActivityGraceScale.position(of: 0) == 0)
        #expect(ActivityGraceScale.value(at: 0) == 0)
    }

    @Test("the dead zone left of the log start collapses to 0")
    func deadZone() {
        #expect(ActivityGraceScale.value(at: 0.04) == 0)
    }

    @Test("every mark round-trips exactly")
    func marksRoundTrip() {
        for mark in ActivityGraceScale.marks {
            let p = ActivityGraceScale.position(of: mark)
            #expect(ActivityGraceScale.value(at: p) == mark)
        }
    }

    @Test("positions just off a mark snap onto it")
    func snapping() {
        let nearFifteen = ActivityGraceScale.position(of: 900) + 0.02
        #expect(ActivityGraceScale.value(at: nearFifteen) == 900)
    }

    @Test("between marks the value rounds to whole minutes")
    func minuteRounding() {
        let p = (ActivityGraceScale.position(of: 300) + ActivityGraceScale.position(of: 900)) / 2
        let value = ActivityGraceScale.value(at: p)
        #expect(value.truncatingRemainder(dividingBy: 60) == 0)
        #expect(value > 300 && value < 900)
    }

    @Test("positions are monotonic across the whole range")
    func monotonic() {
        let values: [Double] = [0, 60, 120, 300, 900, 1800, 3600]
        let positions = values.map(ActivityGraceScale.position(of:))
        #expect(positions == positions.sorted())
        #expect(positions.dropFirst().allSatisfy { $0 > 0 })
    }

    @Test("out-of-range input clamps to the endpoints")
    func clamping() {
        #expect(ActivityGraceScale.position(of: 7200) == 1)
        #expect(ActivityGraceScale.value(at: 1.5) == 3600)
        #expect(ActivityGraceScale.value(at: -0.5) == 0)
    }
}
