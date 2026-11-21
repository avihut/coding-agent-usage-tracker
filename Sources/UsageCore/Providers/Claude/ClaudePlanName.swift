import Foundation

/// Claude's plan names as Anthropic shows them. The credentials keep the raw
/// facts — subscription type "max", tier "default_claude_max_20x" — while the
/// names move: since 2026-10-30 the former Max 5x is "Max" and the former
/// Max 20x is "Ultra" (whose five-hour cap the "20x" described is gone).
///
/// The name Claude Code itself records (`oauthAccount.planDisplayName`, from
/// the profile it fetches) wins; the tier mapping covers agent versions that
/// record none. Anything else keeps PlanInfo's name built from the raw facts.
public enum ClaudePlanName {
    public static func resolve(_ plan: PlanInfo?, recordedName: String?) -> PlanInfo? {
        if let name = recordedName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return (plan ?? PlanInfo(subscriptionType: nil, rateLimitTier: nil)).named(name)
        }
        guard let plan else { return nil }
        return plan.named(fromTier(plan))
    }

    /// "max" + a 20x tier → "Ultra"; "max" with any other tier → "Max".
    static func fromTier(_ plan: PlanInfo) -> String? {
        guard plan.subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "max"
        else { return nil }
        let tier = plan.rateLimitTier?.lowercased() ?? ""
        return tier.hasSuffix("_20x") ? "Ultra" : "Max"
    }
}
