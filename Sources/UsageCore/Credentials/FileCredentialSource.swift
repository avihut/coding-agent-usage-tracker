import Foundation

/// Reads a home's `.credentials.json` (the non-Keychain storage path Claude
/// Code uses on some setups) — `~/.claude/.credentials.json` by default.
public struct FileCredentialSource: CredentialSource {
    let fileURL: URL

    /// "file (~/.claude/.credentials.json)" — the path, never the contents.
    public var name: String { "file (\(PathDisplay.abbreviated(fileURL)))" }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? ClaudeHome.standard.credentialsFileURL
    }

    public func readCredential() throws -> Credential {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CredentialError.notFound
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw CredentialError.unreadable("credentials file exists but could not be read")
        }
        let parsed = try CredentialsParser.parse(fromJSON: data)
        return Credential(accessToken: parsed.token, sourceName: name, plan: parsed.plan)
    }
}
