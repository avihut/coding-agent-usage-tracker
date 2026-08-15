import Foundation

/// One token class priced out — a single line of the arithmetic behind a
/// cost estimate. `listed` is false when the feed carried no rate for the
/// class and a standard multiple of another rate stood in.
public struct CostComponent: Sendable, Equatable, Identifiable {
    public enum TokenClass: String, Sendable, CaseIterable {
        case freshInput
        case cacheWrite5m
        case cacheWrite1h
        case cacheRead
        case output
    }

    public let tokenClass: TokenClass
    public let tokens: Int
    /// USD per token actually applied.
    public let rate: Double
    public let listed: Bool

    public var id: TokenClass { tokenClass }
    public var dollars: Double { Double(tokens) * rate }
}

/// USD per token, straight from the pricing feed. Cache fields are optional —
/// costing falls back to Anthropic's standard multipliers when absent.
public struct ModelRates: Codable, Sendable, Equatable {
    public let input: Double
    public let output: Double
    public let cacheWrite: Double?
    /// 1-hour-TTL cache writes are priced higher than the 5-minute default.
    public let cacheWrite1h: Double?
    public let cacheRead: Double?

    public init(
        input: Double, output: Double,
        cacheWrite: Double? = nil, cacheWrite1h: Double? = nil, cacheRead: Double? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
    }

    /// A tally's cost per token class. Cache-write tokens split into
    /// 5-minute and 1-hour TTL portions because they're billed differently.
    public struct DollarBreakdown: Sendable, Equatable {
        public let input: Double
        public let output: Double
        public let cacheWrite: Double
        public let cacheRead: Double
        public var total: Double { input + output + cacheWrite + cacheRead }
    }

    /// The estimate's arithmetic, one line per token class in reading
    /// order. This is the single costing source: `dollarBreakdown` and
    /// `dollars` are sums over these lines, and the cost-math popover
    /// renders them verbatim.
    public func components(for tally: TokenTally) -> [CostComponent] {
        let write1h = min(tally.cacheCreation1h, tally.cacheCreation)
        let write5m = tally.cacheCreation - write1h
        return [
            CostComponent(
                tokenClass: .freshInput, tokens: tally.input, rate: input, listed: true),
            CostComponent(
                tokenClass: .cacheWrite5m, tokens: write5m,
                rate: cacheWrite ?? input * 1.25, listed: cacheWrite != nil),
            CostComponent(
                tokenClass: .cacheWrite1h, tokens: write1h,
                rate: cacheWrite1h ?? cacheWrite ?? input * 2, listed: cacheWrite1h != nil),
            CostComponent(
                tokenClass: .cacheRead, tokens: tally.cacheRead,
                rate: cacheRead ?? input * 0.1, listed: cacheRead != nil),
            CostComponent(
                tokenClass: .output, tokens: tally.output, rate: output, listed: true),
        ]
    }

    public func dollarBreakdown(for tally: TokenTally) -> DollarBreakdown {
        var byClass: [CostComponent.TokenClass: Double] = [:]
        for line in components(for: tally) { byClass[line.tokenClass, default: 0] += line.dollars }
        return DollarBreakdown(
            input: byClass[.freshInput] ?? 0,
            output: byClass[.output] ?? 0,
            cacheWrite: (byClass[.cacheWrite5m] ?? 0) + (byClass[.cacheWrite1h] ?? 0),
            cacheRead: byClass[.cacheRead] ?? 0)
    }

    /// What a tally would cost at these rates.
    public func dollars(for tally: TokenTally) -> Double {
        dollarBreakdown(for: tally).total
    }
}

