import Foundation

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

    /// What a tally would cost at these rates. Cache-write tokens split into
    /// 5-minute and 1-hour TTL portions because they're billed differently.
    public func dollars(for tally: TokenTally) -> Double {
        let write1h = min(tally.cacheCreation1h, tally.cacheCreation)
        let write5m = tally.cacheCreation - write1h
        return Double(tally.input) * input
            + Double(tally.output) * output
            + Double(tally.cacheRead) * (cacheRead ?? input * 0.1)
            + Double(write5m) * (cacheWrite ?? input * 1.25)
            + Double(write1h) * (cacheWrite1h ?? cacheWrite ?? input * 2)
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

public enum PricingFeedError: Error, Sendable {
    case network(URLError)
    case http(Int)
    case schema
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

    public func fetch(now: Date = Date()) async throws -> PricingTable {
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
        return try Self.decode(feed: data, now: now)
    }

    /// The feed is a huge mixed-provider dictionary; entries that don't decode
    /// are skipped rather than failing the whole table.
    static func decode(feed: Data, now: Date) throws -> PricingTable {
        guard let entries = try? JSONDecoder().decode([String: Lenient<FeedEntry>].self, from: feed)
        else { throw PricingFeedError.schema }

        var rates: [String: ModelRates] = [:]
        for (key, lenient) in entries {
            guard key.hasPrefix("claude"),
                  let entry = lenient.value,
                  entry.litellmProvider == "anthropic",
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

    public init(client: PricingFeedClient = PricingFeedClient(), cacheDirectory: URL) {
        self.client = client
        self.fileURL = cacheDirectory.appending(path: "pricing.json")
    }

    public static func standard(bundleID: String) -> PricingService {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return PricingService(cacheDirectory: base.appending(path: bundleID))
    }

    /// Best table available without touching the network.
    public func current() -> PricingTable {
        guard let data = try? Data(contentsOf: fileURL),
              let table = try? JSONDecoder().decode(PricingTable.self, from: data),
              !table.rates.isEmpty
        else { return .bundled }
        return table
    }

    /// Fetches a fresh table when the current one is stale. Returns nil when
    /// nothing changed (still fresh, or the fetch failed).
    public func refreshIfStale(now: Date = Date()) async -> PricingTable? {
        guard current().isStale(now: now) else { return nil }
        guard let table = try? await client.fetch(now: now) else { return nil }
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
