import Foundation
import Testing
@testable import UsageCore

@Suite("GeminiProvider")
struct GeminiProviderTests {
    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    @Test("the daily meter counts today's prompts against the assumed cap")
    func dailyMeter() throws {
        let fixture = try GeminiFixture()
        defer { fixture.tearDown() }
        let now = Date()
        // Three prompts today, one yesterday; message text present in the
        // log must be tolerated (and is never decoded).
        try fixture.writeLog(entries: [
            (Self.iso(now.addingTimeInterval(-300)), "user"),
            (Self.iso(now.addingTimeInterval(-200)), "user"),
            (Self.iso(now.addingTimeInterval(-100)), "user"),
            (Self.iso(now.addingTimeInterval(-90000)), "user"),
            (Self.iso(now.addingTimeInterval(-50)), "gemini"),
        ])

        let payload = try GeminiTraces.usagePayload(root: fixture.root, cap: 10, now: now)
        let snapshot = try GeminiMeterBuilder.snapshot(
            fromPayload: payload, thresholds: .standard)

        let meter = try #require(snapshot.meters.first)
        #expect(meter.percent == 30)
        #expect(meter.rank == 0)
        #expect(meter.limitWindow == TimeInterval(24 * 3600))
        #expect(meter.label == "Daily · counted locally")
        #expect(snapshot.fetchedAt == now)
    }

    @Test("daily quotas reset at the next Pacific midnight")
    func pacificReset() throws {
        let captured = try #require(
            FlexibleISO8601.date(from: "2026-08-15T10:00:00.000Z"))
        let reset = try #require(GeminiMeterBuilder.nextPacificMidnight(after: captured))
        // 10:00Z on Aug 15 is 03:00 PDT; the next midnight PDT is
        // Aug 16 00:00 PDT = Aug 16 07:00Z.
        #expect(reset == FlexibleISO8601.date(from: "2026-08-16T07:00:00.000Z"))
    }

    @Test("session headers stand in for days the prompt log doesn't cover")
    func sessionFallback() throws {
        let fixture = try GeminiFixture()
        defer { fixture.tearDown() }
        let calendar = Calendar.current
        let now = Date()
        let loggedDay = calendar.startOfDay(for: now)
        let sessionOnly = calendar.startOfDay(for: now.addingTimeInterval(-3 * 86400))
        try fixture.writeLog(entries: [(Self.iso(now.addingTimeInterval(-60)), "user")])
        try fixture.writeSession(
            name: "session-old.jsonl",
            startTime: Self.iso(sessionOnly.addingTimeInterval(3600)))
        // A session on the logged day must not double-count its prompts.
        try fixture.writeSession(
            name: "session-today.jsonl",
            startTime: Self.iso(now.addingTimeInterval(-120)))

        let days = GeminiTraces.promptDays(root: fixture.root)

        #expect(days[loggedDay] == 1)
        #expect(days[sessionOnly] == 1)
    }

    @Test("a missing ~/.gemini/tmp throws noLocalData")
    func noLocalData() throws {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "gemini-absent-\(UUID().uuidString)")
        #expect(throws: (any Error).self) {
            try GeminiTraces.usagePayload(root: missing, cap: 1000, now: Date())
        }
    }

    @Test("provider round-trip with an injected cap")
    func providerRoundTrip() async throws {
        let fixture = try GeminiFixture()
        defer { fixture.tearDown() }
        let now = Date()
        try fixture.writeLog(entries: [
            (Self.iso(now.addingTimeInterval(-30)), "user"),
            (Self.iso(now.addingTimeInterval(-20)), "user"),
        ])
        let provider = GeminiProvider(tmpRoot: fixture.root, dailyCap: 4)

        let body = try await provider.fetchRawUsage(accessToken: "")
        let snapshot = try provider.snapshot(
            fromRawUsage: body, fetchedAt: Date(), plan: nil, thresholds: .standard)

        #expect(snapshot.meters.first?.percent == 50)
    }

    @Test("gemini catalog: display names, tier families, ranks")
    func geminiCatalog() {
        let catalog = ModelCatalog.gemini
        #expect(catalog.displayName("gemini-3-pro-20260115") == "Gemini 3 Pro")
        #expect(catalog.displayName("gemini-2.5-flash") == "Gemini 2.5 Flash")
        #expect(catalog.displayName("unknown") == "Other")
        #expect(catalog.familyName("gemini-3-pro") == "Gemini Pro")
        #expect(catalog.familyName("gemini-2.5-flash") == "Gemini Flash")
        #expect(catalog.familyRank("Gemini Pro") < catalog.familyRank("Gemini Flash"))
        #expect(catalog.familyRank("Gemini Flash") < catalog.familyRank("Gemini Nano"))
    }

    @Test("provider identity: local-only, credential-free, cap preference declared")
    func providerIdentity() throws {
        let provider = GeminiProvider()
        #expect(provider.networkDestinations.isEmpty)
        #expect(provider.menuBarGlyph == "✦")
        #expect(provider.agentSettings == nil)
        #expect(provider.preferences.first?.key == "gemini.dailyRequestCap")
        let credential = try provider.credentials.readCredential()
        #expect(credential.accessToken.isEmpty)
    }

    @Test("gemini feed selector strips the route prefix")
    func feedSelector() {
        let selector = PricingFeedSelector.gemini
        #expect(selector.includes("gemini/gemini-3-pro", "gemini"))
        #expect(!selector.includes("claude-fable-5", "anthropic"))
        #expect(selector.normalizeKey("gemini/gemini-3-pro") == "gemini-3-pro")
        #expect(selector.normalizeKey("gemini-3-pro") == "gemini-3-pro")
    }
}

/// A temp `~/.gemini/tmp`-shaped tree: one project hash with a prompt log
/// and chat session headers.
private struct GeminiFixture {
    let root: URL
    private let project: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "gemini-provider-tests-\(UUID().uuidString)")
        project = root.appending(path: "abc123")
        try FileManager.default.createDirectory(
            at: project.appending(path: "chats"), withIntermediateDirectories: true)
    }

    func writeLog(entries: [(timestamp: String, type: String)]) throws {
        let records = entries.map { entry in
            """
            {"sessionId":"s","messageId":1,"timestamp":"\(entry.timestamp)",\
            "type":"\(entry.type)","message":"redacted-content-never-read"}
            """
        }
        let json = "[\(records.joined(separator: ","))]"
        try Data(json.utf8).write(to: project.appending(path: "logs.json"))
    }

    func writeSession(name: String, startTime: String) throws {
        let header = """
        {"sessionId":"\(UUID().uuidString)","projectHash":"abc123",\
        "startTime":"\(startTime)","lastUpdated":"\(startTime)","kind":"main"}
        """
        try Data(header.utf8).write(
            to: project.appending(path: "chats").appending(path: name))
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}