/// A model-id → rates map with provenance. `bundled` is the table baked into
/// the binary; `live` came from the pricing feed (directly or via disk cache).
public struct PricingTable: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case bundled
        case live
    }

    public let rates: [String: ModelRates]
    public let fetchedAt: Date
    public let source: Source

    public init(rates: [String: ModelRates], fetchedAt: Date, source: Source) {
        self.rates = rates
        self.fetchedAt = fetchedAt
        self.source = source
    }

    /// Exact id first, then with the trailing release date stripped
    /// ("claude-haiku-4-5-20251001" → "claude-haiku-4-5").
    public func rates(for modelID: String) -> ModelRates? {
        if let exact = rates[modelID] { return exact }
        let parts = modelID.split(separator: "-")
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            return rates[parts.dropLast().joined(separator: "-")]
        }
        return nil
    }

    /// A live table is due for a refresh after 24h; the bundled table always is.
    public func isStale(now: Date) -> Bool {
        source == .bundled || now.timeIntervalSince(fetchedAt) >= 24 * 3600
    }

    /// Feed snapshot from 2026-08-13, so costs render before the first
    /// successful fetch and when offline.
    public static let bundled = PricingTable(
        rates: [
            "claude-fable-5": ModelRates(
                input: 1e-5, output: 5e-5, cacheWrite: 1.25e-5, cacheWrite1h: 2e-5, cacheRead: 1e-6),
            "claude-mythos-5": ModelRates(
                input: 1e-5, output: 5e-5, cacheWrite: 1.25e-5, cacheWrite1h: 2e-5, cacheRead: 1e-6),
            "claude-opus-5": ModelRates(
                input: 5e-6, output: 2.5e-5, cacheWrite: 6.25e-6, cacheWrite1h: 1e-5, cacheRead: 5e-7),
            "claude-opus-4-8": ModelRates(
                input: 5e-6, output: 2.5e-5, cacheWrite: 6.25e-6, cacheWrite1h: 1e-5, cacheRead: 5e-7),
            "claude-opus-4-7": ModelRates(
                input: 5e-6, output: 2.5e-5, cacheWrite: 6.25e-6, cacheWrite1h: 1e-5, cacheRead: 5e-7),
            "claude-opus-4-6": ModelRates(
                input: 5e-6, output: 2.5e-5, cacheWrite: 6.25e-6, cacheWrite1h: 1e-5, cacheRead: 5e-7),
            "claude-opus-4-5": ModelRates(
                input: 5e-6, output: 2.5e-5, cacheWrite: 6.25e-6, cacheWrite1h: 1e-5, cacheRead: 5e-7),
            "claude-opus-4-1": ModelRates(
                input: 1.5e-5, output: 7.5e-5, cacheWrite: 1.875e-5, cacheWrite1h: 3e-5, cacheRead: 1.5e-6),
            "claude-opus-4": ModelRates(
                input: 1.5e-5, output: 7.5e-5, cacheWrite: 1.875e-5, cacheWrite1h: 3e-5, cacheRead: 1.5e-6),
            "claude-sonnet-5": ModelRates(
                input: 2e-6, output: 1e-5, cacheWrite: 2.5e-6, cacheWrite1h: 4e-6, cacheRead: 2e-7),
            "claude-sonnet-4-6": ModelRates(
                input: 3e-6, output: 1.5e-5, cacheWrite: 3.75e-6, cacheWrite1h: 6e-6, cacheRead: 3e-7),
            "claude-sonnet-4-5": ModelRates(
                input: 3e-6, output: 1.5e-5, cacheWrite: 3.75e-6, cacheWrite1h: 6e-6, cacheRead: 3e-7),
            "claude-sonnet-4": ModelRates(
                input: 3e-6, output: 1.5e-5, cacheWrite: 3.75e-6, cacheWrite1h: 6e-6, cacheRead: 3e-7),
            "claude-haiku-4-5": ModelRates(
                input: 1e-6, output: 5e-6, cacheWrite: 1.25e-6, cacheWrite1h: 2e-6, cacheRead: 1e-7),
        ],
        fetchedAt: .distantPast,
        source: .bundled)
}

/// Which slice of the mixed-provider feed a provider's pricing table keeps.
/// The feed mirrors every vendor's list prices; each provider declares its
/// own filter so a Codex table never fills with Claude rates and vice versa.
public struct PricingFeedSelector: Sendable {
    /// Keep this feed entry? `key` is the feed's model id, `litellmProvider`
    /// its `litellm_provider` tag (nil when the entry omits it).
    public let includes: @Sendable (_ key: String, _ litellmProvider: String?) -> Bool

    public init(includes: @escaping @Sendable (String, String?) -> Bool) {
        self.includes = includes
    }

    public static let claude = PricingFeedSelector { key, provider in
        key.hasPrefix("claude") && provider == "anthropic"
    }

    /// Route-prefixed duplicates ("openai/gpt-…") are skipped — the bare
    /// keys are the canonical ids the agent's transcripts use.
    public static let openAI = PricingFeedSelector { key, provider in
        provider == "openai" && !key.contains("/")
    }
}

public enum PricingFeedError: Error, Sendable {
    case network(URLError)
    case http(Int)
    case schema

    /// Readable one-liner for the settings screen's refresh feedback.
    public var shortText: String {
        switch self {
        case .network: "network unreachable"
        case .http(let code): "feed returned HTTP \(code)"
        case .schema: "feed format not recognized"
        }
    }
}

