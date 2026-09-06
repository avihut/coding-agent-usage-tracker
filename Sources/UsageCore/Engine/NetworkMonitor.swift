import Foundation
import Network

/// The network-restored impulse, ONE per host process: it used to live
/// inside every Scheduler, which was fine with one engine and would have
/// meant N path monitors with N profiles. The host fans a restore out to
/// every engine's `noteNetworkRestored()`.
@MainActor
final class NetworkMonitor {
    var onRestored: (() -> Void)?

    private var pathMonitor: NWPathMonitor?
    private var wasSatisfied = true

    func start() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                if satisfied && !self.wasSatisfied {
                    self.onRestored?()
                }
                self.wasSatisfied = satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.avihu.ClaudeUsage.network-monitor"))
        pathMonitor = monitor
    }

    /// The path monitor would otherwise keep its queue alive.
    func stop() {
        pathMonitor?.cancel()
        pathMonitor = nil
        onRestored = nil
    }
}
