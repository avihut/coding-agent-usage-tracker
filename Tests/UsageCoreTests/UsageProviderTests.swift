import Foundation
import Testing
@testable import UsageCore

@Suite("UsageProvider seam")
struct UsageProviderTests {
    @Test("MeterBuilder stamps window shapes as meter data")
    func windowShapes() throws {
        let response = try UsageResponse.decode(from: loadFixture("nominal"))
        let meters = MeterBuilder.meters(from: response)

        let session = try #require(meters.first { $0.rank == 0 })
        #expect(session.limitWindow == TimeInterval(5 * 3600))
        #expect(session.rateWindow == 45 * 60)
        #expect(session.scopedModelName == nil)

        let weekly = try #require(meters.first { $0.rank == 1 })
        #expect(weekly.limitWindow == TimeInterval(7 * 86400))
        #expect(weekly.rateWindow == 4 * 3600)

        let scoped = try #require(meters.first { $0.rank == 2 })
        #expect(scoped.limitWindow == TimeInterval(7 * 86400))
        #expect(scoped.scopedModelName == "Fable")
    }

    @Test("unknown limit kinds carry no window and default to the slow rate fit")
    func unknownKindWindow() throws {
        let response = try UsageResponse.decode(from: loadFixture("unknown-kind"))
        let unknown = try #require(
            MeterBuilder.meters(from: response).first { $0.limitWindow == nil })
        #expect(unknown.rateWindow == 4 * 3600)
    }

    @Test("default rate window tiers on the limit window length")
    func defaultRateWindow() {
        #expect(Meter.defaultRateWindow(limitWindow: 5 * 3600) == 45 * 60)
        #expect(Meter.defaultRateWindow(limitWindow: 6 * 3600) == 45 * 60)
        #expect(Meter.defaultRateWindow(limitWindow: 24 * 3600) == 4 * 3600)
        #expect(Meter.defaultRateWindow(limitWindow: nil) == 4 * 3600)
    }

    @Test("re-leveling preserves the severity floor without the payload")
    func rebuiltKeepsSeverityFloor() throws {
        let response = try UsageResponse.decode(from: loadFixture("severity-elevated"))
        let snapshot = makeSnapshot(response: response)
        // Thresholds so lax no percent qualifies — only the API's own flag
        // can keep a meter at warning.
        let relaxed = snapshot.rebuilt(
            thresholds: Thresholds(warningPercent: 95, criticalPercent: 100))
        let flagged = relaxed.meters.filter(\.forcesWarning)
        #expect(!flagged.isEmpty)
        #expect(flagged.allSatisfy { $0.level >= .warning })
    }

    @Test("ClaudeProvider decodes raw bytes into a normalized snapshot")
    func claudeProviderSnapshot() throws {
        let provider = ClaudeProvider()
        let snapshot = try provider.snapshot(
            fromRawUsage: loadFixture("real-2026-08-07"),
            fetchedAt: Date(), plan: nil, thresholds: .standard)
        #expect(!snapshot.meters.isEmpty)
        #expect(snapshot.meters.contains { $0.rank == 0 && $0.limitWindow == 5 * 3600 })
    }

    @Test("ClaudeProvider rejects undecodable bytes")
    func claudeProviderSchemaError() {
        let provider = ClaudeProvider()
        #expect(throws: (any Error).self) {
            try provider.snapshot(
                fromRawUsage: Data("not json".utf8),
                fetchedAt: Date(), plan: nil, thresholds: .standard)
        }
    }

    @Test("claude catalog: display names, families, tier order")
    func claudeCatalog() {
        let catalog = ModelCatalog.claude
        #expect(catalog.displayName("claude-fable-5") == "Fable 5")
        #expect(catalog.displayName("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(catalog.displayName("unknown") == "Other")
        #expect(catalog.familyName("claude-opus-4-8") == "Opus")
        #expect(catalog.familyRank("Fable") < catalog.familyRank("Opus"))
        #expect(catalog.familyRank("Opus") < catalog.familyRank("Sonnet"))
        #expect(catalog.familyRank("Sonnet") < catalog.familyRank("Haiku"))
        #expect(catalog.familyRank("Haiku") < catalog.familyRank("SomethingElse"))
    }

    @Test("generic catalog: ids pass through, date suffix trimmed")
    func genericCatalog() {
        let catalog = ModelCatalog.generic
        #expect(catalog.displayName("gpt-5.2-codex") == "gpt-5.2-codex")
        #expect(catalog.displayName("gemini-3-pro-20260115") == "gemini-3-pro")
        #expect(catalog.displayName("unknown") == "Other")
        #expect(catalog.familyName("gemini-3-pro") == "gemini")
    }

    @Test("Claude provider identity: hosts, links, glyph, capabilities")
    func claudeProviderIdentity() {
        let provider = ClaudeProvider()
        #expect(provider.networkDestinations == ["api.anthropic.com"])
        #expect(provider.links.planUpgrade?.host() == "claude.ai")
        #expect(provider.menuBarGlyph == "✳︎")
        #expect(provider.agentSettings != nil)
        #expect(provider.makeLocalActivity(bundleID: "test.bundle") != nil)
    }
}
