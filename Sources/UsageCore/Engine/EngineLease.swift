import Darwin
import Foundation

/// The single-writer interlock: an exclusive `flock(2)` on
/// `<root>/engine.lock`. Whoever holds it runs the engine — and therefore
/// the publisher and the control socket. The kernel releases the lock when
/// the holder exits, crashes, or is killed, so a stale lock cannot exist
/// and no pid-file heuristics are needed.
@MainActor
public final class EngineLease {
    public let lockURL: URL
    private var fd: Int32 = -1

    public init(lockURL: URL) {
        self.lockURL = lockURL
    }

    public var isAcquired: Bool { fd >= 0 }

    /// Non-blocking: true when this process now holds the lease.
    @discardableResult
    public func acquire() -> Bool {
        guard fd < 0 else { return true }
        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let handle = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard handle >= 0 else { return false }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else {
            close(handle)
            return false
        }
        fd = handle
        return true
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    /// Probe without taking: true when SOME process holds the lease right
    /// now. Uses its own descriptor, so a successful trial acquisition is
    /// released immediately and never disturbs a real holder.
    public static func isHeld(at lockURL: URL) -> Bool {
        let handle = open(lockURL.path, O_RDWR)
        guard handle >= 0 else { return false }
        defer { close(handle) }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(handle, LOCK_UN)
        return false
    }

    deinit {
        // The kernel would release on exit anyway; this covers a dropped
        // lease object inside a still-running process.
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }
}
