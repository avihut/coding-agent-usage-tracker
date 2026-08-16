import Foundation
import Network

/// Emits refresh triggers; owns no refresh logic or cadence. The engine
/// decides whether a trigger actually runs (gate + single-flight + backoff)
/// and schedules every fire one-shot, so the delay can change between polls.
/// System wake is the one impulse the host process must supply itself
/// (`UsageEngine.noteWake()`) — the app's NSWorkspace observer and the
/// daemon's IOKit power callback both live outside core.
@MainActor
final class Scheduler {
    var onTrigger: ((UsageEngine.RefreshReason) -> Void)?

    private var timer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var networkWasSatisfied = true

    /// When the pending one-shot will fire; nil once it has fired, which is
    /// how the engine tells a live timer from a spent one.
    var nextFireDate: Date? {
        guard let timer, timer.isValid else { return nil }
        return timer.fireDate
    }

    /// Starts the event sources. Polling is driven by `schedule(after:)`.
    func start() {
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

    /// Tears the event sources down — the path monitor would otherwise keep
    /// its queue alive. Called when the engine's host retires it.
    func stop() {
        timer?.invalidate()
        timer = nil
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
