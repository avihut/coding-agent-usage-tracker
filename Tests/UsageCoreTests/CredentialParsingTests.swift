import Foundation
import Testing
@testable import UsageCore

@Suite("Credential payload parsing")
struct CredentialParsingTests {
    @Test("wrapped shape: {\"claudeAiOauth\": {\"accessToken\": ...}}")
    func wrappedShape() throws {
        let json = Data(#"{"claudeAiOauth": {"accessToken": "tok-123", "refreshToken": "ref-999"}}"#.utf8)
        #expect(try CredentialsParser.accessToken(fromJSON: json) == "tok-123")
    }

    @Test("bare OAuth object shape: {\"accessToken\": ...}")
    func bareShape() throws {
        let json = Data(#"{"accessToken": "tok-456", "expiresAt": 1}"#.utf8)
        #expect(try CredentialsParser.accessToken(fromJSON: json) == "tok-456")
    }

    @Test("token is trimmed of stray whitespace")
    func trimsWhitespace() throws {
        let json = Data(#"{"accessToken": "  tok-789\n"}"#.utf8)
        #expect(try CredentialsParser.accessToken(fromJSON: json) == "tok-789")
    }

    @Test("unrecognized JSON shape throws, without echoing contents")
    func unrecognizedShape() {
        let json = Data(#"{"something": "else"}"#.utf8)
        #expect(throws: CredentialError.self) {
            try CredentialsParser.accessToken(fromJSON: json)
        }
    }

    @Test("malformed JSON throws")
    func malformedJSON() {
        let json = Data("not json at all".utf8)
        #expect(throws: CredentialError.self) {
            try CredentialsParser.accessToken(fromJSON: json)
        }
    }

    @Test("empty token rejected")
    func emptyToken() {
        let json = Data(#"{"accessToken": "   "}"#.utf8)
        #expect(throws: CredentialError.self) {
            try CredentialsParser.accessToken(fromJSON: json)
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
