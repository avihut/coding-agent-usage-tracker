import AppKit

/// Puts the app in the Dock and the Cmd+Tab switcher while any real window
/// is open, and returns it to a pure menu bar accessory when the last one
/// closes. LSUIElement in the plist sets the launch state; this is the
/// runtime override on top of it.
///
/// Windows enroll on every show — the visible set makes re-shows idempotent —
/// and report back when they close. One holder for all windows, because the
/// policy is process-wide: with per-window flips, closing Settings would
/// yank the Dock tile out from under an open Sessions window.
@MainActor
final class DockPresence {
    static let shared = DockPresence()
    private var visible: Set<ObjectIdentifier> = []
    private var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Holds the app in the Dock while `window` stays open. Hears the close
    /// through `willCloseNotification` — every close path (the red button,
    /// Cmd+W, a teardown `close()`) posts it — so a window's delegate seat
    /// stays free for the window itself.
    func adopt(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        visible.insert(id)
        if observers[id] == nil {
            observers[id] = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.closed(id) }
            }
        }
        NSApp.setActivationPolicy(.regular)
    }

    private func closed(_ id: ObjectIdentifier) {
        visible.remove(id)
        if let observer = observers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
        if visible.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
