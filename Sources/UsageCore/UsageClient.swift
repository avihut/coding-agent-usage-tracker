import Foundation

public enum UsageClientError: Error, Sendable {
    /// 401 or 403 — the access token is stale; opening Claude Code refreshes it.
    case signInExpired
    /// 429 — the server asked us to slow down. Carries Retry-After when sent.
    case rateLimited(retryAfter: TimeInterval?)
    /// Any other non-2xx status.
    case http(Int)
    /// Transport-level failure (offline, DNS, timeout). The caller may retry
    /// once; this client never retries on its own.
    case network(URLError)
    /// 2xx but the body doesn't decode — the undocumented schema moved.
    case schema
}

/// One call against the usage endpoint. No retry policy, no UI, no state.
///
/// The endpoint is undocumented — it is what the Claude app's own Usage screen
/// calls. Everything downstream decodes defensively; this type only moves bytes.
public struct UsageClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            // Ephemeral: no cookie/cache/credential storage touches disk.
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            self.session = URLSession(configuration: config)
        }
    }

    /// Fetches the raw response body. The token lives in the request header for
    /// the duration of this one call and is never stored on this type.
    public func fetchRawUsage(accessToken: String) async throws -> Data {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw UsageClientError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageClientError.network(URLError(.badServerResponse))
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw UsageClientError.signInExpired
        case 429:
            throw UsageClientError.rateLimited(
                retryAfter: RetryAfter.seconds(from: http.value(forHTTPHeaderField: "Retry-After")))
        default:
            throw UsageClientError.http(http.statusCode)
        }
    }
}
