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

    public static func lockURL(bundleID: String, roots: StorageScope.Roots = .standard) -> URL {
        StorageScope.rootSupportDirectory(bundleID: bundleID, roots: roots)
            .appending(path: "engine.lock")
    }

    public static func socketURL(bundleID: String, roots: StorageScope.Roots = .standard) -> URL {
        StorageScope.rootSupportDirectory(bundleID: bundleID, roots: roots)
            .appending(path: "control.sock")
    }

    /// Touched by usaged every 2s — how an app that HOLDS the lease learns
    /// a daemon wants it (the daemon cannot bind the socket or take the
    /// lease while the app holds it, so it needs one writable signal).
    public static func daemonMarkerURL(bundleID: String, roots: StorageScope.Roots = .standard) -> URL {
        StorageScope.rootSupportDirectory(bundleID: bundleID, roots: roots)
            .appending(path: "daemon.alive")
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

    /// How a face speaks about the host (2026-11-21). A digest past the
    /// heartbeat cutoff only says nobody REWROTE it lately; the lease says
    /// whether anybody is there. Held means a live process — starved under
    /// load, still scanning — so the honest word is "busy", with the digest's
    /// numbers shown as of their real age. Only a free lease is offline.
    /// The TUI's `freshness` is this rule in Rust; both decode the same
    /// vectors (`Fixtures/liveness-cases.json`).
    public static func liveness(
        generatedAt: Date?, nextPollAt: Date?, now: Date, leaseHeld: Bool
    ) -> EngineLiveness {
        // No digest yet behind a held lease is a host still starting (its
        // first publish can wait on a starved CPU): busy, not gone.
        guard let generatedAt else { return leaseHeld ? .busy : .offline }
        guard heartbeatStale(generatedAt: generatedAt, nextPollAt: nextPollAt, now: now)
        else { return .live }
        return leaseHeld ? .busy : .offline
    }
}

/// Whether a face's host is publishing, alive but late, or gone.
public enum EngineLiveness: String, Sendable, Equatable, Codable {
    /// The digest is inside the heartbeat cutoff.
    case live
    /// Past the cutoff — or nothing published yet — while a process holds
    /// the engine lease: alive, busy.
    case busy
    /// Past the cutoff (or no digest at all) with the lease free.
    case offline
}
