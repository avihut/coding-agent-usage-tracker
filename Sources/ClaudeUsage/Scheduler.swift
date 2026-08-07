import AppKit
import Network

/// Emits refresh triggers; owns no refresh logic. The store decides whether a
/// trigger actually runs (gate + single-flight).
@MainActor
final class Scheduler {
    var onTrigger: ((UsageStore.RefreshReason) -> Void)?

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var networkWasSatisfied = true

    /// When the repeating timer will next fire (tolerance may shift it a bit).
    var nextFireDate: Date? { timer?.fireDate }

    func start(interval: TimeInterval) {
        startTimer(interval: interval)

        // Stale numbers after lid-open are what make these widgets feel
        // broken (spec §9) — refresh on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onTrigger?(.wake)
            }
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                if satisfied && !self.networkWasSatisfied {
                    self.onTrigger?(.networkRestored)
                }
                self.networkWasSatisfied = satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.avihu.ClaudeUsage.network-monitor"))
        pathMonitor = monitor
    }

    func restart(interval: TimeInterval) {
        startTimer(interval: interval)
    }

    private func startTimer(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.onTrigger?(.timer)
            }
        }
        // Background poller: generous tolerance lets macOS coalesce wakeups.
        timer.tolerance = max(30, interval * 0.1)
        self.timer = timer
    }
}
