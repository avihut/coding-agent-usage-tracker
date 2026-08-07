import Foundation
import Testing
@testable import UsageCore

@Suite("UsageClient error mapping")
struct UsageClientTests {
    @Test("2xx returns the body")
    func success() async throws {
        let token = uniqueToken()
        StubURLProtocol.register(token: token) { _ in (200, Data("{}".utf8)) }
        let data = try await stubbedClient().fetchRawUsage(accessToken: token)
        #expect(data == Data("{}".utf8))
    }

    @Test("sends bearer token, beta header, and honest User-Agent")
    func requestShape() async throws {
        let token = uniqueToken()
        let captured = Box<URLRequest?>(nil)
        StubURLProtocol.register(token: token) { request in
            captured.value = request
            return (200, Data("{}".utf8))
        }
        _ = try await stubbedClient().fetchRawUsage(accessToken: token)

        let request = try #require(captured.value)
        #expect(request.url == UsageClient.endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == AppIdentity.userAgent)
    }

    @Test("401 and 403 map to signInExpired", arguments: [401, 403])
    func authFailure(status: Int) async {
        let token = uniqueToken()
        StubURLProtocol.register(token: token) { _ in (status, Data()) }
        do {
            _ = try await stubbedClient().fetchRawUsage(accessToken: token)
            Issue.record("expected a throw")
        } catch let error as UsageClientError {
            guard case .signInExpired = error else {
                Issue.record("expected signInExpired, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type")
        }
    }

    @Test("other HTTP statuses map to .http(code)")
    func serverError() async {
        let token = uniqueToken()
        StubURLProtocol.register(token: token) { _ in (500, Data()) }
        do {
            _ = try await stubbedClient().fetchRawUsage(accessToken: token)
            Issue.record("expected a throw")
        } catch let error as UsageClientError {
            guard case .http(500) = error else {
                Issue.record("expected http(500), got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type")
        }
    }

    @Test("transport failures map to .network")
    func transportFailure() async {
        let token = uniqueToken()
        StubURLProtocol.register(token: token) { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await stubbedClient().fetchRawUsage(accessToken: token)
            Issue.record("expected a throw")
        } catch let error as UsageClientError {
            guard case .network = error else {
                Issue.record("expected network, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type")
        }
    }
}
