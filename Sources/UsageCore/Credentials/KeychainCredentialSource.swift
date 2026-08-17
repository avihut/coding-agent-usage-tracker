import Foundation

/// Reads the `Claude Code-credentials` generic-password item from the login
/// Keychain — through `/usr/bin/security`, never `SecItemCopyMatching`.
///
/// Why a subprocess: Claude Code writes this item with Apple's `security`
/// tool, so that tool is the item's own client in the ACL — and Claude Code
/// rewrites the item on every token refresh, resetting whatever "Always
/// Allow" grant a third-party binary had earned for a native read. Stable
/// signing (spec §5 rule 2) can't outlive the rewrites: through v0.82.0 the
/// consent dialog returned roughly once per refresh, times three reading
/// binaries. Reading through the item's own Apple-signed client is silent —
/// today, and after every refresh, rebuild, and re-login (v0.82.1).
///
/// Read-only by design: `find-generic-password` cannot mutate the Keychain,
/// and this type contains no code path that writes, updates, or deletes
/// items. The secret travels pipe → memory → parser; never argv, never a
/// log, never disk.
public struct KeychainCredentialSource: CredentialSource {
    let service: String

    public var name: String { "keychain (login, service \"\(service)\")" }

    public init(service: String = "Claude Code-credentials") {
        self.service = service
    }

    public func readCredential() throws -> Credential {
        let tool = Process()
        tool.executableURL = URL(filePath: "/usr/bin/security")
        tool.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        tool.standardOutput = output
        tool.standardError = FileHandle.nullDevice
        do {
            try tool.run()
        } catch {
            throw CredentialError.unreadable("/usr/bin/security failed to launch")
        }
        let raw = output.fileHandleForReading.readDataToEndOfFile()
        tool.waitUntilExit()

        switch tool.terminationStatus {
        case 0:
            break
        case 44:  // errSecItemNotFound, as `security` reports it
            throw CredentialError.notFound
        case let code:  // 128 = an unlock dialog was dismissed; else the Keychain refused
            throw CredentialError.accessDenied(code)
        }

        let parsed = try CredentialsParser.parse(fromJSON: SecurityToolOutput.payload(raw))
        return Credential(accessToken: parsed.token, sourceName: name, plan: parsed.plan)
    }
}

/// Undoes `security … -w` output framing: the secret arrives with a trailing
/// newline, and a blob holding non-printable bytes arrives hex-encoded
/// instead of raw. Claude Code's payload is printable JSON, so the hex leg
/// is insurance — and it cannot misfire on the real payload, because JSON
/// opens with `{`, which is not a hex digit.
enum SecurityToolOutput {
    static func payload(_ raw: Data) -> Data {
        guard let text = String(data: raw, encoding: .utf8) else { return raw }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.count.isMultiple(of: 2),
            trimmed.allSatisfy(\.isHexDigit),
            let decoded = hexDecoded(trimmed) {
            return decoded
        }
        return Data(trimmed.utf8)
    }

    private static func hexDecoded(_ text: String) -> Data? {
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
