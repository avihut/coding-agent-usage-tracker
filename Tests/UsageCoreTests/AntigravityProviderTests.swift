import Foundation
import Testing

@testable import UsageCore

@Suite("Antigravity provider")
struct AntigravityProviderTests {
    private let now = AntigravityQuotaFixture.capturedNow

    private func reduce(_ stdout: Data, exit: Int32 = 0, stderr: String = "") -> AgentQuotaOutcome {
        AntigravityQuota.reduce(exitStatus: exit, stdout: stdout, stderr: Data(stderr.utf8), now: now)
    }

    private func buckets(_ stdout: Data) throws -> [AgentQuotaBucket] {
        guard case .buckets(let buckets) = reduce(stdout) else {
            Issue.record("expected buckets")
            return []
        }
        return buckets
    }

    private func snapshot(
        _ buckets: [AgentQuotaBucket]?, capturedAt: Date? = nil,
        conversationWrittenAt: Date? = nil, fetchedAt: Date? = nil
    ) throws -> Snapshot {
        let captured = capturedAt ?? now
        let payload = AntigravityUsagePayload(
            fetchedAt: fetchedAt ?? now,
            reading: buckets.map {
                AgentQuotaReading(startedAt: captured.addingTimeInterval(-2), capturedAt: captured, buckets: $0)
            },
            conversationWrittenAt: conversationWrittenAt)
        return try AntigravityQuota.snapshot(
            fromPayload: AntigravityQuota.encodePayload(payload), thresholds: .standard, now: now)
    }

    private func stamp(_ offset: TimeInterval) -> String {
        AntigravityFixture.stamp(now.addingTimeInterval(offset))
    }

    @Test("identity is provider data: ∩, violet, local, no credentials, its own CLI for limits")
    func identity() throws {
        let provider = AntigravityProvider()
        #expect(provider.id == "antigravity")
        #expect(provider.agentName == "Antigravity CLI")
        #expect(provider.menuBarGlyph == "∩")
        #expect(provider.accent == ProviderAccent(red: 0.631, green: 0.259, blue: 0.957))
        // The CLI the probe runs talks to Google itself: no destination here.
        #expect(provider.networkDestinations.isEmpty)
        #expect(provider.statusFeed == nil)
        #expect(provider.accountIdentity == nil)
        #expect(provider.agentSettings == nil)
        #expect(provider.deprecationNote == nil)
        #expect(!provider.supportsMultipleHomes)
        #expect(HarnessResolution.standardProviders().last?.id == "antigravity")
        let command = try #require(provider.quotaCommand)
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(command.executableCandidates.map(\.path) == [
            home.appending(path: ".local/bin/agy").path, "/opt/homebrew/bin/agy", "/usr/local/bin/agy",
        ])
        #expect(!command.executableCandidates.contains { $0.path.contains(".antigravity") })
        #expect(command.versionArguments == ["--version"])
        #expect(command.environment == ["AGY_CLI_DISABLE_AUTO_UPDATE": "true"])
        #expect(command.privacyLines.count == 3)
    }

