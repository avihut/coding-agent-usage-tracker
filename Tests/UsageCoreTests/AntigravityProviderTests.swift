import Foundation
import Testing

@testable import UsageCore

/// Status-line payloads in the shape Antigravity's status-line docs give —
/// built here, with the identifying fields a real one carries so the tests
/// prove none survives the reduction.
enum AntigravityStatusLine {
    static func payload(
        quota: String?, planTier: String? = "pro", email: String = "person@example.com"
    ) -> Data {
        var fields = [
            #""cwd":"/Users/someone/secret-project""#,
            #""email":"\#(email)""#,
            #""transcript_path":"/Users/someone/.gemini/antigravity-cli/brain/x/.system_generated/logs/transcript.jsonl""#,
            #""conversation_title":"SECRET TITLE""#,
            #""model":{"id":"gemini-4-neon","display_name":"Gemini 4 Neon","effort":"xhigh"}"#,
            #""version":"1.5.14""#,
            #""cost":{"total_usd":1.23}"#,
            #""context_window":{"total_input_tokens":1000}"#,
        ]
        if let planTier { fields.append(#""plan_tier":"\#(planTier)""#) }
        if let quota { fields.append(#""quota":\#(quota)"#) }
        return Data(("{" + fields.joined(separator: ",") + "}").utf8)
    }

    static func bucket(
        _ id: String, remaining: Double? = nil, reset: Date? = nil, inSeconds: Double? = nil,
        disabled: Bool? = nil, amount: Double? = nil
    ) -> String {
        var fields: [String] = []
        if let remaining { fields.append(#""remaining_fraction":\#(remaining)"#) }
        if let amount { fields.append(#""remaining_amount":\#(amount)"#) }
        if let reset { fields.append(#""reset_time":"\#(AntigravityFixture.stamp(reset))""#) }
        if let inSeconds { fields.append(#""reset_in_seconds":\#(inSeconds)"#) }
        if let disabled { fields.append(#""disabled":\#(disabled)"#) }
        return #""\#(id)":{\#(fields.joined(separator: ","))}"#
    }

    static func quota(_ buckets: [String]) -> String { "{" + buckets.joined(separator: ",") + "}" }
}

@Suite("Antigravity provider")
struct AntigravityProviderTests {
    private let now = Date()

    private func reading(_ buckets: [String], at captured: Date) throws -> Data {
        try #require(AntigravityQuota.reduce(
            statusLine: AntigravityStatusLine.payload(quota: AntigravityStatusLine.quota(buckets)),
            now: captured))
    }

    private func snapshot(
        _ reading: Data?, conversationWrittenAt: Date? = nil, fetchedAt: Date? = nil
    ) throws -> Snapshot {
        let payload = AntigravityUsagePayload(
            fetchedAt: fetchedAt ?? now,
            reading: reading.flatMap(AntigravityQuota.decodeReading),
            conversationWrittenAt: conversationWrittenAt)
        return try AntigravityQuota.snapshot(
            fromPayload: AntigravityQuota.encodePayload(payload), thresholds: .standard, now: now)
    }

    @Test("identity is provider data: ∩, violet, local, no credentials")
    func identity() {
        let provider = AntigravityProvider()
        #expect(provider.id == "antigravity")
        #expect(provider.agentName == "Antigravity CLI")
        #expect(provider.menuBarGlyph == "∩")
        #expect(provider.accent == ProviderAccent(red: 0.631, green: 0.259, blue: 0.957))
        #expect(provider.networkDestinations.isEmpty)
        #expect(provider.statusFeed == nil)
        #expect(provider.accountIdentity == nil)
        #expect(provider.agentSettings == nil)
        #expect(provider.deprecationNote == nil)
        #expect(provider.statusLineExport != nil)
        #expect(!provider.supportsMultipleHomes)
        #expect(HarnessResolution.standardProviders().last?.id == "antigravity")
    }

    @Test("its models read and price as Gemini's")
    func modelsAndPricing() {
        let provider = AntigravityProvider()
        #expect(provider.modelCatalog.displayName("gemini-4-neon") == "Gemini 4 Neon")
        #expect(provider.pricingSelector.normalizeKey("gemini/gemini-4-neon") == "gemini-4-neon")
        #expect(provider.pricingSelector.includes("gemini/gemini-4-neon", "gemini"))
    }

    /// The rates the feed carries for Antigravity's models sit under
    /// `gemini/`; a synthetic fragment proves the provider's own slice picks
    /// them up and keys them the way transcripts name them.
    @Test("its models price through Gemini's feed slice")
    func pricesThroughFeed() throws {
        let feed = Data("""
        {"gemini/gemini-4-neon":{"litellm_provider":"gemini","input_cost_per_token":0.000003,
          "output_cost_per_token":0.000015,"cache_read_input_token_cost":1.5e-7},
         "vertex_ai/gemini-4-neon":{"litellm_provider":"vertex_ai","input_cost_per_token":9,
          "output_cost_per_token":9},
         "gemini/gemini-4-argon":{"litellm_provider":"gemini","input_cost_per_token":0.000002,
          "output_cost_per_token":0.00001}}
        """.utf8)
        let table = try PricingFeedClient.decode(
            feed: feed, now: now, selector: AntigravityProvider().pricingSelector)
        let neon = try #require(table.rates["gemini-4-neon"])
        let dollars = neon.dollars(for: TokenTally(input: 1_000_000, output: 100_000, cacheRead: 1_000_000))
        #expect(abs(dollars - (3 + 1.5 + 0.15)) < 0.0001)
        #expect(table.rates["gemini-4-argon"] != nil)
        #expect(table.rates.count == 2)
    }

    @Test("no conversations is noLocalData; conversations without transcripts too")
    func noLocalData() async throws {
        let fixture = try AntigravityFixture()
        defer { fixture.tearDown() }
        await #expect(throws: (any Error).self) {
            _ = try await fixture.provider().fetchRawUsage(accessToken: "")
        }
        try fixture.conversation(rows: nil)
        await #expect(throws: (any Error).self) {
            _ = try await fixture.provider().fetchRawUsage(accessToken: "")
        }
    }

    @Test("transcripts but no status-line reading: no limits, fresh")
    func noReadingYet() async throws {
        let fixture = try AntigravityFixture()
        defer { fixture.tearDown() }
        try fixture.conversation(rows: [
            AntigravityFixture.call(at: now.addingTimeInterval(-60), input: 1, output: 1),
        ])
        let provider = fixture.provider()
        let body = try await provider.fetchRawUsage(accessToken: "")
        let snapshot = try provider.snapshot(
            fromRawUsage: body, fetchedAt: now, plan: nil, thresholds: .standard)
        #expect(snapshot.meters.isEmpty)
        #expect(abs(snapshot.fetchedAt.timeIntervalSince(Date())) < 5)
    }

    @Test("v1 meters: Gemini session and weekly, the Claude + GPT pool scoped")
    func bucketTable() throws {
        let reset5h = now.addingTimeInterval(2 * 3600)
        let resetWeek = now.addingTimeInterval(3 * 86400)
        let data = try reading([
            AntigravityStatusLine.bucket("gemini-5h", remaining: 0.82, reset: reset5h),
            AntigravityStatusLine.bucket("gemini-weekly", remaining: 0.59, reset: resetWeek),
            AntigravityStatusLine.bucket("3p-weekly", remaining: 0.93, reset: resetWeek),
            AntigravityStatusLine.bucket("3p-5h", remaining: 0.5, inSeconds: 3600),
            AntigravityStatusLine.bucket("gemini-3-flash-lite-weekly", remaining: 0.1),
            AntigravityStatusLine.bucket("gemini-daily", remaining: 0.4, disabled: true),
            AntigravityStatusLine.bucket("gemini-monthly", amount: 300),
        ], at: now)
        let snapshot = try snapshot(data)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.meters.map { ($0.id, $0) })
        #expect(Set(byID.keys) == ["0-session", "1-weekly", "2-3p-weekly", "2-3p-5h"])

        let session = try #require(byID["0-session"])
        #expect(session.label == "Session (5h)")
        #expect(session.percent == 18)
        #expect(session.rank == 0)
        #expect(session.limitWindow == TimeInterval(5 * 3600))
        #expect(session.resetsAt.map { abs($0.timeIntervalSince(reset5h)) < 1 } == true)
        #expect(UsageFormatting.tag(for: session) == "S")

        let weekly = try #require(byID["1-weekly"])
        #expect(weekly.label == "Weekly")
        #expect(weekly.percent == 41)
        #expect(UsageFormatting.tag(for: weekly) == "W")

        let thirdParty = try #require(byID["2-3p-weekly"])
        #expect(thirdParty.label == "Weekly · Claude + GPT")
        #expect(thirdParty.rank == 2)
        #expect(thirdParty.scopedModelName == "Claude + GPT")
        #expect(UsageFormatting.tag(for: thirdParty) == "C")
        // reset_in_seconds became an absolute time at capture.
        let thirdPartySession = try #require(byID["2-3p-5h"])
        #expect(thirdPartySession.label == "Session (5h) · Claude + GPT")
        #expect(thirdPartySession.resetsAt.map {
            abs($0.timeIntervalSince(now.addingTimeInterval(3600))) < 1
        } == true)

        #expect(UsageFormatting.menuBarSegments(from: snapshot.meters).map(\.tag) == ["S", "W", "C"])
        #expect(snapshot.plan?.subscriptionType == "pro")
    }

    @Test("a reading is as fresh as its capture, whatever the fetch says")
    func freshnessIsTheCapture() throws {
        let captured = now.addingTimeInterval(-2 * 86400)
        let data = try reading([
            AntigravityStatusLine.bucket(
                "gemini-weekly", remaining: 0.7, reset: now.addingTimeInterval(86400)),
        ], at: captured)
        let snapshot = try snapshot(data, fetchedAt: now)
        #expect(abs(snapshot.fetchedAt.timeIntervalSince(captured)) < 1)
        #expect(snapshot.meters.first?.percent == 30)
    }

    @Test("a window that rolled unseen is a dash, unless nothing was used since")
    func rolledWindow() throws {
        let reset = now.addingTimeInterval(-3600)
        let data = try reading([
            AntigravityStatusLine.bucket("gemini-5h", remaining: 0.1, reset: reset),
        ], at: now.addingTimeInterval(-5 * 3600))
        // A conversation was written after the reset: spent, but unseen.
        let used = try snapshot(data, conversationWrittenAt: now.addingTimeInterval(-600))
        #expect(used.meters.first?.percent == nil)
        #expect(used.meters.first?.resetsAt == nil)
        // Nothing written since the reset: the fresh window is untouched.
        let idle = try snapshot(data, conversationWrittenAt: reset.addingTimeInterval(-60))
        #expect(idle.meters.first?.percent == 0)
        #expect(idle.meters.first?.resetsAt == nil)
    }

    @Test("an export the provider can't read surfaces as a schema error")
    func unreadable() {
        #expect(throws: (any Error).self) {
            _ = try AntigravityProvider().snapshot(
                fromRawUsage: Data("nope".utf8), fetchedAt: now, plan: nil, thresholds: .standard)
        }
    }

    @Test("the reduction keeps the quota and drops everything identifying")
    func reduction() throws {
        let payload = AntigravityStatusLine.payload(quota: AntigravityStatusLine.quota([
            #""gemini-weekly":{"remaining_fraction":"0.25","reset_in_seconds":86400}"#,
            AntigravityStatusLine.bucket("bad id with spaces", remaining: 0.5),
        ]))
        let kept = try #require(AntigravityQuota.reduce(statusLine: payload, now: now))
        let text = try #require(String(data: kept, encoding: .utf8))
        for secret in ["person@example.com", "secret-project", "transcript", "SECRET", "total_usd",
                       "gemini-4-neon", "bad id"] {
            #expect(!text.contains(secret), "\(secret) leaked into the export")
        }
        let reading = try #require(AntigravityQuota.decodeReading(kept))
        #expect(reading.buckets.map(\.id) == ["gemini-weekly"])
        #expect(reading.buckets.first?.remainingFraction == 0.25)
        #expect(reading.planTier == "pro")
        #expect(reading.cliVersion == "1.5.14")
        // No quota at all — an API-key sign-in — keeps nothing.
        #expect(AntigravityQuota.reduce(
            statusLine: AntigravityStatusLine.payload(quota: nil), now: now) == nil)
        #expect(AntigravityQuota.reduce(
            statusLine: AntigravityStatusLine.payload(quota: "{}"), now: now) == nil)
        #expect(AntigravityQuota.reduce(statusLine: Data("[1,2".utf8), now: now) == nil)
        // An email-shaped tier is not a tier.
        let odd = AntigravityStatusLine.payload(
            quota: AntigravityStatusLine.quota([AntigravityStatusLine.bucket("gemini-5h", remaining: 1)]),
            planTier: "x@y.z")
        let oddReading = try #require(
            AntigravityQuota.reduce(statusLine: odd, now: now).flatMap(AntigravityQuota.decodeReading))
        #expect(oddReading.planTier == nil)
    }

    @Test("a reading differs only when a meter would show it")
    func differs() throws {
        let reset = now.addingTimeInterval(4 * 3600)
        func make(_ remaining: Double, reset: Date, tier: String = "pro", at: Date) throws -> Data {
            try #require(AntigravityQuota.reduce(
                statusLine: AntigravityStatusLine.payload(
                    quota: AntigravityStatusLine.quota([
                        AntigravityStatusLine.bucket("gemini-5h", remaining: remaining, reset: reset),
                    ]), planTier: tier),
                now: at))
        }
        let base = try make(0.800, reset: reset, at: now)
        #expect(!AntigravityQuota.differs(
            stored: base, fresh: try make(0.801, reset: reset.addingTimeInterval(20), at: now + 30)))
        #expect(AntigravityQuota.differs(stored: base, fresh: try make(0.78, reset: reset, at: now)))
        #expect(AntigravityQuota.differs(
            stored: base, fresh: try make(0.8, reset: reset.addingTimeInterval(3600), at: now)))
        #expect(AntigravityQuota.differs(
            stored: base, fresh: try make(0.8, reset: reset, tier: "ultra", at: now)))
        #expect(AntigravityQuota.differs(stored: Data("junk".utf8), fresh: base))
    }

    @Test("bucket ids name their pool and window, or nothing")
    func shapes() {
        #expect(AntigravityQuota.shape(of: "gemini-5h")
            == .init(pool: .gemini, window: 5 * 3600))
        #expect(AntigravityQuota.shape(of: "3p-weekly")
            == .init(pool: .thirdParty, window: 7 * 86400))
        #expect(AntigravityQuota.shape(of: "gemini-2d")
            == .init(pool: .gemini, window: 2 * 86400))
        #expect(AntigravityQuota.shape(of: "gemini-4-argon-weekly") == nil)
        #expect(AntigravityQuota.shape(of: "gemini-soon") == nil)
        #expect(AntigravityQuota.shape(of: "image-weekly") == nil)
    }
}
