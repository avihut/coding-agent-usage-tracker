import Foundation
import Testing
@testable import UsageCore

@Suite("CodexProvider")
struct CodexProviderTests {
    /// Feb-2026 CLI schema: rate_limits carries primary/secondary directly.
    private static func tokenCountLine(
        stamp: String, primaryPercent: Double, primaryReset: Int,
        secondaryPercent: Double, secondaryReset: Int, extras: String = ""
    ) -> String {
        """
        {"timestamp":"\(stamp)","type":"event_msg","payload":{"type":"token_count",\
        "info":{"total_token_usage":{"input_tokens":17685,"cached_input_tokens":4352,\
        "output_tokens":474,"reasoning_output_tokens":275,"total_tokens":18159},\
        "last_token_usage":{"input_tokens":1000,"cached_input_tokens":600,\
        "output_tokens":200,"reasoning_output_tokens":50,"total_tokens":1200},\
        "model_context_window":258400},"rate_limits":{\(extras)"primary":{"used_percent":\(primaryPercent),\
        "window_minutes":300,"resets_at":\(primaryReset)},"secondary":{"used_percent":\(secondaryPercent),\
        "window_minutes":10080,"resets_at":\(secondaryReset)},\
        "credits":{"has_credits":false,"unlimited":false,"balance":null},"plan_type":"plus"}}}
        """
    }

    /// A local-model session's token_count: limits present but empty.
    private static func emptyLimitsLine(stamp: String) -> String {
        """
        {"timestamp":"\(stamp)","type":"event_msg","payload":{"type":"token_count",\
        "info":{"last_token_usage":{"input_tokens":500,"cached_input_tokens":100,\
        "output_tokens":80,"total_tokens":580}},"rate_limits":{"limit_id":"codex",\
        "limit_name":null,"primary":null,"secondary":null,"credits":null,\
        "plan_type":null,"rate_limit_reached_type":null}}}
        """
    }

    private static func turnContextLine(stamp: String, model: String) -> String {
        """
        {"timestamp":"\(stamp)","type":"turn_context","payload":{"cwd":"/tmp",\
        "model":"\(model)","effort":"high"}}
        """
    }

    private static func userMessageLine(stamp: String) -> String {
        """
        {"timestamp":"\(stamp)","type":"event_msg","payload":{"type":"user_message",\
        "info":null,"rate_limits":null}}
        """
    }

