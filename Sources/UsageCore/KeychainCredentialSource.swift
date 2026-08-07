import Foundation
import Security

/// Reads the `Claude Code-credentials` generic-password item from the login
/// Keychain.
///
/// Deliberately absent from the query: `kSecUseDataProtectionKeychain`. That
/// flag targets the iOS-style data-protection keychain (needs an entitlement
/// and access group we don't have); omitting it uses the file-based login
/// keychain — the same store `security find-generic-password` reads.
///
/// Read-only by design: this type contains no code path that writes, updates,
/// or deletes Keychain items.
public struct KeychainCredentialSource: CredentialSource {
    let service: String

    public var name: String { "keychain (login, service \"\(service)\")" }

    public init(service: String = "Claude Code-credentials") {
        self.service = service
    }

    public func readCredential() throws -> Credential {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw CredentialError.notFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw CredentialError.accessDenied(status)
        default:
            throw CredentialError.unreadable("keychain read failed (OSStatus \(status))")
        }

        guard let data = item as? Data else {
            throw CredentialError.unreadable("keychain item has no data payload")
        }
        return Credential(
            accessToken: try CredentialsParser.accessToken(fromJSON: data),
            sourceName: name
        )
    }
}
