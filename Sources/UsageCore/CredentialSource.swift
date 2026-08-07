import Foundation

/// A place the Claude Code OAuth access token can be read from.
///
/// Sources are read-only by contract: nothing in this app may ever write
/// credentials back, and only the access token is extracted — never the
/// refresh token.
public protocol CredentialSource: Sendable {
    /// Human-readable description of the source, safe to log (contains no secrets).
    var name: String { get }
    func readCredential() throws -> Credential
}

public struct Credential: Sendable {
    public let accessToken: String
    /// Which source produced this credential — safe to show in diagnostics.
    public let sourceName: String

    public init(accessToken: String, sourceName: String) {
        self.accessToken = accessToken
        self.sourceName = sourceName
    }
}

extension Credential: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "Credential(source: \(sourceName), token: <redacted>)" }
    public var debugDescription: String { description }
}

public enum CredentialError: Error, Sendable {
    /// The source has no credentials at all (file missing, Keychain item absent).
    case notFound
    /// The Keychain refused access (user denied the prompt, or ACL mismatch).
    case accessDenied(OSStatus)
    /// The source exists but its contents can't be understood. The associated
    /// string describes the problem and must never contain the contents.
    case unreadable(String)
}

/// Tries each source in order. First success wins.
public struct CredentialChain: Sendable {
    public let sources: [any CredentialSource]

    public init(sources: [any CredentialSource]) {
        self.sources = sources
    }

    /// File first, Keychain as fallback — per spec §5.
    public static let standard = CredentialChain(sources: [
        FileCredentialSource(),
        KeychainCredentialSource(),
    ])

    /// Returns the first credential found. If every source fails, throws the
    /// most informative error seen (anything beats `.notFound`).
    public func readCredential() throws -> Credential {
        var informativeError: CredentialError?
        for source in sources {
            do {
                return try source.readCredential()
            } catch let error as CredentialError {
                if case .notFound = error { continue }
                informativeError = informativeError ?? error
            }
        }
        throw informativeError ?? CredentialError.notFound
    }
}
