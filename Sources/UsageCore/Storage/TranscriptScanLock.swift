import Darwin
import Foundation

/// One out-of-process transcript scan per account at a time, machine-wide.
///
/// A whole-corpus scan by a non-holder (usage-cli's `sessions --all`, a
/// `session --all` no engine answered) costs seconds of CPU once live
/// transcripts have changed, and callers on a timer overlap: 18 of them in
/// flight kept a 12-core Mac at load 221 (issue #24). The second caller
/// does NOT wait — a waiting lock queues without bound once callers arrive
/// faster than scans finish — it gives up and says so.
///
/// The lock is an exclusive non-blocking `flock(2)` on the account's
/// EXISTING storage directory, so it adds no file to the app's scopes (spec
/// §10 enumerates the arbitration artifacts; this is not one). The kernel
/// drops it with the descriptor, so a crashed scan can't wedge the next.
final class TranscriptScanLock {
    enum Outcome {
        case held(TranscriptScanLock)
        /// Another process is scanning this account right now.
        case busy
        /// The directory doesn't exist yet — no host has ever written this
        /// account's scope, so there is nothing to contend over and the
        /// scan runs unguarded (it creates nothing either way).
        case unavailable
    }

    private let fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    static func acquire(directory: URL) -> Outcome {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return .unavailable }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            if failure == EINTR { continue }
            close(fd)
            return failure == EWOULDBLOCK ? .busy : .unavailable
        }
        return .held(TranscriptScanLock(fd: fd))
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
