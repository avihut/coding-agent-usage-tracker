import Foundation

/// The whole refresh pipeline: fresh token read → one fetch (with a single
/// transport-only retry) → decode → cache. Returns a renderable state in
/// every failure mode. No UI, no shared state, fully testable.
public struct UsageService: Sendable {
    let credentials: CredentialChain
    let client: UsageClient
    let cache: UsageCache
    /// Delay before the one transport retry (spec §6). Injectable so tests
    /// don't sleep.
    let retryDelay: Duration

    public init(
        credentials: CredentialChain,
        client: UsageClient,
        cache: UsageCache,
        retryDelay: Duration = .seconds(2)
    ) {
        self.credentials = credentials
        self.client = client
        self.cache = cache
        self.retryDelay = retryDelay
    }

    public static func standard(bundleID: String) -> UsageService {
        UsageService(credentials: .standard, client: UsageClient(), cache: .standard(bundleID: bundleID))
    }

    public func refresh(thresholds: Thresholds = .standard) async -> DisplayState {
        // The token is re-read every cycle (Claude Code rotates it) and lives
        // only in this frame for the duration of one request (spec §5).
        let token: String
        let plan: PlanInfo
        do {
            let credential = try credentials.readCredential()
            token = credential.accessToken
            plan = credential.plan
        } catch let error as CredentialError {
            return fallback(.from(error), thresholds: thresholds)
        } catch {
            return fallback(.credentialsUnreadable, thresholds: thresholds)
        }

        let body: Data
        do {
            body = try await fetchWithOneRetry(token: token)
        } catch let error as UsageClientError {
            return fallback(.from(error), thresholds: thresholds)
        } catch {
            return fallback(.network, thresholds: thresholds)
        }

        guard let response = try? UsageResponse.decode(from: body) else {
            return fallback(.schema, thresholds: thresholds)
        }
        let snapshot = Snapshot(response: response, fetchedAt: Date(), plan: plan, thresholds: thresholds)
        cache.save(body: body, fetchedAt: snapshot.fetchedAt)
        return .live(snapshot)
    }

    /// Exactly one retry, transport failures only — a 401 won't fix itself,
    /// and this runs unattended against an undocumented endpoint (spec §6).
    private func fetchWithOneRetry(token: String) async throws -> Data {
        do {
            return try await client.fetchRawUsage(accessToken: token)
        } catch let error as UsageClientError {
            guard case .network = error else { throw error }
            try? await Task.sleep(for: retryDelay)
            return try await client.fetchRawUsage(accessToken: token)
        }
    }

    private func fallback(_ error: UsageError, thresholds: Thresholds) -> DisplayState {
        guard let (body, fetchedAt) = cache.load(),
              let response = try? UsageResponse.decode(from: body)
        else { return .unavailable(error) }
        return .cached(
            Snapshot(response: response, fetchedAt: fetchedAt, thresholds: thresholds),
            error: error)
    }
}
