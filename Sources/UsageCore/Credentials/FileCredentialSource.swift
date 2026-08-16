import Foundation

/// Reads `~/.claude/.credentials.json` (the non-Keychain storage path Claude
/// Code uses on some setups).
public struct FileCredentialSource: CredentialSource {
    let fileURL: URL

    public var name: String { "file (~/.claude/.credentials.json)" }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".claude/.credentials.json")
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
