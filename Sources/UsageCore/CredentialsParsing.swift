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

    public init(subscriptionType: String?, rateLimitTier: String?) {
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    /// "max" (+ tier "…_20x") → "Max plan · 20x"; nil when the credentials
    /// carry no plan facts, so the panel shows nothing rather than a guess.
    public var displayLabel: String? {
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
