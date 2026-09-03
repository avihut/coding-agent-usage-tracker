import Foundation
import Testing

@testable import UsageCore

@Suite("Model curves")
struct ModelCurvesTests {
    private func at(_ hours: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: hours * 3600)
    }

    /// The anchor counts only what the span GAINED. A sawtooth that rose 60,
    /// reset to 0, then rose 40 has bought 100 percent's worth of tokens —
    /// summing raw deltas would call it 40 and stretch every curve.
    @Test func theAnchorCountsGainsNotNetChange() {
        let sawtooth = [0, 60, 0, 40]
        let anchor = ModelCurves.gainsPercentPerToken(percents: sawtooth, tokens: 1_000)

        #expect(anchor == 0.1)
    }

    /// No growth, or no tokens, means no honest rate — the caller falls back
    /// to a shape-only scale rather than inventing one.
    @Test func aSpanWithoutGrowthHasNoAnchor() {
        #expect(ModelCurves.gainsPercentPerToken(percents: [7, 7, 7], tokens: 1_000) == nil)
        #expect(ModelCurves.gainsPercentPerToken(percents: [0, 50], tokens: 0) == nil)
    }

    /// Curves are cumulative and monotonic, and the anchor puts them on the
    /// percent axis: 500k tokens at 0.0001 %/token stands at 50%.
    @Test func curvesAreCumulativeAndAnchoredToPercent() {
        let moments = [
            ModelCurves.Moment(model: "opus", t: at(1), amount: 250_000),
            ModelCurves.Moment(model: "opus", t: at(3), amount: 250_000),
        ]
        let curves = ModelCurves.build(
            models: ["opus"], moments: moments, start: at(0), end: at(4),
            percentPerToken: 0.0001, cap: false)

        #expect(curves.count == 1)
        let values = curves[0].points.map(\.value)
        #expect(values.first == 0)
        #expect(abs(curves[0].peak - 50) < 0.001)
        // Cumulative means it never descends.
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    /// A span holding more than one window may honestly exceed a limit, and
    /// the ceiling rises to meet it. Capped, the same data stops at 100.
    @Test func overshootSurvivesUncappedAndClampsWhenCapped() {
        let moments = [ModelCurves.Moment(model: "opus", t: at(1), amount: 2_600_000)]
        let uncapped = ModelCurves.build(
            models: ["opus"], moments: moments, start: at(0), end: at(4),
            percentPerToken: 0.0001, cap: false)
        let capped = ModelCurves.build(
            models: ["opus"], moments: moments, start: at(0), end: at(4),
            percentPerToken: 0.0001, cap: true)

        #expect(abs(uncapped[0].peak - 260) < 0.001)
        #expect(ModelCurves.ceiling(uncapped) > 259)
        #expect(capped[0].peak == 100)
        #expect(ModelCurves.ceiling(capped) == 100)
    }

    /// Without an anchor the axis stops speaking percent, but the shape is
    /// still true: the tallest curve scales to 100 and the smaller model
    /// keeps its proportion (a quarter of the tokens → a quarter as tall).
    @Test func withoutAnAnchorTheShapeIsStillHonest() {
        let moments = [
            ModelCurves.Moment(model: "opus", t: at(1), amount: 400_000),
            ModelCurves.Moment(model: "haiku", t: at(1), amount: 100_000),
        ]
        let curves = ModelCurves.build(
            models: ["opus", "haiku"], moments: moments, start: at(0), end: at(4),
            percentPerToken: nil, cap: false)

        #expect(abs((curves.first { $0.model == "opus" }?.peak ?? 0) - 100) < 0.001)
        #expect(abs((curves.first { $0.model == "haiku" }?.peak ?? 0) - 25) < 0.001)
    }

    /// A model that spent nothing in the span keeps its ENTRY (legends and
    /// colour lookups still find it) but carries no points — the plot draws
    /// nothing rather than a flat zero line pretending to be usage.
    @Test func anIdleModelKeepsItsEntryButDrawsNothing() {
        let curves = ModelCurves.build(
            models: ["opus", "haiku"],
            moments: [ModelCurves.Moment(model: "opus", t: at(1), amount: 100)],
            start: at(0), end: at(4), percentPerToken: 0.0001, cap: false)

        let idle = curves.first { $0.model == "haiku" }
        #expect(idle != nil)
        #expect(idle?.points.isEmpty == true)
        #expect(idle?.peak == 0)
    }

    /// A model adopted mid-span appears only from its first tokens: one
    /// zero at the boundary it climbs from, nothing back to the span's
    /// start — the flat leader read as "at 0 the whole time".
    @Test func aModelAdoptedMidSpanAppearsWhenItStarts() {
        let moments = [
            ModelCurves.Moment(model: "opus", t: at(0), amount: 100_000),
            ModelCurves.Moment(model: "haiku", t: at(3), amount: 100_000),
        ]
        let curves = ModelCurves.build(
            models: ["opus", "haiku"], moments: moments, start: at(0), end: at(4),
            percentPerToken: 0.0001, cap: false)

        let late = try! #require(curves.first { $0.model == "haiku" })
        #expect(late.points.first?.value == 0)
        #expect(late.points.filter { $0.value == 0 }.count == 1)
        // Its first point sits within one bucket (4h/180) of the first call.
        #expect((late.points.first?.t ?? at(0)) > at(2.9))
        #expect((late.points.first?.t ?? at(9)) <= at(3))
        // A model busy from the first bucket still starts at the span's start.
        let early = try! #require(curves.first { $0.model == "opus" })
        #expect(early.points.first?.t == at(0))
    }

    /// An empty ceiling still gives the plot a full limit to draw against.
    @Test func theCeilingNeverCollapsesBelowOneLimit() {
        #expect(ModelCurves.ceiling([]) == 100)
    }
}
