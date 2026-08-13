import Foundation
import Testing
@testable import UsageCore

@Suite("CostSimulator")
struct CostSimulatorTests {
    // Haiku-shaped rates: output 5× input, read 0.1×, writes 1.25×/2×.
    private let rates = ModelRates(
        input: 1e-6, output: 5e-6, cacheWrite: 1.25e-6, cacheWrite1h: 2e-6, cacheRead: 1e-7)

    @Test("first request writes the starting context, reads nothing")
    func singleStep() {
        let outcome = CostSimulator.simulate(
            .init(startingContext: 5_000, steps: 1, growthPerStep: 800, outputPerStep: 300),
            rates: rates)
        #expect(outcome.tally.cacheCreation == 5_000)
        #expect(outcome.tally.cacheRead == 0)
        #expect(outcome.tally.output == 300)
        #expect(outcome.finalContext == 5_800)
    }

    @Test("token totals match the closed forms")
    func closedForms() {
        let outcome = CostSimulator.simulate(
            .init(
                startingContext: 1_000, steps: 3, growthPerStep: 100, outputPerStep: 200,
                freshPerStep: 10),
            rates: rates)
        // writes = C + (n−1)g; reads = (n−1)C + g(n−1)(n−2)/2
        #expect(outcome.tally.cacheCreation == 1_200)
        #expect(outcome.tally.cacheRead == 2_100)
        #expect(outcome.tally.input == 30)
        #expect(outcome.tally.output == 600)
        #expect(outcome.finalContext == 1_300)
    }

    @Test("TTL flag switches the cache-write class, and 1h costs more")
    func ttlSelectsWriteRate() {
        var session = CostSimulator.Session(
            startingContext: 10_000, steps: 5, growthPerStep: 1_000, outputPerStep: 0,
            freshPerStep: 0)
        session.oneHourTTL = true
        let hourly = CostSimulator.simulate(session, rates: rates)
        session.oneHourTTL = false
        let fiveMinute = CostSimulator.simulate(session, rates: rates)

        #expect(hourly.tally.cacheCreation1h == hourly.tally.cacheCreation)
        #expect(fiveMinute.tally.cacheCreation1h == 0)
        #expect(hourly.tally.cacheRead == fiveMinute.tally.cacheRead)
        #expect(hourly.cost > fiveMinute.cost)
    }

    @Test("dollars match hand arithmetic, cached and counterfactual")
    func costMatchesHandArithmetic() {
        let outcome = CostSimulator.simulate(
            .init(
                startingContext: 1_000, steps: 2, growthPerStep: 500, outputPerStep: 100,
                freshPerStep: 10, oneHourTTL: false),
            rates: rates)
        // writes 1500, reads 1000, input 20, output 200
        let expected = 20 * 1e-6 + 200 * 5e-6 + 1_000 * 1e-7 + 1_500 * 1.25e-6
        #expect(abs(outcome.cost - expected) < 1e-12)
        // Uncached prompt: 2·1000 + 500·(2·1/2) + 20 fresh = 2520.
        let uncachedExpected = 2_520 * 1e-6 + 200 * 5e-6
        #expect(abs(outcome.uncachedCost - uncachedExpected) < 1e-12)
        // The per-class breakdown the playground displays sums to the total.
        let breakdown = rates.dollarBreakdown(for: outcome.tally)
        #expect(abs(breakdown.total - outcome.cost) < 1e-12)
    }

    @Test("a long session is read-dominated and far cheaper than resending")
    func cachingBeatsResending() {
        let outcome = CostSimulator.simulate(
            .init(startingContext: 18_000, steps: 60, growthPerStep: 2_500, outputPerStep: 400),
            rates: rates)
        #expect(outcome.cost < outcome.uncachedCost)
        #expect(outcome.tally.cacheRead > 10 * outcome.tally.uncachedInput)
    }

    @Test("zero steps clamp to one request")
    func stepsClampToOne() {
        let outcome = CostSimulator.simulate(
            .init(startingContext: 1_000, steps: 0, growthPerStep: 100, outputPerStep: 50),
            rates: rates)
        #expect(outcome.tally.cacheCreation == 1_000)
        #expect(outcome.tally.cacheRead == 0)
        #expect(outcome.finalContext == 1_100)
    }
}
