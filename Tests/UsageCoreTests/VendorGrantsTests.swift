import Foundation
import Testing

@testable import UsageCore

@Suite("Vendor grants")
struct VendorGrantsTests {
    private let session = "Session"
    private let weekly = "Weekly"

    private func at(_ hours: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: hours * 3600)
    }

    /// 2026-09-04's shape: the session window had closed at its own boundary
    /// and sat at zero; the weekly meter fell 30 → 0 under one window end.
    private var samples: [UsageSample] {
        [
            UsageSample(
                t: at(1), percents: [session: 40, weekly: 30],
                resets: [session: at(2), weekly: at(100)]),
            UsageSample(
                t: at(3), percents: [session: 0, weekly: 30],
                resets: [session: at(8), weekly: at(100)]),
            // The stampless zeroed poll the API actually sent.
            UsageSample(t: at(5), percents: [session: 0, weekly: 0], resets: nil),
            UsageSample(
                t: at(6), percents: [session: 2, weekly: 1],
                resets: [session: at(11), weekly: at(100)]),
        ]
    }

    @Test func aSiblingMetersGrantIsMarkedOnAMeterAlreadyAtZero() {
        let grants = VendorGrants.observed(samples: samples, for: session, through: at(10))
        #expect(grants.count == 1)
        #expect(grants.first?.at == at(4))
        #expect(grants.first?.kind == .midWindow)
        // Voiced for the chart it lands on: the session stood at 0.
        #expect(grants.first?.from == 0)
    }

    @Test func theCatchingMetersOwnCliffIsNotItsForeignGrant() {
        // Only the weekly dropped; excluding it leaves the session's samples,
        // which never emptied from a height.
        let grants = VendorGrants.observed(samples: samples, for: weekly, through: at(10))
        #expect(grants.isEmpty)
    }

    @Test func nothingPastTheMeasuredEndCounts() {
        #expect(VendorGrants.observed(samples: samples, for: session, through: at(3)).isEmpty)
    }

    @Test func twoMetersDroppingTogetherNameOneEvent() {
        var both = samples
        both[1] = UsageSample(
            t: at(3), percents: [session: 40, weekly: 30],
            resets: [session: at(8), weekly: at(100)])
        // A third meter caught the same instant: still one grant for the
        // session chart.
        let scoped = "Weekly (Fable)"
        let widened = both.map { sample in
            UsageSample(
                t: sample.t,
                percents: sample.percents.merging([scoped: sample.percents[weekly] ?? 0]) { a, _ in a },
                resets: sample.resets.map { $0.merging([scoped: $0[weekly] ?? at(100)]) { a, _ in a } })
        }
        let grants = VendorGrants.observed(samples: widened, for: session, through: at(10))
        #expect(grants.map(\.at) == [at(4)])
        #expect(grants.first?.from == 40)
    }

    @Test func unionPrefersTheMetersOwnReading() {
        let own = [ResetCliffs.Cliff(at: at(4), from: 40, kind: .midWindow)]
        let foreign = [
            ResetCliffs.Cliff(at: at(4).addingTimeInterval(30), from: 0, kind: .midWindow),
            ResetCliffs.Cliff(at: at(20), from: 0, kind: .midWindow),
        ]
        let merged = VendorGrants.union(own: own, foreign: foreign)
        #expect(merged == [own[0], foreign[1]])
    }

    @Test func theAuditModelCarriesASiblingsGrant() {
        let model = AuditWindow.build(
            domain: DateInterval(start: at(0), end: at(24)), meterLabel: session,
            window: 5 * 3600, samples: samples, sessions: [], outcomes: [], now: at(30))
        #expect(model.midWindowResets.map(\.at) == [at(4)])
        #expect(model.midWindowResets.first?.from == 0)
    }
}
