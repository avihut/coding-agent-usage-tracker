import Foundation
import Testing
@testable import UsageCore

@Suite("Credential payload parsing")
struct CredentialParsingTests {
    @Test("wrapped shape: {\"claudeAiOauth\": {\"accessToken\": ...}}")
    func wrappedShape() throws {
        let json = Data(#"{"claudeAiOauth": {"accessToken": "tok-123", "refreshToken": "ref-999"}}"#.utf8)
        #expect(try CredentialsParser.parse(fromJSON: json).token == "tok-123")
    }

    @Test("bare OAuth object shape: {\"accessToken\": ...}")
    func bareShape() throws {
        let json = Data(#"{"accessToken": "tok-456", "expiresAt": 1}"#.utf8)
        #expect(try CredentialsParser.parse(fromJSON: json).token == "tok-456")
    }

    @Test("token is trimmed of stray whitespace")
    func trimsWhitespace() throws {
        let json = Data(#"{"accessToken": "  tok-789\n"}"#.utf8)
        #expect(try CredentialsParser.parse(fromJSON: json).token == "tok-789")
    }

    @Test("plan metadata rides along; absent fields degrade to nil")
    func planMetadata() throws {
        let json = Data(#"""
            {"claudeAiOauth": {"accessToken": "tok-1", "subscriptionType": "max",
             "rateLimitTier": "default_claude_max_20x"}}
            """#.utf8)
        let plan = try CredentialsParser.parse(fromJSON: json).plan
        #expect(plan == PlanInfo(subscriptionType: "max", rateLimitTier: "default_claude_max_20x"))
        #expect(plan.displayLabel == "Max plan · 20x")

        let bare = Data(#"{"accessToken": "tok-2"}"#.utf8)
        let empty = try CredentialsParser.parse(fromJSON: bare).plan
        #expect(empty.displayLabel == nil)
    }

    @Test("plan label variants")
    func planLabels() {
        #expect(PlanInfo(subscriptionType: "pro", rateLimitTier: nil).displayLabel == "Pro plan")
        // A tier that isn't a multiplier suffix stays off the label.
        #expect(PlanInfo(subscriptionType: "max", rateLimitTier: "standard").displayLabel == "Max plan")
        #expect(PlanInfo(subscriptionType: "  ", rateLimitTier: "x").displayLabel == nil)
    }

    @Test("unrecognized JSON shape throws, without echoing contents")
    func unrecognizedShape() {
        let json = Data(#"{"something": "else"}"#.utf8)
        #expect(throws: CredentialError.self) {
            try CredentialsParser.parse(fromJSON: json)
        }
    }

    @Test("malformed JSON throws")
    func malformedJSON() {
        let json = Data("not json at all".utf8)
        #expect(throws: CredentialError.self) {
            try CredentialsParser.parse(fromJSON: json)
        }
    }

    @Test("empty token rejected")
    func emptyToken() {
        let json = Data(#"{"accessToken": "   "}"#.utf8)
        #expect(throws: CredentialError.self) {
            try CredentialsParser.parse(fromJSON: json)
        }
    }

    @Test("Credential never exposes the token via description")
    func redactedDescription() {
        let credential = Credential(accessToken: "tok-secret", sourceName: "test")
        #expect(!String(describing: credential).contains("tok-secret"))
        #expect(!String(reflecting: credential).contains("tok-secret"))
    }
}

@Suite("Credential chain")
struct CredentialChainTests {
    struct StubSource: CredentialSource {
        let name: String
        let result: Result<String, CredentialError>

        func readCredential() throws -> Credential {
            Credential(accessToken: try result.get(), sourceName: name)
        }
    }

    @Test("first successful source wins")
    func firstSuccessWins() throws {
        let chain = CredentialChain(sources: [
            StubSource(name: "a", result: .failure(.notFound)),
            StubSource(name: "b", result: .success("tok-b")),
            StubSource(name: "c", result: .success("tok-c")),
        ])
        let credential = try chain.readCredential()
        #expect(credential.accessToken == "tok-b")
        #expect(credential.sourceName == "b")
    }

    @Test("all notFound collapses to notFound")
    func allNotFound() {
        let chain = CredentialChain(sources: [
            StubSource(name: "a", result: .failure(.notFound)),
            StubSource(name: "b", result: .failure(.notFound)),
        ])
        #expect(throws: CredentialError.self) { try chain.readCredential() }
    }

    @Test("informative error preferred over notFound")
    func informativeErrorPreferred() {
        let chain = CredentialChain(sources: [
            StubSource(name: "a", result: .failure(.accessDenied(-128))),
            StubSource(name: "b", result: .failure(.notFound)),
        ])
        do {
            _ = try chain.readCredential()
            Issue.record("expected a throw")
        } catch let error as CredentialError {
            guard case .accessDenied(let status) = error else {
                Issue.record("expected accessDenied, got \(error)")
                return
            }
            #expect(status == -128)
        } catch {
            Issue.record("unexpected error type")
        }
    }
}

@Suite("`security -w` output framing")
struct SecurityToolOutputTests {
    @Test("raw JSON with the trailing newline passes through")
    func rawPassthrough() throws {
        let piped = Data("{\"accessToken\": \"tok-raw\"}\n".utf8)
        let token = try CredentialsParser.parse(fromJSON: SecurityToolOutput.payload(piped)).token
        #expect(token == "tok-raw")
    }

    @Test("hex-encoded payload is decoded before parsing")
    func hexDecoded() throws {
        let json = #"{"accessToken": "tok-hex"}"#
        let hex = Data(json.utf8).map { String(format: "%02X", $0) }.joined() + "\n"
        let token = try CredentialsParser.parse(fromJSON: SecurityToolOutput.payload(Data(hex.utf8))).token
        #expect(token == "tok-hex")
    }

    @Test("JSON can never take the hex leg — `{` is not a hex digit")
    func jsonNeverHex() {
        let braced = Data("{\"a\": 1}\n".utf8)
        #expect(SecurityToolOutput.payload(braced) == Data("{\"a\": 1}".utf8))
    }

    @Test("odd-length hex-looking text stays raw")
    func oddLengthStaysRaw() {
        #expect(SecurityToolOutput.payload(Data("ABC\n".utf8)) == Data("ABC".utf8))
    }
}

@Suite("Keychain source via /usr/bin/security")
struct KeychainCredentialSourceTests {
    /// Spawns the real tool against a service that cannot exist: proves the
    /// subprocess plumbing and the exit-44 → `.notFound` mapping without
    /// touching real credentials, and a not-found lookup never shows
    /// consent UI (consent is per-item).
    @Test("absent service maps to notFound, promptless")
    func absentService() {
        let source = KeychainCredentialSource(service: "ClaudeUsage-test-no-such-item")
        do {
            _ = try source.readCredential()
            Issue.record("expected a throw")
        } catch let error as CredentialError {
            guard case .notFound = error else {
                Issue.record("expected notFound, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type")
        }
    }
}
