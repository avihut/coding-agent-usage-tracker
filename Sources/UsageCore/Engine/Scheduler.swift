import Foundation

/// Emits refresh triggers; owns no refresh logic or cadence. The engine
/// decides whether a trigger actually runs (gate + single-flight + backoff)
/// and schedules every fire one-shot, so the delay can change between polls.
/// The other impulses arrive from the host process: system wake
/// (`UsageEngine.noteWake()` — the app's NSWorkspace observer, the daemon's
/// IOKit power callback) and network restore (`noteNetworkRestored()`, from
/// the host's one `NetworkMonitor`).
@MainActor
final class Scheduler {
    var onTrigger: ((UsageEngine.RefreshReason) -> Void)?

    private var timer: Timer?

    /// When the pending one-shot will fire; nil once it has fired, which is
    /// how the engine tells a live timer from a spent one.
    var nextFireDate: Date? {
        guard let timer, timer.isValid else { return nil }
        return timer.fireDate
    }

    /// Tears the timer down. Called when the engine's host retires it.
    func stop() {
        timer?.invalidate()
        timer = nil
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
