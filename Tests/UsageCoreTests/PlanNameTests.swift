import Foundation
import Testing
@testable import UsageCore

@Suite("Plan names")
struct PlanNameTests {
    @Test("a provider's name wins over the raw facts; blank falls back")
    func nameWins() {
        let raw = PlanInfo(subscriptionType: "max", rateLimitTier: "default_claude_max_20x")
        #expect(raw.displayLabel == "Max plan · 20x")
        #expect(raw.named("Ultra").displayLabel == "Ultra plan")
        #expect(raw.named("Ultra").subscriptionType == "max")
        #expect(raw.named("Ultra").rateLimitTier == "default_claude_max_20x")
        #expect(raw.named("Team plan").displayLabel == "Team plan")
        #expect(raw.named("  ").displayLabel == "Max plan · 20x")
        #expect(raw.named("Ultra").named(nil).displayName == "Ultra")
    }

    @Test("Claude: the recorded name wins, then the renamed tiers, then the raw facts")
    func claudeNames() {
        let max20 = PlanInfo(subscriptionType: "max", rateLimitTier: "default_claude_max_20x")
        let max5 = PlanInfo(subscriptionType: "max", rateLimitTier: "default_claude_max_5x")
        let pro = PlanInfo(subscriptionType: "pro", rateLimitTier: nil)

        #expect(ClaudePlanName.resolve(max20, recordedName: nil)?.displayLabel == "Ultra plan")
        #expect(ClaudePlanName.resolve(max5, recordedName: nil)?.displayLabel == "Max plan")
        #expect(ClaudePlanName.resolve(pro, recordedName: nil)?.displayLabel == "Pro plan")
        // What Claude Code records beats any mapping, whatever it says.
        #expect(ClaudePlanName.resolve(max5, recordedName: "Ultra")?.displayLabel == "Ultra plan")
        #expect(ClaudePlanName.resolve(max20, recordedName: " ")?.displayLabel == "Ultra plan")
        // A cache-served snapshot carries no credential facts; the record still names it.
        #expect(ClaudePlanName.resolve(nil, recordedName: "Ultra")?.displayLabel == "Ultra plan")
        #expect(ClaudePlanName.resolve(nil, recordedName: nil) == nil)
    }

    @Test("Claude: the plan name is read from oauthAccount, and only there")
    func recordedName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "plan-name-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: ".claude.json")

        try Data(#"{"oauthAccount": {"accountUuid": "a", "planDisplayName": "Ultra"}}"#.utf8)
            .write(to: file)
        let source = ClaudeAccountIdentitySource(fileURL: file)
        #expect(source.planDisplayName() == "Ultra")
        // Display only: the identity (and so the epoch) is untouched by it.
        #expect(source.currentIdentity() == AccountIdentity(accountUuid: "a", organizationUuid: ""))

        try Data(#"{"planDisplayName": "Ultra", "oauthAccount": {"accountUuid": "a"}}"#.utf8)
            .write(to: file)
        #expect(source.planDisplayName() == nil)
        try Data("not json".utf8).write(to: file)
        #expect(source.planDisplayName() == nil)
        #expect(ClaudeAccountIdentitySource(fileURL: dir.appending(path: "missing.json"))
            .planDisplayName() == nil)
    }

    @Test("Codex: plan ids read as ChatGPT plan names")
    func codexNames() {
        #expect(CodexPlanName.name(for: "plus") == "Plus")
        #expect(CodexPlanName.name(for: "prolite") == "Pro Lite")
        #expect(CodexPlanName.name(for: "promax") == "Pro Max")
        #expect(CodexPlanName.name(for: "self_serve_business_usage_based") == "Business")
        #expect(CodexPlanName.name(for: "enterprise_cbp_usage_based") == "Enterprise")
        #expect(CodexPlanName.name(for: "k12") == "K-12")
        #expect(CodexPlanName.name(for: "sci_plus") == "Sci Plus")
        #expect(CodexPlanName.name(for: " ") == nil)
        let plan = PlanInfo(
            subscriptionType: "prolite", rateLimitTier: nil,
            displayName: CodexPlanName.name(for: "prolite"))
        #expect(plan.displayLabel == "Pro Lite plan")
    }

    @Test("the digest carries the name, and a digest without it still decodes")
    func digestCarriesName() throws {
        let engine = EngineStatus(
            providerID: "claude", serviceName: "Claude", agentName: "Claude Code", glyph: "✳︎",
            accent: RGBColor(red: 0.851, green: 0.467, blue: 0.341), systemAccent: nil,
            planLabel: "Ultra plan", planSubscriptionType: "max",
            planRateLimitTier: "default_claude_max_20x", planDisplayName: "Ultra",
            appVersion: "0.103.0", pid: 1, host: "daemon",
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000), fetchedAt: nil,
            nextPollAt: nil, backoffUntil: nil, stale: false, isLocalProvider: false,
            activeIntervalSeconds: 300, paceMultiplier: 1, apiBudgetUsed: nil,
            apiBudgetCeiling: nil, apiBudgetFraction: nil, gateFloorSeconds: 180,
            error: nil, spend: nil)
        let data = try LiveState.encoder().encode(engine)
        let decoded = try LiveState.decoder().decode(EngineStatus.self, from: data)
        #expect(decoded.planDisplayName == "Ultra")

        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "planDisplayName")
        let older = try JSONSerialization.data(withJSONObject: object)
        #expect(try LiveState.decoder().decode(EngineStatus.self, from: older).planDisplayName == nil)
    }
}
