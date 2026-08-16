import Foundation

/// The whole refresh pipeline: fresh token read → one fetch (with a single
/// transport-only retry) → decode → cache. Returns a renderable state in
/// every failure mode. Provider-agnostic: the injected `UsageProvider` owns
/// where credentials live, how the fetch speaks, and how bytes become a
/// snapshot — this type owns only the orchestration. No UI, no shared state,
/// fully testable.
public struct UsageService: Sendable {
    let provider: any UsageProvider
    let cache: UsageCache
    /// Delay before the one transport retry (spec §6). Injectable so tests
    /// don't sleep.
    let retryDelay: Duration

    public init(
        provider: any UsageProvider,
        cache: UsageCache,
        retryDelay: Duration = .seconds(2)
    ) {
        self.provider = provider
        self.cache = cache
        self.retryDelay = retryDelay
    }

    public func refresh(thresholds: Thresholds = .standard) async -> DisplayState {
        // The token is re-read every cycle (the agent rotates it) and lives
        // only in this frame for the duration of one request (spec §5).
        let token: String
        let plan: PlanInfo
        do {
            let credential = try provider.credentials.readCredential()
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

        let fetchedAt = Date()
        guard let snapshot = try? provider.snapshot(
            fromRawUsage: body, fetchedAt: fetchedAt, plan: plan, thresholds: thresholds)
        else {
            return fallback(.schema, thresholds: thresholds)
        }
        cache.save(body: body, fetchedAt: fetchedAt)
        return .live(snapshot)
    }

    /// Exactly one retry, transport failures only — a 401 won't fix itself,
    /// and this runs unattended against an undocumented endpoint (spec §6).
    private func fetchWithOneRetry(token: String) async throws -> Data {
        do {
            return try await provider.fetchRawUsage(accessToken: token)
        } catch let error as UsageClientError {
            guard case .network = error else { throw error }
            try? await Task.sleep(for: retryDelay)
            return try await provider.fetchRawUsage(accessToken: token)
        }
    }

    private func fallback(_ error: UsageError, thresholds: Thresholds) -> DisplayState {
        guard let (body, fetchedAt) = cache.load(),
              let snapshot = try? provider.snapshot(
                  fromRawUsage: body, fetchedAt: fetchedAt, plan: nil, thresholds: thresholds)
        else { return .unavailable(error) }
        return .cached(snapshot, error: error)
    }
}