    @Test("meters map primary→session and secondary→weekly with served percents")
    func meterMapping() throws {
        let fixture = try CodexFixture()
        defer { fixture.tearDown() }
        let now = try #require(FlexibleISO8601.date(from: "2026-02-07T15:00:00.000Z"))
        let reset = Int(now.timeIntervalSince1970) + 3600
        try fixture.writeRollout(
            "2026/02/07/rollout-a.jsonl",
            lines: [Self.tokenCountLine(
                stamp: "2026-02-07T14:26:55.123Z",
                primaryPercent: 25.4, primaryReset: reset,
                secondaryPercent: 80.6, secondaryReset: reset + 86400)])

        let payload = try CodexRollouts.latestUsagePayload(root: fixture.root)
        let snapshot = try CodexMeterBuilder.snapshot(
            fromPayload: payload, thresholds: .standard, now: now)

        let session = try #require(snapshot.meters.first { $0.rank == 0 })
        #expect(session.label == "Session (5h)")
        #expect(session.percent == 25)
        #expect(session.limitWindow == TimeInterval(5 * 3600))
        #expect(session.rateWindow == 45 * 60)
        #expect(session.resetsAt == Date(timeIntervalSince1970: TimeInterval(reset)))
        let weekly = try #require(snapshot.meters.first { $0.rank == 1 })
        #expect(weekly.label == "Weekly")
        #expect(weekly.percent == 81)
        #expect(weekly.limitWindow == TimeInterval(7 * 86400))
        #expect(snapshot.plan?.subscriptionType == "plus")
        #expect(snapshot.fetchedAt
            == FlexibleISO8601.date(from: "2026-02-07T14:26:55.123Z"))
    }

    @Test("an expired window reads 0% with no reset — the window rolled over")
    func expiredWindowAges() throws {
        let fixture = try CodexFixture()
        defer { fixture.tearDown() }
        let now = try #require(FlexibleISO8601.date(from: "2026-03-01T00:00:00.000Z"))
        let pastReset = Int(now.timeIntervalSince1970) - 86400
        try fixture.writeRollout(
            "2026/02/07/rollout-a.jsonl",
            lines: [Self.tokenCountLine(
                stamp: "2026-02-07T14:26:55.123Z",
                primaryPercent: 87, primaryReset: pastReset,
                secondaryPercent: 40, secondaryReset: pastReset + 3600)])

        let payload = try CodexRollouts.latestUsagePayload(root: fixture.root)
        let snapshot = try CodexMeterBuilder.snapshot(
            fromPayload: payload, thresholds: .standard, now: now)

        for meter in snapshot.meters {
            #expect(meter.percent == 0)
            #expect(meter.resetsAt == nil)
        }
    }

    @Test("the newest populated snapshot wins; empty-limits sessions are walked past")
    func walkBackPastLocalSessions() throws {
        let fixture = try CodexFixture()
        defer { fixture.tearDown() }
        let now = Date()
        let reset = Int(now.timeIntervalSince1970) + 3600
        // Older file: real ChatGPT-backed session with limits.
        try fixture.writeRollout(
            "2026/02/07/rollout-old.jsonl",
            lines: [Self.tokenCountLine(
                stamp: "2026-02-07T14:26:55.123Z",
                primaryPercent: 55, primaryReset: reset,
                secondaryPercent: 10, secondaryReset: reset,
                extras: "\"limit_id\":\"codex\",\"rate_limit_reached_type\":null,")],
            age: 7200)
        // Newest file: local-model session, limits empty.
        try fixture.writeRollout(
            "2026/05/16/rollout-new.jsonl",
            lines: [Self.emptyLimitsLine(stamp: "2026-05-16T11:33:05.123Z")],
            age: 60)

        let payload = try CodexRollouts.latestUsagePayload(root: fixture.root)
        let snapshot = try CodexMeterBuilder.snapshot(
            fromPayload: payload, thresholds: .standard, now: now)

        #expect(snapshot.meters.first { $0.rank == 0 }?.percent == 55)
    }

    @Test("no rollouts at all throws noLocalData")
    func noLocalData() throws {
        let fixture = try CodexFixture()
        defer { fixture.tearDown() }
        #expect(throws: (any Error).self) {
            try CodexRollouts.latestUsagePayload(root: fixture.root)
        }
    }

    @Test("activity scan attributes token deltas to the turn's model")
    func activityScan() throws {
        let fixture = try CodexFixture()
        defer { fixture.tearDown() }
        let now = Date()
        let reset = Int(now.timeIntervalSince1970) + 3600
        let stamp = "2026-08-15T10:00:30.000Z"
        try fixture.writeRollout(
            "2026/08/15/rollout-a.jsonl",
            lines: [
                Self.turnContextLine(stamp: "2026-08-15T10:00:00.000Z", model: "gpt-5.2-codex"),
                Self.userMessageLine(stamp: "2026-08-15T10:00:10.000Z"),
                Self.tokenCountLine(
                    stamp: stamp, primaryPercent: 1, primaryReset: reset,
                    secondaryPercent: 1, secondaryReset: reset),
                Self.tokenCountLine(
                    stamp: "2026-08-15T10:00:45.000Z", primaryPercent: 2, primaryReset: reset,
                    secondaryPercent: 2, secondaryReset: reset),
            ])
        let source = CodexActivitySource(
            root: fixture.root, cacheDirectory: fixture.cacheDirectory)

        let scan = source.scanTranscripts(now: now)

        let day = try #require(scan.daily.first)
        // Two token_count events × last_token_usage 1200 each.
        #expect(day.tokens == 2400)
        #expect(day.messages == 2)
        #expect(day.prompts == 1)
        let model = try #require(day.models["gpt-5.2-codex"])
        // Per event: input 1000 splits into 400 fresh + 600 cache reads.
        #expect(model.input == 800)
        #expect(model.cacheRead == 1200)
        #expect(model.output == 400)
        #expect(model.cacheCreation == 0)
        // Both events fall inside one minute → they merge into one slot.
        let slot = try #require(scan.timeline.first)
        #expect(scan.timeline.count == 1)
        #expect(slot.model == "gpt-5.2-codex")
        #expect(slot.tally.total == 2400)

        // Second scan reuses the cache and reports identically.
        let rescan = source.scanTranscripts(now: now)
        #expect(rescan.daily == scan.daily)
        #expect(rescan.timeline == scan.timeline)
    }

    private static func sessionMetaLine(stamp: String, cwd: String) -> String {
        """
        {"timestamp":"\(stamp)","type":"session_meta","payload":{"id":"x","cwd":"\(cwd)",\
        "cli_version":"0.44.0","originator":"codex_cli_rs","source":"cli"}}
        """
    }

    private static func promptLine(stamp: String, text: String) -> String {
        """
        {"timestamp":"\(stamp)","type":"event_msg","payload":{"type":"user_message",\
        "message":"\(text)","images":null}}
        """
    }

    @Test("rollouts list as sessions: one file one session, derived counts, detail rows")
    func sessions() throws {
        let fixture = try CodexFixture()
        defer { fixture.tearDown() }
        let reset = Int(Date().timeIntervalSince1970) + 3600
        try fixture.writeRollout(
            "2026/08/15/rollout-b.jsonl",
            lines: [
                Self.sessionMetaLine(stamp: "2026-08-15T10:00:00.000Z", cwd: "/Users/dev/tool"),
                Self.turnContextLine(stamp: "2026-08-15T10:00:05.000Z", model: "gpt-5.2-codex"),
                Self.promptLine(stamp: "2026-08-15T10:00:10.000Z", text: "port the scanner"),
                Self.tokenCountLine(
                    stamp: "2026-08-15T10:00:30.000Z", primaryPercent: 1, primaryReset: reset,
                    secondaryPercent: 1, secondaryReset: reset),
                Self.tokenCountLine(
                    stamp: "2026-08-15T10:20:30.000Z", primaryPercent: 2, primaryReset: reset,
                    secondaryPercent: 2, secondaryReset: reset),
            ])
        let source = CodexActivitySource(
            root: fixture.root, cacheDirectory: fixture.cacheDirectory)

        let sessions = source.scanTranscripts(now: Date()).sessions
        #expect(sessions.count == 1)
        let s = try #require(sessions.first)
        #expect(s.id == "rollout-b")
        #expect(s.title == "port the scanner")
        #expect(s.projectPath == "/Users/dev/tool")
        #expect(s.agentVersion == "0.44.0")
        #expect(s.kind == .interactive)
        #expect(s.prompts == 1)
        #expect(s.apiCalls == 2)
        #expect(s.models["gpt-5.2-codex"]?.total == 2400)
        #expect(s.start == FlexibleISO8601.date(from: "2026-08-15T10:00:10.000Z"))
        #expect(s.end == FlexibleISO8601.date(from: "2026-08-15T10:20:30.000Z"))
        // Two active minutes 20 min apart — beyond grace, so two 60s
        // stretches, never a stitched span.
        #expect(s.activeSeconds == TimeInterval(120))

        let detail = try #require(source.sessionDetail(id: "rollout-b"))
        #expect(detail.rows.count == 3)
        #expect(detail.rows[0].kind == .prompt(preview: "port the scanner"))
        if case .apiCall(let model, let tally, _) = detail.rows[1].kind {
            #expect(model == "gpt-5.2-codex")
            #expect(tally.total == 1200)
        } else {
            Issue.record("expected a call row")
        }
        #expect(detail.summary.apiCalls == 2)
        #expect(source.sessionDetail(id: "rollout-nope") == nil)
    }

    @Test("provider identity: local-only, credential-free, retention-free")
    func providerIdentity() throws {
        let provider = CodexProvider()
        #expect(provider.networkDestinations.isEmpty)
        #expect(provider.menuBarGlyph == "⬡")
        #expect(provider.agentSettings == nil)
        #expect(provider.bundledRates.rates.isEmpty)
        let credential = try provider.credentials.readCredential()
        #expect(credential.accessToken.isEmpty)
    }

    @Test("provider round-trip: fetch serializes, snapshot decodes")
    func providerRoundTrip() async throws {
        let fixture = try CodexFixture()
        defer { fixture.tearDown() }
        let reset = Int(Date().timeIntervalSince1970) + 3600
        try fixture.writeRollout(
            "2026/08/15/rollout-a.jsonl",
            lines: [Self.tokenCountLine(
                stamp: "2026-08-15T10:00:30.000Z", primaryPercent: 12, primaryReset: reset,
                secondaryPercent: 34, secondaryReset: reset)])
        let provider = CodexProvider(sessionsRoot: fixture.root)

        let body = try await provider.fetchRawUsage(accessToken: "")
        let snapshot = try provider.snapshot(
            fromRawUsage: body, fetchedAt: Date(), plan: nil, thresholds: .standard)

        #expect(snapshot.meters.count == 2)
        #expect(snapshot.meters.first { $0.rank == 1 }?.percent == 34)
    }

    @Test("codex catalog: display names, families, tiers")
    func codexCatalog() {
        let catalog = ModelCatalog.codex
        #expect(catalog.displayName("gpt-5.2-codex") == "GPT 5.2 Codex")
        #expect(catalog.displayName("unknown") == "Other")
        #expect(catalog.familyName("gpt-5.2-codex") == "Codex")
        #expect(catalog.familyName("gpt-6") == "GPT")
        #expect(catalog.familyRank("Codex") < catalog.familyRank("GPT"))
        #expect(catalog.familyRank("GPT") < catalog.familyRank("SomethingElse"))
    }

    @Test("openai feed selector keeps bare openai keys only")
    func feedSelector() {
        let selector = PricingFeedSelector.openAI
        #expect(selector.includes("gpt-5.2-codex", "openai"))
        #expect(!selector.includes("openai/gpt-5.2-codex", "openai"))
        #expect(!selector.includes("claude-fable-5", "anthropic"))
        #expect(!selector.includes("gemini-3-pro", "gemini"))
    }
}

/// A temp `~/.codex/sessions`-shaped tree plus a scoped cache directory.
private struct CodexFixture {
    let base: URL
    let root: URL
    let cacheDirectory: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appending(path: "codex-provider-tests-\(UUID().uuidString)")
        root = base.appending(path: "sessions")
        cacheDirectory = base.appending(path: "cache")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Writes a rollout file; `age` pushes its mtime into the past so
    /// newest-first ordering is deterministic.
    func writeRollout(_ path: String, lines: [String], age: TimeInterval = 0) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        if age > 0 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }
}
