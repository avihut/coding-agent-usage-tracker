import AppKit
import Network

/// Emits refresh triggers; owns no refresh logic or cadence. The store decides
/// whether a trigger actually runs (gate + single-flight + backoff) and
/// schedules every fire one-shot, so the delay can change between polls.
@MainActor
final class Scheduler {
    var onTrigger: ((UsageStore.RefreshReason) -> Void)?

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var networkWasSatisfied = true

    /// When the pending one-shot will fire; nil once it has fired, which is
    /// how the store tells a live timer from a spent one.
    var nextFireDate: Date? {
        guard let timer, timer.isValid else { return nil }
        return timer.fireDate
    }

    /// Starts the event sources. Polling is driven by `schedule(after:)`.
    func start() {
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

    /// Tears the event sources down — the wake observer would otherwise be
    /// retained by NotificationCenter forever and the path monitor would
    /// keep its queue alive. Called when the registry retires this
    /// scheduler's store.
    func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        onTrigger = nil
    }

    /// Replaces the pending fire with one `delay` seconds out.
    func schedule(after delay: TimeInterval) {
        timer?.invalidate()
        let clamped = max(1, delay)
        let timer = Timer.scheduledTimer(withTimeInterval: clamped, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.onTrigger?(.timer)
            }
        }
        // Background poller: generous tolerance lets macOS coalesce wakeups.
        timer.tolerance = min(max(5, clamped * 0.1), clamped / 2)
        self.timer = timer
    }
}
