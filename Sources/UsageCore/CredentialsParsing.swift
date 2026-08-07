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
    }

    /// Extracts the access token. Error messages never include the payload.
    static func accessToken(fromJSON data: Data) throws -> String {
        let decoder = JSONDecoder()
        let token: String
        if let wrapped = try? decoder.decode(Wrapped.self, from: data) {
            token = wrapped.claudeAiOauth.accessToken
        } else if let bare = try? decoder.decode(OAuthObject.self, from: data) {
            token = bare.accessToken
        } else {
            throw CredentialError.unreadable("credentials JSON has no accessToken in a recognized shape")
        }

        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CredentialError.unreadable("accessToken is empty")
        }
        return trimmed
    }
}
