import Foundation
import Testing
@testable import UsageCore

private func fixtureData(_ name: String) -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    return try! Data(contentsOf: url)
}

private func metersFromFixture(_ name: String) throws -> [Meter] {
    try MeterBuilder.meters(from: UsageResponse.decode(from: fixtureData(name)))
}

@Suite("Response decoding")
struct ResponseDecodingTests {
    @Test("nominal fixture decodes")
    func nominal() throws {
        let response = try UsageResponse.decode(from: fixtureData("nominal"))
        #expect(response.limits?.count == 3)
        #expect(response.spend?.enabled == true)
    }

    @Test("real captured payload decodes, including microsecond timestamps")
    func realPayload() throws {
        let response = try UsageResponse.decode(from: fixtureData("real-2026-08-07"))
        #expect(response.limits?.count == 3)
        #expect(response.spend?.enabled == false)
        let first = try #require(response.limits?.first)
        #expect(first.percent == 6.0)
        #expect(first.resetsAt != nil)
    }

    @Test("malformed JSON throws (mapped to .schema at the client layer)")
    func malformed() {
        #expect(throws: (any Error).self) {
            try UsageResponse.decode(from: fixtureData("malformed"))
        }
    }

    @Test("empty limits decodes to an empty array")
    func emptyLimits() throws {
        let response = try UsageResponse.decode(from: fixtureData("empty-limits"))
        #expect(response.limits?.isEmpty == true)
        #expect(response.spend == nil)
    }
}

@Suite("MeterBuilder")
struct MeterBuilderTests {
    @Test("nominal: labels, order, percents, levels")
    func nominal() throws {
        let meters = try metersFromFixture("nominal")
        #expect(meters.map(\.label) == ["Session (5h)", "Weekly · all models", "Weekly · Fable"])
        #expect(meters.map(\.percent) == [12, 34, 56])
        #expect(meters.allSatisfy { $0.level == .normal })
        #expect(meters.allSatisfy { $0.resetsAt != nil })
    }

    @Test("custom thresholds re-classify the same percents")
    func customThresholds() throws {
        let response = try UsageResponse.decode(from: fixtureData("nominal"))
        let meters = MeterBuilder.meters(
            from: response, thresholds: Thresholds(warningPercent: 30, criticalPercent: 50))
        #expect(meters.map(\.level) == [.normal, .warning, .critical])
        let rebuilt = Snapshot(response: response, fetchedAt: Date())
            .rebuilt(thresholds: Thresholds(warningPercent: 30, criticalPercent: 50))
        #expect(rebuilt.meters.map(\.level) == [.normal, .warning, .critical])
    }

    @Test("nominal: menu bar summary")
    func nominalSummary() throws {
        let summary = MeterBuilder.menuBarSummary(from: try metersFromFixture("nominal"))
        #expect(summary == MenuBarSummary(session: 12, weeklyAll: 34, scopedMax: 56, worstLevel: .normal))
    }

    @Test("nominal: enabled spend renders a line")
    func nominalSpend() throws {
        let response = try UsageResponse.decode(from: fixtureData("nominal"))
        let line = try #require(MeterBuilder.spendLine(from: response))
        #expect(line.formatted == "$0.00 of $50.00")
    }

    @Test("real payload: 6/17/22 and no spend line (credits disabled)")
    func realPayload() throws {
        let response = try UsageResponse.decode(from: fixtureData("real-2026-08-07"))
        let meters = MeterBuilder.meters(from: response)
        #expect(meters.map(\.percent) == [6, 17, 22])
        #expect(meters.map(\.label) == ["Session (5h)", "Weekly · all models", "Weekly · Fable"])
        let summary = MeterBuilder.menuBarSummary(from: meters)
        #expect(summary == MenuBarSummary(session: 6, weeklyAll: 17, scopedMax: 22, worstLevel: .normal))
        #expect(MeterBuilder.spendLine(from: response) == nil)
    }

    @Test("high percentages cross the warning/critical thresholds")
    func allHigh() throws {
        let meters = try metersFromFixture("all-high")
        #expect(meters.map(\.level) == [.warning, .critical, .critical])
        #expect(MeterBuilder.menuBarSummary(from: meters).worstLevel == .critical)
    }

    @Test("non-normal severity forces warning even at low percent; percent can still escalate")
    func severityForced() throws {
        let meters = try metersFromFixture("severity-elevated")
        #expect(meters[0].percent == 10)
        #expect(meters[0].level == .warning)
        #expect(meters[1].percent == 95)
        #expect(meters[1].level == .critical)
    }

    @Test("missing spend produces no spend line")
    func missingSpend() throws {
        let response = try UsageResponse.decode(from: fixtureData("missing-spend"))
        #expect(MeterBuilder.spendLine(from: response) == nil)
    }

    @Test("unknown kinds: generic labels at rank 2, response order kept, missing percent tolerated")
    func unknownKinds() throws {
        let meters = try metersFromFixture("unknown-kind")
        #expect(meters.map(\.label) == ["Session (5h)", "Weekly · Fable", "Lunar Lease", "Unknown limit"])
        #expect(meters[0].percent == nil)
        let summary = MeterBuilder.menuBarSummary(from: meters)
        #expect(summary.session == nil)
        #expect(summary.weeklyAll == nil)
        #expect(summary.scopedMax == 63)
    }

    @Test("percent is clamped and rounded")
    func clamping() {
        func percent(_ value: Double) -> Int? {
            let limit = UsageLimit(kind: "session", percent: value, severity: "normal", resetsAt: nil, scope: nil)
            return MeterBuilder.meters(from: UsageResponse(limits: [limit], spend: nil)).first?.percent
        }
        #expect(percent(150) == 100)
        #expect(percent(-5) == 0)
        #expect(percent(55.6) == 56)
    }

    @Test("spend line formatting: no limit, non-USD currency")
    func spendFormatting() {
        let unlimited = SpendLine(usedMinor: 150, limitMinor: nil, currency: "EUR", exponent: 2)
        #expect(unlimited.formatted == "EUR 1.50")
        let capped = SpendLine(usedMinor: 1234, limitMinor: 5000, currency: "USD", exponent: 2)
        #expect(capped.formatted == "$12.34 of $50.00")
    }
}
