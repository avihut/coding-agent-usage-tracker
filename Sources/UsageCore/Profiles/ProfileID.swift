import CryptoKit
import Foundation

/// How a profile — one agent home under one provider — is named on disk
/// and in the digest. The standard home is `default` (its files and keys
/// keep the pre-profile spelling); every other home takes the first eight
/// hex digits of SHA-256 over its path, which is exactly how Claude Code
/// suffixes the Keychain item it writes for a custom `CLAUDE_CONFIG_DIR`
/// (`Claude Code-credentials-<id>`), so the id doubles as the credential
/// lookup key and never has to be stored beside a secret.
public enum ProfileID {
    /// The standard home's id.
    public static let standard = StorageScope.defaultProfileID

    /// SHA-256 over the path with trailing slashes dropped, first 8 hex.
    /// The path is hashed as GIVEN — symlinks are never resolved, because
    /// Claude Code hashed whatever the environment variable said.
    public static func derive(homePath: String) -> String {
        let digest = SHA256.hash(data: Data(PathDisplay.trimmed(homePath).utf8))
        return digest.prefix(4).map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }

    /// `standard` when `directory` IS the standard home, else the derived id.
    public static func forHome(_ directory: URL, standard: URL) -> String {
        PathDisplay.trimmed(directory.path) == PathDisplay.trimmed(standard.path)
            ? Self.standard : derive(homePath: directory.path)
    }
}
