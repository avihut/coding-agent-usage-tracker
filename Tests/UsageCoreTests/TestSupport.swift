import Foundation
@testable import UsageCore

func loadFixture(_ name: String) -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    return try! Data(contentsOf: url)
}

/// Thread-safe box for capturing values inside @Sendable stub closures.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) {
        self._value = value
    }

    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    func mutate(_ transform: (inout T) -> Void) {
        lock.withLock { transform(&_value) }
    }
}

/// URLProtocol stub that routes by bearer token, so concurrently running
/// suites never trample each other's handlers: every test registers its own
/// unique token and only sees its own requests.
final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    typealias FullHandler = @Sendable (URLRequest) throws -> (Int, Data, [String: String]?)

    private static let registry = Box<[String: FullHandler]>([:])

    static func register(token: String, handler: @escaping Handler) {
        registerWithHeaders(token: token) { request in
            let (status, data) = try handler(request)
            return (status, data, nil)
        }
    }

    /// Variant for tests that need response headers (e.g. Retry-After).
    static func registerWithHeaders(token: String, handler: @escaping FullHandler) {
        registry.mutate { $0[token] = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let token = auth.replacingOccurrences(of: "Bearer ", with: "")
            guard let handler = Self.registry.value[token] else {
                throw URLError(.unsupportedURL)
            }
            let (status, data, headers) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

func uniqueToken() -> String {
    "tok-\(UUID().uuidString)"
}

func stubbedClient() -> UsageClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return UsageClient(session: URLSession(configuration: config))
}

struct StubCredentialSource: CredentialSource {
    let name = "stub"
    let result: Result<String, CredentialError>

    func readCredential() throws -> Credential {
        Credential(accessToken: try result.get(), sourceName: name)
    }
}

func temporaryCache() -> UsageCache {
    UsageCache(directory: FileManager.default.temporaryDirectory
        .appending(path: "claude-usage-tests-\(UUID().uuidString)"))
}

func makeService(
    token: String,
    credential: Result<String, CredentialError>? = nil,
    cache: UsageCache
) -> UsageService {
    UsageService(
        provider: ClaudeProvider(
            credentials: CredentialChain(
                sources: [StubCredentialSource(result: credential ?? .success(token))]),
            client: stubbedClient()),
        cache: cache,
        retryDelay: .zero
    )
}

/// A snapshot built the way the Claude provider builds one — the shorthand
/// most suites want when they just need "a decoded snapshot of this fixture".
func makeSnapshot(
    response: UsageResponse, fetchedAt: Date = Date(),
    thresholds: Thresholds = .standard
) -> Snapshot {
    MeterBuilder.snapshot(from: response, fetchedAt: fetchedAt, thresholds: thresholds)
}
