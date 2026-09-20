import Foundation
import Testing

@testable import UsageCore

// One download of the rate feed serves every metered harness (0.101.0).
// Three harnesses used to mean three requests for the same ~2 MB document on
// the same daily schedule. Serialized: the URLProtocol stub carries its body
// in a static, which parallel tests would clobber for each other.
@Suite("Pricing feed cache", .serialized) struct PricingFeedCacheTests {
    private let feed = """
        {
          "claude-opus-5": {
            "litellm_provider": "anthropic", "mode": "chat",
            "input_cost_per_token": 0.000015, "output_cost_per_token": 0.000075
          },
          "gpt-5.2-codex": {
            "litellm_provider": "openai", "mode": "chat",
            "input_cost_per_token": 0.0000025, "output_cost_per_token": 0.00001
          }
        }
        """

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pricing-feed-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("absent, stale and future-stamped caches all read as no cache")
    func freshness() throws {
        let cache = PricingFeedCache(fileURL: directory().appending(path: "feed.json"))
        let now = Date()
        #expect(cache.bytes(now: now) == nil)

        cache.store(Data(feed.utf8))
        #expect(cache.bytes(now: now) != nil)
        // A day on, the automatic path fetches again…
        #expect(cache.bytes(now: now.addingTimeInterval(PricingFeedCache.freshness + 1)) == nil)
        // …and a click's window is a minute, so a click always reaches the
        // network while its own fan-out across harnesses does not.
        #expect(cache.bytes(now: now, maxAge: PricingFeedCache.forcedFreshness) != nil)
        #expect(cache.bytes(
            now: now.addingTimeInterval(120), maxAge: PricingFeedCache.forcedFreshness) == nil)
        // A clock that moved backwards must not make the cache immortal.
        #expect(cache.bytes(now: now.addingTimeInterval(-2 * PricingFeedCache.freshness)) == nil)
        // Empty bytes are never stored — a truncated write must not be
        // handed to the next harness as if it were the feed.
        let empty = PricingFeedCache(fileURL: directory().appending(path: "feed.json"))
        empty.store(Data())
        #expect(empty.bytes(now: now) == nil)
    }

    @Test("a second harness decodes its own slice without a second request")
    func sharedAcrossHarnesses() async throws {
        let cache = PricingFeedCache(fileURL: directory().appending(path: "feed.json"))
        let requests = Counter()
        let client = PricingFeedClient(session: stubSession(body: Data(feed.utf8), onRequest: {
            await requests.bump()
        }))

        let claude = try await client.fetch(selector: .claude, cache: cache)
        let codex = try await client.fetch(selector: .openAI, cache: cache)

        #expect(await requests.count == 1)
        // Each harness still gets ITS OWN slice out of the one document.
        #expect(claude.rates.keys.contains("claude-opus-5"))
        #expect(!claude.rates.keys.contains("gpt-5.2-codex"))
        #expect(codex.rates.keys.contains("gpt-5.2-codex"))
        #expect(!codex.rates.keys.contains("claude-opus-5"))
    }

    @Test("bytes that don't decode are never cached")
    func undecodableIsNotCached() async throws {
        let cache = PricingFeedCache(fileURL: directory().appending(path: "feed.json"))
        let client = PricingFeedClient(session: stubSession(body: Data("not json".utf8)))
        _ = try? await client.fetch(selector: .claude, cache: cache)
        #expect(cache.bytes() == nil)
    }

    @Test("without a cache every service fetches for itself, as before")
    func optOut() async throws {
        let requests = Counter()
        let client = PricingFeedClient(session: stubSession(body: Data(feed.utf8), onRequest: {
            await requests.bump()
        }))
        _ = try await client.fetch(selector: .claude)
        _ = try await client.fetch(selector: .openAI)
        #expect(await requests.count == 2)
    }

    private actor Counter {
        var count = 0
        func bump() { count += 1 }
    }

    private func stubSession(
        body: Data, onRequest: (@Sendable () async -> Void)? = nil
    ) -> URLSession {
        StubProtocol.body = body
        StubProtocol.onRequest = onRequest
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
}

/// The house rule: network behavior is tested with a `URLProtocol` stub and
/// never against the live feed.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    // Set once per test before the session runs, read on the protocol's own
    // thread; the suite is serial per test so there is no contention.
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var onRequest: (@Sendable () async -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body
        let hook = Self.onRequest
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        Task {
            await hook?()
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
