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
    /// The host's liveness (2026-11-21): past the heartbeat cutoff with the
    /// lease held it is BUSY — alive, starved, its numbers shown as of their
    /// real age — and only with the lease free is it offline. Judged on every
    /// 2 s tick; the lease is probed only past the cutoff. A fixed (demo)
    /// feed carries what its hatch says.
    private(set) var liveness: EngineLiveness = .live
    @ObservationIgnored private var lockURL: URL?

    @ObservationIgnored let socketURL: URL
    @ObservationIgnored private let digestURL: URL
    @ObservationIgnored private var watchTimer: Timer?
    @ObservationIgnored private var lastModified: Date?

    init(bundleID: String) {
        digestURL = LiveState.fileURL(bundleID: bundleID)
        socketURL = EngineHostBroker.socketURL(bundleID: bundleID)
        lockURL = EngineHostBroker.lockURL(bundleID: bundleID)
        reload()
        judgeLiveness()
        // A 2s stat is the reload signal — cheaper and simpler than
        // re-arming a DispatchSource across the publisher's atomic renames.
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer.tolerance = 0.5
        watchTimer = timer
    }

    /// A feed that never changes — the launch hatches' synthetic digest,
    /// with the liveness the hatch asks for (`--demo-engine-busy`).
    init(fixed: LiveState, liveness: EngineLiveness = .live) {
        digestURL = URL(fileURLWithPath: "/dev/null")
        socketURL = URL(fileURLWithPath: "/dev/null")
        digest = fixed
        self.liveness = liveness
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
        judgeLiveness()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: digestURL.path),
              let modified = attributes[.modificationDate] as? Date
        else { return }
        if let lastModified, modified <= lastModified { return }
        lastModified = modified
        reload()
    }

    private func judgeLiveness() {
        guard let lockURL else { return }
        let judged = EngineHostBroker.liveness(
            generatedAt: digest?.engine.generatedAt, nextPollAt: digest?.engine.nextPollAt,
            now: Date(), leaseHeld: false)
        // The probe only past the cutoff: a fresh digest needs no second word.
        let next = judged == .live
            ? EngineLiveness.live
            : EngineHostBroker.liveness(
                generatedAt: digest?.engine.generatedAt, nextPollAt: digest?.engine.nextPollAt,
                now: Date(), leaseHeld: EngineLease.isHeld(at: lockURL))
        if next != liveness { liveness = next }
    }

    private func reload() {
        guard let data = try? Data(contentsOf: digestURL),
              let decoded = try? LiveState.decoder().decode(LiveState.self, from: data)
        else { return }
        digest = decoded
    }
}