    @Test("its models read and price as Gemini's, and its pool's as their vendors'")
    func modelsAndPricing() {
        let provider = AntigravityProvider()
        #expect(provider.modelCatalog.displayName("gemini-4-neon") == "Gemini 4 Neon")
        #expect(provider.modelCatalog.displayName("claude-sonnet-4-5")
            == ModelCatalog.claude.displayName("claude-sonnet-4-5"))
        #expect(provider.pricingSelector.normalizeKey("gemini/gemini-4-neon") == "gemini-4-neon")
        #expect(provider.pricingSelector.includes("gemini/gemini-4-neon", "gemini"))
    }

    /// The rates the feed carries for Antigravity's models sit under
    /// `gemini/`; a synthetic fragment proves the provider's own slice picks
    /// them up and keys them the way transcripts name them.
    @Test("its models price through Gemini's feed slice; the pool's through theirs")
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
        let thirdParty = Data("""
        {"claude-sonnet-4-5":{"litellm_provider":"anthropic","input_cost_per_token":0.000003,
          "output_cost_per_token":0.000015},
         "gpt-5.1":{"litellm_provider":"openai","input_cost_per_token":0.000001,
          "output_cost_per_token":0.00001},
         "openai/gpt-5.1":{"litellm_provider":"openai","input_cost_per_token":9,
          "output_cost_per_token":9}}
        """.utf8)
        let other = try PricingFeedClient.decode(
            feed: thirdParty, now: now, selector: AntigravityProvider().pricingSelector)
        #expect(Set(other.rates.keys) == ["claude-sonnet-4-5", "gpt-5.1"])
    }

    @Test("its rates table lists what it ran plus Gemini's, not every vendor's catalogue")
    func ratesListing() {
        let provider = AntigravityProvider()
        #expect(provider.listsUnseenRate("gemini-4-neon"))
        #expect(provider.listsUnseenRate("gemini-3.8-flash"))
        #expect(!provider.listsUnseenRate("claude-opus-5-5"))
        #expect(!provider.listsUnseenRate("gpt-oss-120b"))
        // Every other harness lists its whole slice, as before.
        #expect(CodexProvider().listsUnseenRate("gpt-5.1"))
    }

    @Test("no conversations and no reading is noLocalData; conversations without transcripts too")
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
        // A reading alone (transcripts pruned) still renders.
        let reading = AgentQuotaReading(startedAt: now, capturedAt: now, buckets: [])
        _ = try await fixture.provider().fetchRawUsage(accessToken: "", quota: reading)
    }

    @Test("transcripts but no reading yet: no limits, fresh")
    func noReadingYet() async throws {
        let fixture = try AntigravityFixture()
        defer { fixture.tearDown() }
        try fixture.conversation(rows: [
            AntigravityFixture.call(at: Date().addingTimeInterval(-60), input: 1, output: 1),
        ])
        let provider = fixture.provider()
        let body = try await provider.fetchRawUsage(accessToken: "")
        let snapshot = try provider.snapshot(
            fromRawUsage: body, fetchedAt: now, plan: nil, thresholds: .standard)
        #expect(snapshot.meters.isEmpty)
        #expect(abs(snapshot.fetchedAt.timeIntervalSince(Date())) < 5)
    }

    /// The person's own `/usage` screen at the moment of the capture read:
    /// Gemini weekly 76.86% left, 5h 74.62%, Claude + GPT 100% / 100%
    /// ("Quota available"), Gemini 4 Argon weekly 98.20%.
    @Test("the real reading: every pool the plan reports, as the CLI's own screen shows it")
    func realReading() throws {
        let read = try buckets(try AntigravityQuotaFixture.real())
        #expect(read.map(\.id)
            == ["gemini-weekly", "gemini-5h", "3p-weekly", "3p-5h", "gemini-argon-wtu-weekly"])
        // The untouched pool's epoch reset is no reset.
        #expect(read.first { $0.id == "3p-5h" }?.resetsAt == nil)
        #expect(read.first { $0.id == "3p-5h" }?.remainingFraction == 1)

        let snapshot = try snapshot(read)
        #expect(snapshot.meters.map(\.label)
            == ["Session (5h)", "Weekly", "Claude + GPT (5h)", "Claude + GPT (7d)", "Argon (7d)"])
        #expect(snapshot.meters.map(\.percent) == [25, 23, 0, 0, 2])
        #expect(snapshot.meters.map(UsageFormatting.tag(for:)) == ["S", "W", "C", "C", "A"])
        let byLabel = Dictionary(uniqueKeysWithValues: snapshot.meters.map { ($0.label, $0) })
        let session = try #require(byLabel["Session (5h)"])
        #expect(session.limitWindow == TimeInterval(5 * 3600))
        // 00:02:05Z is 2 h 54 m after the screen's 21:08Z ("2h 53m").
        #expect(session.resetsAt.map { abs($0.timeIntervalSince(now) - (2 * 3600 + 54 * 60 + 5)) < 0.5 }
            == true)
        let pool = try #require(byLabel["Claude + GPT (7d)"])
        #expect(pool.resetsAt == nil)
        #expect(pool.scopedModelName == "Claude + GPT")
        let argon = try #require(byLabel["Argon (7d)"])
        #expect(argon.rank == 2 && argon.scopedModelName == "Argon")
        #expect(argon.limitWindow == TimeInterval(7 * 86400))
        #expect(snapshot.plan == nil)
        #expect(snapshot.fetchedAt == now)

        // `usage-cli limits session|weekly` must each still name ONE meter.
        for word in ["session", "weekly"] {
            #expect(snapshot.meters.filter { $0.label.lowercased().contains(word) }.count == 1)
        }
        // The bar: S, W, and one scoped segment — the most-used scoped meter.
        #expect(UsageFormatting.menuBarSegments(from: snapshot.meters).map(\.tag) == ["S", "W", "A"])
    }

    @Test("each pool counts its own models; Gemini's excludes Argon when the plan meters it apart")
    func scopes() throws {
        let read = try buckets(try AntigravityQuotaFixture.real())
        let meters = try snapshot(read).meters
        let byLabel = Dictionary(uniqueKeysWithValues: meters.map { ($0.label, $0) })
        let session = try #require(byLabel["Session (5h)"])
        let weekly = try #require(byLabel["Weekly"])
        let pool = try #require(byLabel["Claude + GPT (5h)"])
        let argon = try #require(byLabel["Argon (7d)"])
        #expect(session.inScope("gemini-4-neon") && session.inScope("gemini-3.8-flash"))
        #expect(!session.inScope("gemini-4-argon") && !session.inScope("claude-opus-5-5"))
        #expect(argon.inScope("gemini-4-argon") && !argon.inScope("gemini-4-neon"))
        #expect(pool.inScope("claude-opus-5-5") && pool.inScope("gpt-oss-120b"))
        #expect(!pool.inScope("gemini-4-neon"))
        #expect(session.countedScope == weekly.countedScope)

        // Without a separate Argon bucket (a plan that folds Argon into the
        // Gemini pool), Gemini's meters count Argon too.
        let folded = try snapshot(read.filter { $0.id != "gemini-argon-wtu-weekly" }).meters
        #expect(folded.first { $0.label == "Weekly" }?.inScope("gemini-4-argon") == true)
        #expect(folded.first { $0.label == "Weekly" }?.countedScope == ["gemini"])
    }

    @Test("an exclusion needle excludes; an older reader's literal match never fires")
    func exclusionNeedles() {
        #expect(Meter.inScope("gemini-4-neon", needles: ["gemini", "!argon"]))
        #expect(!Meter.inScope("gemini-4-argon-low", needles: ["gemini", "!argon"]))
        #expect(Meter.inScope("anything", needles: ["!argon"]))
        #expect(!Meter.inScope("gemini-4-argon", needles: ["!argon"]))
        #expect(!Meter.inScope("claude-opus", needles: ["gemini", "!argon"]))
        #expect(Meter.inScope("x", needles: nil) && Meter.inScope("x", needles: []))
        // What a pre-exclusion reader did with the same needles: "!argon"
        // as a literal matches no id, so it counts the pool whole.
        #expect(["gemini", "!argon"].contains { "gemini-4-argon".contains($0) })
    }

    @Test("lockouts stay inside a pool")
    func lockoutsStayInPool() throws {
        let spent = try buckets(AntigravityQuotaFixture.output([
            AntigravityQuotaFixture.bucket("gemini-5h", window: "5h", remaining: 0, reset: stamp(3600)),
            AntigravityQuotaFixture.bucket("gemini-weekly", window: "weekly", remaining: 0.5, reset: stamp(86400)),
            AntigravityQuotaFixture.bucket("3p-5h", window: "5h", remaining: 0, reset: stamp(3600)),
            AntigravityQuotaFixture.bucket("3p-weekly", window: "weekly", remaining: 0.5, reset: stamp(86400)),
            AntigravityQuotaFixture.bucket(
                "gemini-argon-wtu-weekly", window: "weekly", remaining: 0.5, reset: stamp(86400)),
        ]))
        let meters = try snapshot(spent).meters
        let byLabel = Dictionary(uniqueKeysWithValues: meters.map { ($0.label, $0) })
        let gemini5h = try #require(byLabel["Session (5h)"])
        let pool5h = try #require(byLabel["Claude + GPT (5h)"])
        // Only meters whose scope covers another's gate it: Gemini's 5h
        // gates Gemini's weekly, the pool's its own, nothing gates Argon.
        for other in meters where other.id != gemini5h.id {
            let gates = other.countedScope == nil || other.countedScope == gemini5h.countedScope
            #expect(gates == (other.label == "Weekly"), "\(other.label)")
        }
        for other in meters where other.id != pool5h.id {
            let gates = other.countedScope == nil || other.countedScope == pool5h.countedScope
            #expect(gates == (other.label == "Claude + GPT (7d)"), "\(other.label)")
        }
    }

    @Test("a reading is as fresh as its capture, whatever the fetch says")
    func freshnessIsTheCapture() throws {
        let captured = now.addingTimeInterval(-2 * 86400)
        let snapshot = try snapshot(
            [AgentQuotaBucket(id: "gemini-weekly", remainingFraction: 0.7, resetsAt: now.addingTimeInterval(86400))],
            capturedAt: captured)
        #expect(snapshot.fetchedAt == captured)
        #expect(snapshot.meters.first?.percent == 30)
    }

    @Test("a window that rolled unseen is a dash, unless nothing was used since")
    func rolledWindow() throws {
        let reset = now.addingTimeInterval(-3600)
        let read = [AgentQuotaBucket(id: "gemini-5h", remainingFraction: 0.1, resetsAt: reset)]
        let captured = now.addingTimeInterval(-5 * 3600)
        let used = try snapshot(read, capturedAt: captured, conversationWrittenAt: now.addingTimeInterval(-600))
        #expect(used.meters.first?.percent == nil)
        #expect(used.meters.first?.resetsAt == nil)
        let idle = try snapshot(read, capturedAt: captured, conversationWrittenAt: reset.addingTimeInterval(-60))
        #expect(idle.meters.first?.percent == 0)
        #expect(idle.meters.first?.resetsAt == nil)
        let unknown = try snapshot(read, capturedAt: captured, conversationWrittenAt: nil)
        #expect(unknown.meters.first?.percent == nil)
        let replayed = try snapshot(
            read, capturedAt: captured, conversationWrittenAt: reset.addingTimeInterval(-600),
            fetchedAt: reset.addingTimeInterval(-300))
        #expect(replayed.meters.first?.percent == nil)
    }

    /// The digest carries a stated scope (additive), so a client-mode app
    /// filters a pool's curves the way the host does — and a meter without
    /// one encodes exactly as before.
    @Test("a meter's model scope rides the digest only when stated")
    func scopeInDigest() throws {
        func card(_ scope: [String]?) -> LiveMeter {
            LiveMeter(
                id: "1-weekly", label: "Weekly", tag: "W", percent: 7,
                level: "normal", rank: 1, rateWindowSeconds: 14400, forcesWarning: false,
                risk: nil, resetsAt: nil, limitWindow: 604_800, scopedModelName: nil,
                resetCaption: nil, forecast: nil, series: [], stretches: [], modelScope: scope)
        }
        let scoped = try LiveState.encoder().encode(card(["gemini", "!argon"]))
        let decoded = try LiveState.decoder().decode(LiveMeter.self, from: scoped)
        #expect(decoded.modelScope == ["gemini", "!argon"])
        let plain = try LiveState.encoder().encode(card(nil))
        #expect(!(String(data: plain, encoding: .utf8) ?? "").contains("modelScope"))
        #expect(Meter.countedScope(modelScope: nil, scopedModelName: "Fable") == ["fable"])
        #expect(Meter.countedScope(modelScope: nil, scopedModelName: nil) == nil)
    }

    @Test("a garbage reading can't crash the engine")
    func garbageBounds() throws {
        #expect(AntigravityQuota.windowLength("3000000000000000h") == nil)
        #expect(AntigravityQuota.windowLength("0h") == nil)
        #expect(AntigravityQuota.windowLength("10000d") == TimeInterval(10_000 * 86400))
        #expect(AntigravityQuota.usedPercent(5) == 0)
        #expect(AntigravityQuota.usedPercent(-3) == 100)
        #expect(AntigravityQuota.usedPercent(1e300) == 0)
        // A stored reading with an absurd id and fraction decodes to meters
        // without trapping.
        let stored = Data("""
        {"fetchedAt":"2026-11-21T21:08:00Z","reading":{"startedAt":"2026-11-21T21:07:58Z",
          "capturedAt":"2026-11-21T21:08:00Z","buckets":[
          {"id":"gemini-3000000000000000h","remainingFraction":0.5},
          {"id":"gemini-weekly","remainingFraction":1e300}]}}
        """.utf8)
        let snapshot = try AntigravityQuota.snapshot(fromPayload: stored, thresholds: .standard, now: now)
        #expect(snapshot.meters.map(\.label) == ["Weekly"])
        #expect(snapshot.meters.first?.percent == 0)
    }

    @Test("an unexpected field drops only itself; a spent bucket with no fraction is 100%")
    func lenientPayload() throws {
        let output = Data("""
        {"status":"SUCCESS","command":{"data":{"groups":[
          {"buckets":[
            {"id":"gemini-weekly","window":"weekly","reset_time":"\(stamp(3600))"},
            {"id":"gemini-5h","window":"5h","remaining_fraction":"0.5","reset_time":"\(stamp(3600))"},
            {"id":"3p-weekly","window":"weekly","reset_time":"1970-01-01T00:00:00Z"},
            {"id":"3p-5h","window":"5h","remaining_fraction":0.9,"reset_time":"9999-01-01T00:00:00Z"},
            {"id":17,"remaining_fraction":0.5},
            {"id":"gemini-daily","window":"weekly","remaining_fraction":0.5},
            {"id":"bad id with spaces","remaining_fraction":0.5},
            {"id":"gemini-5h","remaining_fraction":0.1}]},
          "not a group",
          {"buckets":"nope"}]}}}
        """.utf8)
        let read = try buckets(output)
        let byID = Dictionary(uniqueKeysWithValues: read.map { ($0.id, $0) })
        #expect(Set(byID.keys) == ["gemini-weekly", "gemini-5h", "3p-weekly", "3p-5h"])
        // Fraction omitted, a REAL reset ahead: spent, not dropped.
        #expect(byID["gemini-weekly"]?.remainingFraction == 0)
        // Fraction omitted, the epoch: not spent — nothing to draw.
        #expect(byID["3p-weekly"]?.remainingFraction == nil)
        #expect(byID["3p-weekly"]?.resetsAt == nil)
        // A numeric string reads; an absurd distance is no reset; the first
        // of a repeated id wins.
        #expect(byID["gemini-5h"]?.remainingFraction == 0.5)
        #expect(byID["3p-5h"]?.resetsAt == nil)
        let meters = try snapshot(read).meters
        #expect(meters.first { $0.label == "Weekly" }?.percent == 100)
        #expect(!meters.contains { $0.label == "Claude + GPT (7d)" })
    }

    @Test("what isn't a limits report fails readably, and an empty one is no limits")
    func failuresAndEmpty() throws {
        #expect(reduce(Data()) == .failure(.unreadable))
        #expect(reduce(Data("Gemini Models\tWeekly Limit Remaining\t77%".utf8)) == .failure(.unreadable))
        #expect(reduce(Data(try AntigravityQuotaFixture.real().prefix(900))) == .failure(.unreadable))
        #expect(reduce(Data(#"{"status":"SUCCESS","response":"x"}"#.utf8)) == .failure(.unreadable))
        #expect(reduce(Data(#"{"status":"ERROR","response":"x"}"#.utf8)) == .failure(.failed))
        #expect(reduce(Data(), exit: 1, stderr: "AGY_ERROR: {\"status\":\"UNAVAILABLE\"}") == .failure(.failed))
        #expect(reduce(Data(), exit: 1, stderr: "You are not logged into Antigravity.") == .failure(.notSignedIn))
        #expect(reduce(
            Data(#"{"status":"ERROR","response":"Authentication expired. Please log back in."}"#.utf8))
            == .failure(.notSignedIn))
        // A sign-in with no plan quota (an API key) reports a command with
        // nothing in it: no limits, not an error.
        #expect(reduce(Data(#"{"status":"SUCCESS","command":{"name":"usage","data":{}}}"#.utf8))
            == .buckets([]))
    }

    @Test("only bucket numbers are kept — nothing the output says in words")
    func keepsNumbersOnly() throws {
        let read = try buckets(try AntigravityQuotaFixture.real())
        let reading = AgentQuotaReading(startedAt: now, capturedAt: now, buckets: read)
        let text = try #require(String(data: try JSONEncoder().encode(reading), encoding: .utf8))
        #expect(!text.contains("placeholder"))
        #expect(!text.lowercased().contains("description"))
    }

    @Test("bucket ids name their pool and window, or nothing")
    func shapes() {
        #expect(AntigravityQuota.shape(of: "gemini-5h") == .init(pool: .gemini, window: 5 * 3600))
        #expect(AntigravityQuota.shape(of: "3p-weekly") == .init(pool: .thirdParty, window: 7 * 86400))
        #expect(AntigravityQuota.shape(of: "gemini-2d") == .init(pool: .gemini, window: 2 * 86400))
        #expect(AntigravityQuota.shape(of: "gemini-argon-wtu-weekly")
            == .init(pool: .argon, window: 7 * 86400))
        #expect(AntigravityQuota.shape(of: "gemini-4-argon-weekly") == nil)
        #expect(AntigravityQuota.shape(of: "gemini-soon") == nil)
        #expect(AntigravityQuota.shape(of: "image-weekly") == nil)
    }

    @Test("a body the provider can't read surfaces as a schema error")
    func unreadableBody() {
        #expect(throws: (any Error).self) {
            _ = try AntigravityProvider().snapshot(
                fromRawUsage: Data("nope".utf8), fetchedAt: now, plan: nil, thresholds: .standard)
        }
    }
}
