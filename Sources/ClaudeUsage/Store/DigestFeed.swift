import Foundation
import Observation
import UsageCore

/// The app's one reader of live-state.json in client mode: a 2s stat and
/// ONE decode per heartbeat, shared by every profile's `DigestClient`
/// (which reads its own section off `digest`). Commands go back over the
/// control socket from here too. Everything read-only — the lease holder
/// stays the sole writer.
@MainActor
@Observable
final class DigestFeed {
    private(set) var digest: LiveState?
    private(set) var isShutDown = false

    @ObservationIgnored let socketURL: URL
    @ObservationIgnored private let digestURL: URL
    @ObservationIgnored private var watchTimer: Timer?
    @ObservationIgnored private var lastModified: Date?

    init(bundleID: String) {
        digestURL = LiveState.fileURL(bundleID: bundleID)
        socketURL = EngineHostBroker.socketURL(bundleID: bundleID)
        reload()
        // A 2s stat is the reload signal — cheaper and simpler than
        // re-arming a DispatchSource across the publisher's atomic renames.
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer.tolerance = 0.5
        watchTimer = timer
    }

    /// A feed that never changes — the launch hatches' synthetic digest.
    init(fixed: LiveState) {
        digestURL = URL(fileURLWithPath: "/dev/null")
        socketURL = URL(fileURLWithPath: "/dev/null")
        digest = fixed
    }

    /// The digest heartbeat's age — the registry's takeover check reads it.
    var digestStaleness: (generatedAt: Date, nextPollAt: Date?)? {
        digest.map { ($0.engine.generatedAt, $0.engine.nextPollAt) }
    }

    /// A host from before profiles existed knows only the one-engine verbs.
    var isLegacyHost: Bool { digest?.profiles == nil }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        watchTimer?.invalidate()
        watchTimer = nil
    }

    func send(_ command: ControlCommand) {
        guard !isShutDown, socketURL.path != "/dev/null" else { return }
        let socketURL = socketURL
        Task.detached(priority: .utility) {
            _ = ControlSocket.send(command, to: socketURL)
        }
    }

    private func tick() {
        guard !isShutDown else { return }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: digestURL.path),
              let modified = attributes[.modificationDate] as? Date
        else { return }
        if let lastModified, modified <= lastModified { return }
        lastModified = modified
        reload()
    }

    private func reload() {
        guard let data = try? Data(contentsOf: digestURL),
              let decoded = try? LiveState.decoder().decode(LiveState.self, from: data)
        else { return }
        digest = decoded
    }
}