/// One call against the community pricing feed (LiteLLM's model price list on
/// raw.githubusercontent.com — the second and only other network destination
/// this app talks to, plain GET, no credentials attached, documented in the
/// README). Anthropic publishes no pricing API; this feed is the standard
/// machine-readable mirror of the list prices.
public struct PricingFeedClient: Sendable {
    public static let endpoint = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: config)
        }
    }

    public func fetch(
        now: Date = Date(), selector: PricingFeedSelector = .claude
    ) async throws -> PricingTable {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw PricingFeedError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PricingFeedError.network(URLError(.badServerResponse))
        }
        guard (200...299).contains(http.statusCode) else {
            throw PricingFeedError.http(http.statusCode)
        }
        return try Self.decode(feed: data, now: now, selector: selector)
    }

    /// The feed is a huge mixed-provider dictionary; entries that don't decode
    /// are skipped rather than failing the whole table.
    static func decode(
        feed: Data, now: Date, selector: PricingFeedSelector = .claude
    ) throws -> PricingTable {
        guard let entries = try? JSONDecoder().decode([String: Lenient<FeedEntry>].self, from: feed)
        else { throw PricingFeedError.schema }

        var rates: [String: ModelRates] = [:]
        for (key, lenient) in entries {
            guard let entry = lenient.value,
                  selector.includes(key, entry.litellmProvider),
                  let input = entry.inputCostPerToken,
                  let output = entry.outputCostPerToken
            else { continue }
            rates[key] = ModelRates(
                input: input, output: output,
                cacheWrite: entry.cacheCreationInputTokenCost,
                cacheWrite1h: entry.cacheCreationInputTokenCostAbove1hr,
                cacheRead: entry.cacheReadInputTokenCost)
        }
        guard !rates.isEmpty else { throw PricingFeedError.schema }
        return PricingTable(rates: rates, fetchedAt: now, source: .live)
    }

    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) { value = try? T(from: decoder) }
    }

    private struct FeedEntry: Decodable {
        let litellmProvider: String?
        let inputCostPerToken: Double?
        let outputCostPerToken: Double?
        let cacheCreationInputTokenCost: Double?
        let cacheCreationInputTokenCostAbove1hr: Double?
        let cacheReadInputTokenCost: Double?

        private enum CodingKeys: String, CodingKey {
            case litellmProvider = "litellm_provider"
            case inputCostPerToken = "input_cost_per_token"
            case outputCostPerToken = "output_cost_per_token"
            case cacheCreationInputTokenCost = "cache_creation_input_token_cost"
            case cacheCreationInputTokenCostAbove1hr = "cache_creation_input_token_cost_above_1hr"
            case cacheReadInputTokenCost = "cache_read_input_token_cost"
        }
    }
}

/// Disk-cached pricing with the bundled table as the floor. The store asks
/// `refreshIfStale` opportunistically (piggybacked on usage refreshes); a
/// failed fetch quietly keeps whatever we had.
public struct PricingService: Sendable {
    let client: PricingFeedClient
    let fileURL: URL
    /// The provider's offline floor, used until the feed has been cached.
    let fallback: PricingTable
    /// The provider's slice of the mixed-vendor feed.
    let selector: PricingFeedSelector

    public init(
        client: PricingFeedClient = PricingFeedClient(), cacheDirectory: URL,
        fallback: PricingTable = .bundled, selector: PricingFeedSelector = .claude
    ) {
        self.client = client
        self.fileURL = cacheDirectory.appending(path: "pricing.json")
        self.fallback = fallback
        self.selector = selector
    }

    /// Best table available without touching the network.
    public func current() -> PricingTable {
        guard let data = try? Data(contentsOf: fileURL),
              let table = try? JSONDecoder().decode(PricingTable.self, from: data),
              !table.rates.isEmpty
        else { return fallback }
        return table
    }

    /// Fetches a fresh table when the current one is stale. Returns nil when
    /// nothing changed (still fresh, or the fetch failed).
    public func refreshIfStale(now: Date = Date()) async -> PricingTable? {
        guard current().isStale(now: now) else { return nil }
        guard let table = try? await client.fetch(now: now, selector: selector) else { return nil }
        save(table)
        return table
    }

    /// A user-clicked refresh: fetches regardless of staleness (the
    /// automatic path stays daily) and throws so the button can say why it
    /// failed. Still the same single allowed destination, nothing attached.
    public func refreshNow(now: Date = Date()) async throws -> PricingTable {
        let table = try await client.fetch(now: now, selector: selector)
        save(table)
        return table
    }

    private func save(_ table: PricingTable) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(table)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Cache is an optimization; the bundled table still prices things.
        }
    }
}
