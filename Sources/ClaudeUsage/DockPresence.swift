import AppKit

/// Puts the app in the Dock and the Cmd+Tab switcher while any real window
/// (Sessions, Settings) is open, and returns it to a pure menu bar accessory
/// when the last one closes. LSUIElement in the plist sets the launch state;
/// this is the runtime override on top of it.
///
/// Windows enroll on every show — the visible set makes re-shows idempotent —
/// and report back when they close. One holder for all windows, because the
/// policy is process-wide: with per-window flips, closing Settings would
/// yank the Dock tile out from under an open Sessions window.
@MainActor
final class DockPresence: NSObject {
    static let shared = DockPresence()
    private var visible: Set<ObjectIdentifier> = []

    /// Holds the app in the Dock while `window` stays open. Takes the
    /// window's delegate seat to hear the close — both hosted windows are
    /// hand-built and nothing else claims it.
    func adopt(_ window: NSWindow) {
        window.delegate = self
        visible.insert(ObjectIdentifier(window))
        NSApp.setActivationPolicy(.regular)
    }
}

/// Every close path — the red button, Cmd+W, and a teardown `close()` —
/// lands in `windowWillClose`. AppKit delivers it on the main thread, which
/// is what lets the main-actor implementation satisfy the nonisolated
/// requirement under a `@preconcurrency` conformance.
extension DockPresence: @preconcurrency NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        visible.remove(ObjectIdentifier(window))
        if visible.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
