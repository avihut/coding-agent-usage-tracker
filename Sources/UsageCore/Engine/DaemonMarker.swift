import Foundation

/// What usaged writes INTO `daemon.alive` (2026-11-21): which process it is
/// and which build it runs. The file's mtime stays the liveness signal the
/// app reads (`EngineHostBroker.daemonAliveWindow`); the content is for
/// `LaunchAgentInstaller.ensure`, which restarts a daemon whose binary was
/// rebuilt under it. Written from first breath — before the lease, before
/// any publish — so even a daemon still waiting for the engine, or starved
/// before its first digest, says what it is. A pre-0.10x daemon writes an
/// empty file, which decodes to nil: unknown, never a mismatch.
public struct DaemonMarker: Codable, Sendable, Equatable {
    public let pid: Int32
    public let version: String
    /// `BuildIdentity.running()`; nil when the image carries no UUID.
    public let build: String?

    public init(pid: Int32, version: String, build: String?) {
        self.pid = pid
        self.version = version
        self.build = build
    }

    /// This process.
    public static func current() -> DaemonMarker {
        DaemonMarker(
            pid: ProcessInfo.processInfo.processIdentifier, version: AppIdentity.version,
            build: BuildIdentity.running())
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    /// Nil for an empty (pre-marker-content) or torn file.
    public static func decode(_ data: Data) -> DaemonMarker? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(DaemonMarker.self, from: data)
    }

    public static func read(at url: URL) -> DaemonMarker? {
        FileManager.default.contents(atPath: url.path).flatMap(decode)
    }
}
