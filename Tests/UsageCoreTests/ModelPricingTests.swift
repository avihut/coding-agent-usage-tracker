import Foundation
import Testing
@testable import UsageCore

@Suite("Model pricing")
struct ModelPricingTests {
    static let feed = Data(#"""
        {
          "claude-fable-5": {
            "litellm_provider": "anthropic",
            "input_cost_per_token": 0.00001,
            "output_cost_per_token": 0.00005,
            "cache_creation_input_token_cost": 0.0000125,
            "cache_creation_input_token_cost_above_1hr": 0.00002,
            "cache_read_input_token_cost": 0.000001,
            "mode": "chat"
          },
          "claude-haiku-4-5": {
            "litellm_provider": "anthropic",
            "input_cost_per_token": 0.000001,
            "output_cost_per_token": 0.000005
          },
          "claude-on-bedrock": {
            "litellm_provider": "bedrock",
            "input_cost_per_token": 1,
            "output_cost_per_token": 1
          },
          "claude-no-costs": {"litellm_provider": "anthropic", "mode": "chat"},
          "gpt-something": {"litellm_provider": "openai", "input_cost_per_token": 1},
          "sample_spec": {"anything": ["goes", 42]}
        }
        """#.utf8)

    static let now = Date(timeIntervalSince1970: 1_785_600_000)

    @Test("feed decode keeps anthropic claude entries, skips the rest")
    func decode() throws {
        let table = try PricingFeedClient.decode(feed: Self.feed, now: Self.now)

        #expect(Set(table.rates.keys) == ["claude-fable-5", "claude-haiku-4-5"])
        #expect(table.source == .live)
        #expect(table.rates["claude-fable-5"]?.cacheWrite1h == 0.00002)
    }

    @Test("an all-garbage feed throws rather than yielding an empty table")
    func garbageFeed() {
        #expect(throws: PricingFeedError.self) {
            try PricingFeedClient.decode(feed: Data("[1, 2]".utf8), now: Self.now)
        }
        #expect(throws: PricingFeedError.self) {
            try PricingFeedClient.decode(
                feed: Data(#"{"gpt-x": {"input_cost_per_token": 1}}"#.utf8), now: Self.now)
        }
    }

    @Test("model lookup: exact id, then the id with its release date stripped")
    func lookup() throws {
        let table = try PricingFeedClient.decode(feed: Self.feed, now: Self.now)

        #expect(table.rates(for: "claude-fable-5") != nil)
        #expect(table.rates(for: "claude-haiku-4-5-20251001") != nil) // via strip
        #expect(table.rates(for: "claude-nonexistent-1") == nil)
        #expect(table.rates(for: "unknown") == nil)
    }

    @Test("cost math bills each token class at its own rate, 1h cache split included")
    func dollars() {
        let rates = ModelRates(
            input: 1e-5, output: 5e-5, cacheWrite: 1.25e-5, cacheWrite1h: 2e-5, cacheRead: 1e-6)
        let tally = TokenTally(
            input: 1_000_000, output: 100_000, cacheCreation: 500_000, cacheRead: 2_000_000,
            cacheCreation1h: 200_000)

        // 10 + 5 + (300k × 12.5 + 200k × 20)/1M + 2
        #expect(abs(rates.dollars(for: tally) - 24.75) < 0.0001)
    }

    @Test("missing cache rates fall back to the standard multipliers")
    func fallbackRates() {
        let rates = ModelRates(input: 1e-5, output: 5e-5)
        let tally = TokenTally(input: 0, output: 0, cacheCreation: 1_000_000, cacheRead: 1_000_000)

        // write ×1.25, read ×0.1 of the input rate
        #expect(abs(rates.dollars(for: tally) - 13.5) < 0.0001)
    }

    @Test("cost components spell the math out and sum to the total")
    func components() {
        let rates = ModelRates(
            input: 1e-5, output: 5e-5, cacheWrite: 1.25e-5, cacheWrite1h: 2e-5, cacheRead: 1e-6)
        let tally = TokenTally(
            input: 1_000_000, output: 100_000, cacheCreation: 500_000, cacheRead: 2_000_000,
            cacheCreation1h: 200_000)

        let lines = rates.components(for: tally)
        let classes = lines.map { $0.tokenClass }
        let summed = lines.map { $0.dollars }.reduce(0, +)
        #expect(classes == [.freshInput, .cacheWrite5m, .cacheWrite1h, .cacheRead, .output])
        #expect(lines.allSatisfy { $0.listed })
        #expect(lines[1].tokens == 300_000) // the 5m slice is creation minus the 1h slice
        #expect(lines[2].tokens == 200_000)
        #expect(abs(lines[2].dollars - 4) < 0.0001) // 200K × $20/MTok
        #expect(abs(summed - rates.dollars(for: tally)) < 0.0001)
    }

    @Test("fallback rates are flagged as unlisted in the components")
    func componentFallbacks() {
        let rates = ModelRates(input: 1e-5, output: 5e-5)
        let lines = rates.components(for: TokenTally(
            input: 1, output: 1, cacheCreation: 2, cacheRead: 1, cacheCreation1h: 1))

        let unlisted = lines.filter { !$0.listed }.map { $0.tokenClass }
        #expect(unlisted == [.cacheWrite5m, .cacheWrite1h, .cacheRead])
        #expect(abs(lines[1].rate - 1.25e-5) < 1e-12) // write ×1.25
        #expect(abs(lines[2].rate - 2e-5) < 1e-12) // 1h write ×2 when no write rate at all
        #expect(abs(lines[3].rate - 1e-6) < 1e-12) // read ×0.1
    }

    @Test("per-MTok rate formatting")
    func ratePerMTok() {
        #expect(UsageFormatting.ratePerMTok(1.5e-5) == "$15")
        #expect(UsageFormatting.ratePerMTok(6.25e-6) == "$6.25")
        #expect(UsageFormatting.ratePerMTok(1.875e-5) == "$18.75")
        #expect(UsageFormatting.ratePerMTok(5e-7) == "$0.50")
        #expect(UsageFormatting.ratePerMTok(1e-7) == "$0.10")
    }

    @Test("staleness: bundled is always stale, live only after 24h")
    func staleness() throws {
        let table = try PricingFeedClient.decode(feed: Self.feed, now: Self.now)

        #expect(PricingTable.bundled.isStale(now: Self.now))
        #expect(!table.isStale(now: Self.now.addingTimeInterval(23 * 3600)))
        #expect(table.isStale(now: Self.now.addingTimeInterval(24 * 3600)))
    }

    @Test("bundled table prices the models this Mac actually runs")
    func bundledCoverage() {
        #expect(PricingTable.bundled.rates(for: "claude-fable-5") != nil)
        #expect(PricingTable.bundled.rates(for: "claude-haiku-4-5-20251001") != nil)
        #expect(PricingTable.bundled.rates(for: "claude-opus-5") != nil)
    }

    @Test("pricing service serves the disk cache, or bundled without one")
    func serviceCache() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "pricing-tests-\(UUID().uuidString)")
        let service = PricingService(cacheDirectory: dir)

        #expect(service.current() == .bundled)

        let table = try PricingFeedClient.decode(feed: Self.feed, now: Self.now)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(table).write(to: dir.appending(path: "pricing.json"))
        #expect(service.current() == table)
    }

    @Test("money formatting")
    func money() {
        #expect(UsageFormatting.money(0) == "$0.00")
        #expect(UsageFormatting.money(0.004) == "<$0.01")
        #expect(UsageFormatting.money(4.2) == "$4.20")
        #expect(UsageFormatting.money(1234.5) == "$1,235")
    }
}

@Suite("RequestLedger")
struct RequestLedgerTests {
    static let t0 = Date(timeIntervalSince1970: 1_785_600_000)

    @Test("counts only the trailing hour")
    func window() {
        var ledger = RequestLedger()
        ledger.recordRequest(at: Self.t0)
        ledger.recordRequest(at: Self.t0.addingTimeInterval(1800))
        ledger.recordRequest(at: Self.t0.addingTimeInterval(3599))

        #expect(ledger.used(at: Self.t0.addingTimeInterval(3599)) == 3)
        // The first stamp falls out of the window an hour after it happened.
        #expect(ledger.used(at: Self.t0.addingTimeInterval(3601)) == 2)
    }

    @Test("pressure is used over the estimated ceiling")
    func pressure() {
        var ledger = RequestLedger(ceiling: 10)
        for i in 0..<5 { ledger.recordRequest(at: Self.t0.addingTimeInterval(Double(i))) }
        #expect(ledger.pressure(at: Self.t0.addingTimeInterval(10)) == 0.5)
    }

    @Test("a 429 tightens the ceiling to just under the window's count")
    func learning() {
        var ledger = RequestLedger()
        for i in 0..<8 { ledger.recordRequest(at: Self.t0.addingTimeInterval(Double(i * 60))) }
        ledger.noteRateLimited(at: Self.t0.addingTimeInterval(500))

        #expect(ledger.ceiling == 7)

        // A later 429 with more requests in-window can't raise it back up.
        for i in 0..<12 { ledger.recordRequest(at: Self.t0.addingTimeInterval(600 + Double(i))) }
        ledger.noteRateLimited(at: Self.t0.addingTimeInterval(700))
        #expect(ledger.ceiling == 7)
    }

    @Test("the learned ceiling never collapses below the minimum")
    func floorHolds() {
        var ledger = RequestLedger()
        ledger.recordRequest(at: Self.t0)
        ledger.noteRateLimited(at: Self.t0.addingTimeInterval(1))
        #expect(ledger.ceiling == RequestLedger.minimumCeiling)
    }
}
