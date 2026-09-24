import Foundation
import Testing

@testable import UsageCore

/// The overshoot estimate and its captions: how much extra usage a window
/// forecast past its limit would need, priced at API list rates. Absent is
/// never zero here — a window with no token data prices nothing, and says so.
@Suite("ForecastOvershoot")
struct ForecastOvershootTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_US_POSIX")

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// Two hours of window left of a five-hour one.
    private var reset: Date { now.addingTimeInterval(2 * 3600) }
    private var windowStart: Date { reset.addingTimeInterval(-5 * 3600) }

    private func meter(
        label: String = "Session (5h)", percent: Int = 70,
        limitWindow: TimeInterval? = 5 * 3600, resetsAt: Date? = nil,
        scopedModelName: String? = nil
    ) -> Meter {
        Meter(
            id: "session", label: label, percent: percent,
            resetsAt: resetsAt ?? reset, level: .normal, rank: 0,
            limitWindow: limitWindow, scopedModelName: scopedModelName)
    }

    private func prediction(projectedUnclamped: Double?) -> UsagePrediction {
        UsagePrediction(
            ratePerHour: 15, baselineRatePerHour: nil, paceFactor: nil,
            basis: .recentOnly,
            projectedAtReset: projectedUnclamped.map { Int(min(100, $0).rounded()) },
            exhaustsAt: now.addingTimeInterval(1800),
            verdict: .red, rawVerdict: .red, severity: 1, text: "", curve: [],
            projectedUnclamped: projectedUnclamped)
    }

    /// Two samples inside the window: 0 → 70, i.e. 70 points gained
    /// (the window enters at zero) over whatever tokens the timeline holds.
    private var samples: [UsageSample] {
        [
            UsageSample(
                t: windowStart.addingTimeInterval(600),
                percents: ["Session (5h)": 20], resets: [:]),
            UsageSample(t: now, percents: ["Session (5h)": 70], resets: [:]),
        ]
    }

    /// 700,000 tokens in the window ⇒ 0.0001 percent per token, so one
    /// percentage point costs 10,000 tokens.
    private var timeline: [TokenSlot] {
        [
            TokenSlot(
                t: windowStart.addingTimeInterval(900), model: "test-model",
                tally: TokenTally(input: 400_000, output: 100_000)),
            TokenSlot(
                t: now.addingTimeInterval(-600), model: "test-model",
                tally: TokenTally(input: 150_000, output: 50_000)),
        ]
    }

    /// $1 per million input, $10 per million output — round numbers, so the
    /// blended per-token rate is exact arithmetic rather than a feed value
    /// that can be refreshed out from under the test.
    private var pricing: PricingTable {
        PricingTable(
            rates: ["test-model": ModelRates(input: 1e-6, output: 10e-6)],
            fetchedAt: now, source: .live)
    }

    private func estimate(
        prediction: UsagePrediction? = nil, meter: Meter? = nil,
        samples: [UsageSample]? = nil, timeline: [TokenSlot]? = nil,
        pricing: PricingTable? = nil
    ) -> ForecastOvershoot? {
        ForecastOvershoot.estimate(
            prediction: prediction ?? self.prediction(projectedUnclamped: 111),
            meter: meter ?? self.meter(),
            samples: samples ?? self.samples,
            timeline: timeline ?? self.timeline,
            pricing: pricing ?? self.pricing,
            now: now)
    }

    @Test("a forecast inside its limit has no overshoot")
    func cleanForecast() {
        #expect(estimate(prediction: prediction(projectedUnclamped: 84)) == nil)
        // Exactly at the limit is not over it.
        #expect(estimate(prediction: prediction(projectedUnclamped: 100)) == nil)
        // A prediction from before the field, or off the spent path.
        #expect(estimate(prediction: prediction(projectedUnclamped: nil)) == nil)
    }

    @Test("a window with no live reset or no known shape states nothing")
    func unknownWindow() {
        #expect(estimate(meter: meter(resetsAt: now.addingTimeInterval(-60))) == nil)
        #expect(estimate(meter: meter(limitWindow: nil)) == nil)
    }

    @Test("percent over is the raw projection minus the limit")
    func percentOver() throws {
        let overshoot = try #require(estimate(prediction: prediction(projectedUnclamped: 111.5)))
        #expect(abs(overshoot.percent - 11.5) < 1e-9)
    }

    @Test("tokens convert through what this window's own tokens bought")
    func tokensFromWindowRate() throws {
        // 70 points over 700,000 tokens = 0.0001 %/token; 11 points over
        // that rate is 110,000 tokens.
        let overshoot = try #require(estimate())
        #expect(overshoot.tokens == 110_000)
    }

    /// The poll that lands on the window's boundary still reports the OLD
    /// window's percent (user-reported 2026-09-24). Counted as this
    /// window's entry height it inflates the gains — 0 → 79 → 20 → 70 reads
    /// 129 points, not 70 — and the same overshoot would be quoted at
    /// ~59,700 tokens. Picked by stamp, the estimate is the plain fixture's
    /// to the token.
    @Test("the poll on the window's boundary is not this window's first")
    func boundarySampleIsExcluded() throws {
        let stale = [
            UsageSample(
                t: windowStart, percents: ["Session (5h)": 79],
                resets: ["Session (5h)": windowStart]),
        ] + samples
        let overshoot = try #require(estimate(samples: stale))
        #expect(overshoot.tokens == 110_000)
        #expect(abs(try #require(overshoot.cost) - 110_000 * (2.05 / 700_000)) < 1e-9)
    }

    @Test("cost prices those tokens at the window's own model mix")
    func costFromPricedRows() throws {
        // 550,000 input at $1/MTok + 150,000 output at $10/MTok = $2.05 over
        // 700,000 tokens ⇒ $2.05/700,000 per token, × 110,000 = $0.322142…
        let overshoot = try #require(estimate())
        let expected = 110_000 * (2.05 / 700_000)
        #expect(abs(try #require(overshoot.cost) - expected) < 1e-9)
    }

    @Test("no token data means no tokens and no cost — never zero")
    func emptyTimeline() throws {
        let overshoot = try #require(estimate(timeline: []))
        #expect(overshoot.percent == 11)
        #expect(overshoot.tokens == nil)
        #expect(overshoot.cost == nil)
    }

    @Test("an unpriced window keeps its tokens and drops its dollars")
    func unpricedModels() throws {
        let empty = PricingTable(rates: [:], fetchedAt: now, source: .live)
        let overshoot = try #require(estimate(pricing: empty))
        #expect(overshoot.tokens == 110_000)
        #expect(overshoot.cost == nil)
    }

    @Test("a scoped meter counts only its own model")
    func scopedMeter() throws {
        let mixed = timeline + [
            TokenSlot(
                t: now.addingTimeInterval(-300), model: "other-model",
                tally: TokenTally(input: 10_000_000, output: 0)),
        ]
        let scoped = try #require(
            estimate(
                meter: meter(scopedModelName: "test"), timeline: mixed,
                pricing: PricingTable(
                    rates: [
                        "test-model": ModelRates(input: 1e-6, output: 10e-6),
                        "other-model": ModelRates(input: 1e-6, output: 1e-6),
                    ],
                    fetchedAt: now, source: .live)))
        // The other model's 10M tokens are invisible: same conversion, same
        // token count as the unscoped fixture.
        #expect(scoped.tokens == 110_000)
        #expect(abs(try #require(scoped.cost) - 110_000 * (2.05 / 700_000)) < 1e-9)
    }

    // MARK: - Captions

    @Test("the caption quotes dollars when they are known, percent when not")
    func captions() {
        #expect(
            UsageFormatting.overshootCaption(
                ForecastOvershoot(percent: 11.2, tokens: 110_000, cost: 38.4),
                locale: posix) == "~$38.40 extra (≈11% over)")
        #expect(
            UsageFormatting.overshootCaption(
                ForecastOvershoot(percent: 11.2, tokens: nil, cost: nil),
                locale: posix) == "≈11% over")
        // A sliver over the limit is still over it — never "≈0% over".
        #expect(
            UsageFormatting.overshootCaption(
                ForecastOvershoot(percent: 0.3, tokens: nil, cost: nil),
                locale: posix) == "≈1% over")
    }

    @Test("a future crossing carries the overshoot; nothing else does")
    func forecastCaptionAppends() {
        let overshoot = ForecastOvershoot(percent: 11.2, tokens: 110_000, cost: 38.4)
        #expect(
            UsageFormatting.forecastCaption(
                percent: 70, exhaustsAt: now.addingTimeInterval(3600),
                overshoot: overshoot, now: now, timeZone: utc, locale: posix)
                == "runs out in 1h · ~$38.40 extra (≈11% over)")
        // Spent: the question is when it comes back, not what it would cost.
        #expect(
            UsageFormatting.forecastCaption(
                percent: 100, exhaustsAt: now.addingTimeInterval(-3600),
                overshoot: overshoot, now: now, timeZone: utc, locale: posix)
                == "spent at \(UsageFormatting.stamp(now.addingTimeInterval(-3600), now: now, timeZone: utc, locale: posix))")
        #expect(
            UsageFormatting.forecastCaption(
                percent: 100, exhaustsAt: nil, overshoot: overshoot,
                now: now, timeZone: utc, locale: posix) == "spent")
    }

    /// The seam the faces build on, end to end: a red forecast's estimate
    /// reaches the digest as its own field AND inside the pre-phrased
    /// caption, so a client renders the dollars without recomputing them.
    @Test("the digest carries the overshoot and says it in the caption")
    func digestCarriesTheOvershoot() throws {
        let crossing = now.addingTimeInterval(3600)
        let red = UsagePrediction(
            ratePerHour: 15, baselineRatePerHour: nil, paceFactor: nil,
            basis: .recentOnly, projectedAtReset: 100, exhaustsAt: crossing,
            verdict: .red, rawVerdict: .red, severity: 1, text: "", curve: [],
            projectedUnclamped: 111)
        let overshoot = try #require(
            ForecastOvershoot.estimate(
                prediction: red, meter: meter(), samples: samples,
                timeline: timeline, pricing: pricing, now: now))

        let state = LiveStateBuilder.build(
            provider: ClaudeProvider(),
            host: "app", pid: 1, appVersion: "0.100.0",
            state: .live(Snapshot(meters: [meter()], fetchedAt: now)),
            predictions: [meter().label: red],
            overshoots: [meter().label: overshoot],
            samples: samples, timeline: timeline, activity: [],
            pricing: pricing, colorLedger: ModelColorLedger(),
            graceSeconds: 900, activeInterval: 300, paceMultiplier: 1,
            nextPollAt: nil, backoffUntil: nil, apiBudget: nil,
            now: now, calendar: Calendar(identifier: .gregorian), locale: posix)

        let forecast = try #require(state.meters.first?.forecast)
        #expect(forecast.overshoot == overshoot)
        #expect(abs(try #require(forecast.projectedUnclamped) - 111) < 1e-9)
        let caption = try #require(forecast.caption)
        #expect(caption.hasPrefix("runs out in 1h · "))
        #expect(caption.contains("extra (≈11% over)"))
    }

    @Test("without an overshoot the caption is exactly what it always was")
    func forecastCaptionUnchanged() {
        for (percent, exhaustsAt) in [
            (70, now.addingTimeInterval(3600)),
            (70, now.addingTimeInterval(3 * 86400)),
            (100, now.addingTimeInterval(-3600)),
        ] as [(Int, Date)] {
            let bare = UsageFormatting.forecastCaption(
                percent: percent, exhaustsAt: exhaustsAt,
                now: now, timeZone: utc, locale: posix)
            let explicitNil = UsageFormatting.forecastCaption(
                percent: percent, exhaustsAt: exhaustsAt, overshoot: nil,
                now: now, timeZone: utc, locale: posix)
            #expect(bare == explicitNil)
            #expect(bare?.contains("extra") == false)
        }
        #expect(
            UsageFormatting.forecastCaption(
                percent: 64, exhaustsAt: nil, now: now, timeZone: utc, locale: posix) == nil)
    }
}
