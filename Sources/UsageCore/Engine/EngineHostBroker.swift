import Foundation

/// Which side of the engine a process runs: the engine itself, or a
/// renderer of its digest.
public enum EngineRole: String, Sendable, Equatable {
    case host
    case client
}

/// The host arbitration rules — pure, so every transition is a unit test.
///
/// The daemon wins: when `usaged` is alive the app renders as a client.
/// The app is the embedded fallback — no daemon, no lease holder, and the
/// app hosts the engine in-process; the moment a daemon announces itself
/// the app shuts its embedded engine down, releases the lease, and flips
/// to client. A client flips back only when the digest heartbeat goes
/// stale beyond doubt AND the lease is free (the holder really died —
/// flock releases on death, so a held lease is always a live process).
public enum EngineHostBroker {
    /// How often a hosting app re-checks for a daemon, and a client app
    /// re-checks the heartbeat.
    public static let checkInterval: TimeInterval = 30
    /// A daemon liveness marker younger than this means a daemon is up
    /// (usaged rewrites it every 2s while waiting for — or holding — the
    /// lease).
    public static let daemonAliveWindow: TimeInterval = 10
    /// The takeover floor: a heartbeat must be at least this stale before
    /// a client considers the host dead.
    public static let takeoverFloor: TimeInterval = 180

    // MARK: - Artifact paths (beside the digest, bundle root)

    public static func lockURL(bundleID: String) -> URL {
        StorageScope.rootSupportDirectory(bundleID: bundleID).appending(path: "engine.lock")
    }

    public static func socketURL(bundleID: String) -> URL {
        StorageScope.rootSupportDirectory(bundleID: bundleID).appending(path: "control.sock")
    }

    /// Touched by usaged every 2s — how an app that HOLDS the lease learns
    /// a daemon wants it (the daemon cannot bind the socket or take the
    /// lease while the app holds it, so it needs one writable signal).
    public static func daemonMarkerURL(bundleID: String) -> URL {
        StorageScope.rootSupportDirectory(bundleID: bundleID).appending(path: "daemon.alive")
    }

    // MARK: - Decisions

    /// The app's startup (and periodic) role. The lease is the strongest
    /// fact: held means a live engine host exists somewhere.
    public static func role(leaseHeldByOther: Bool, daemonAlive: Bool) -> EngineRole {
        if daemonAlive || leaseHeldByOther { return .client }
        return .host
    }

    /// While hosting embedded: yield the moment a daemon is alive.
    public static func shouldYield(daemonMarkerAge: TimeInterval?) -> Bool {
        guard let daemonMarkerAge else { return false }
        return daemonMarkerAge < daemonAliveWindow
    }

    /// While client: the host is presumed dead when the digest heartbeat
    /// outages both twice its own poll horizon and the floor. The caller
    /// must ALSO verify the lease is free before hosting — a live holder
    /// beats any staleness heuristic.
    public static func heartbeatStale(
        generatedAt: Date, nextPollAt: Date?, now: Date
    ) -> Bool {
        let age = now.timeIntervalSince(generatedAt)
        let horizon = nextPollAt.map { max(0, $0.timeIntervalSince(generatedAt)) } ?? 0
        return age > max(2 * horizon, takeoverFloor)
    }
}
