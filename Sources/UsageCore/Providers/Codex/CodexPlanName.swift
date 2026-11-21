import Foundation

/// ChatGPT plan names for the `plan_type` ids Codex records in its rollouts
/// (Codex's own `KnownPlan` list, as of CLI 0.167). Capitalizing the raw id
/// read "Prolite plan" or "Self_serve_business_usage_based plan"; the usage-
/// based and automation variants are billing arrangements of the same plan,
/// so they read as that plan. An id this table doesn't know is spelled out
/// word by word ("sci_plus" → "Sci Plus") rather than guessed at.
public enum CodexPlanName {
    public static func name(for planType: String) -> String? {
        let id = planType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return nil }
        if let known = known[id] { return known }
        return id.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static let known: [String: String] = [
        "free": "Free",
        "go": "Go",
        "plus": "Plus",
        "pro": "Pro",
        "prolite": "Pro Lite",
        "promax": "Pro Max",
        "team": "Team",
        "business": "Business",
        "self_serve_business_usage_based": "Business",
        "self_serve_business_prolite": "Business Pro Lite",
        "enterprise": "Enterprise",
        "ent26": "Enterprise",
        "enterprise_cbp_usage_based": "Enterprise",
        "enterprise_cbp_automation": "Enterprise",
        "edu": "Edu",
        "education": "Edu",
        "edu_plus": "Edu Plus",
        "edu_pro": "Edu Pro",
        "k12": "K-12",
    ]
}
