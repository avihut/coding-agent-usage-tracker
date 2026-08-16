import CoreServices
import Foundation

/// Push signal that the agent is in use on this machine: FSEvents on the
/// provider's trace directories (Claude Code's `~/.claude/projects`), which
/// get written the moment a session does anything. Strictly observational —
/// nothing inside them is opened, read, or written here; FSEvents only
/// reports that paths changed (spec §10 still holds: the scanners do the
/// reading, read-only).
final class AgentActivityWatcher {
    private let stream: FSEventStreamRef

    /// `onActivity` is delivered on the main queue. `kFSEventStreamCreateFlagNoDefer`
    /// makes the first event after quiet arrive immediately — that's the
    /// re-engagement moment the store wants to react to — while bursts within
    /// `latency` seconds coalesce into one callback. Directories that don't
    /// exist yet (the agent never ran here) are skipped; nil when none exist.
    @MainActor
    init?(directories: [URL], latency: TimeInterval = 10, onActivity: @escaping @MainActor @Sendable () -> Void) {
        let existing = directories.filter { directory in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        guard !existing.isEmpty else { return nil }

        // The stream holds the box at +1 (passRetained); FSEventStreamInvalidate
        // calls the release callback exactly once, balancing it.
        let box = Unmanaged.passRetained(CallbackBox(onActivity))
        var context = FSEventStreamContext(
            version: 0,
            info: box.toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue().fire()
            },
            &context,
            existing.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        else {
            box.release() // no stream took ownership of the +1
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

/// Bridges the C callback's context pointer back to a Swift closure. The
/// stream's dispatch queue is main, so hopping onto the main actor is an
/// assumption, not a dispatch. Sendable for real: one immutable closure.
private final class CallbackBox: Sendable {
    private let handler: @MainActor @Sendable () -> Void

    init(_ handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
    }

    func fire() {
        MainActor.assumeIsolated { handler() }
    }
}
