import Foundation

/// Parses the JSON payload Claude Code stores (identical shape on disk and in
/// the Keychain). Tolerates both the wrapped form
/// `{"claudeAiOauth": {"accessToken": ...}}` and the bare OAuth object
/// `{"accessToken": ...}`.
enum CredentialsParser {
    private struct Wrapped: Decodable {
        let claudeAiOauth: OAuthObject
    }

    private struct OAuthObject: Decodable {
        let accessToken: String
        let subscriptionType: String?
        let rateLimitTier: String?
    }

    /// Extracts the access token plus safe plan metadata (never the refresh
    /// token). Error messages never include the payload.
    static func parse(fromJSON data: Data) throws -> (token: String, plan: PlanInfo) {
        let decoder = JSONDecoder()
        let oauth: OAuthObject
        if let wrapped = try? decoder.decode(Wrapped.self, from: data) {
            oauth = wrapped.claudeAiOauth
        } else if let bare = try? decoder.decode(OAuthObject.self, from: data) {
            oauth = bare
        } else {
            throw CredentialError.unreadable("credentials JSON has no accessToken in a recognized shape")
        }

        let trimmed = oauth.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CredentialError.unreadable("accessToken is empty")
        }
        return (
            trimmed,
            PlanInfo(
                subscriptionType: oauth.subscriptionType,
                rateLimitTier: oauth.rateLimitTier)
        )
    }
}

/// Non-secret plan facts read alongside the access token: safe to display,
/// safe to log.
public struct PlanInfo: Sendable, Equatable {
    public let subscriptionType: String?
    public let rateLimitTier: String?
    /// The plan's name as its vendor shows it, when the provider knows it.
    /// Vendors rename plans without touching the raw type and tier, so the
    /// provider supplies the name and the label prefers it.
    public let displayName: String?

    public init(subscriptionType: String?, rateLimitTier: String?, displayName: String? = nil) {
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
        self.displayName = displayName
    }

    /// The same facts under the provider's name for the plan (nil keeps the
    /// one it already has).
    public func named(_ name: String?) -> PlanInfo {
        PlanInfo(
            subscriptionType: subscriptionType, rateLimitTier: rateLimitTier,
            displayName: name ?? displayName)
    }

    /// The provider's name when it gave one (a name N reads "N plan");
    /// otherwise built from the raw facts (a type T reads "T plan", and a
    /// tier ending in a multiplier like "_2x" adds " · 2x"); nil when there
    /// are no plan facts, so the panel shows nothing rather than a guess.
    public var displayLabel: String? {
        if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name.lowercased().hasSuffix(" plan") ? name : "\(name) plan"
        }
        guard let type = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !type.isEmpty
        else { return nil }
        var label = "\(type.capitalized) plan"
        if let tier = rateLimitTier?.lowercased(),
           let multiplier = tier.split(separator: "_").last,
           multiplier.hasSuffix("x"), multiplier.count <= 4,
           multiplier.dropLast().allSatisfy(\.isNumber) {
            label += " · \(multiplier)"
        }
        return label
    }
}
