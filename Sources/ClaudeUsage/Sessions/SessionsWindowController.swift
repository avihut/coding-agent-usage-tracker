import AppKit
import SwiftUI

/// Owns the one Sessions window. Same contract as SettingsWindowController:
/// an LSUIElement app gets no scene wiring for free, so the window is created
/// on first show, kept alive across closes, and explicitly fronted —
/// cooperative activation won't bring a background app's window forward on
/// its own.
@MainActor
final class SessionsWindowController {
    private let store: UsageStore
    private let registry: ProviderRegistry
    private var window: NSWindow?

    init(store: UsageStore, registry: ProviderRegistry) {
        self.store = store
        self.registry = registry
    }

    /// Closes and drops the window. Called when the registry retires this
    /// controller's store — releasing a visible NSWindow out from under
    /// AppKit is not an option, so the switch closes it first.
    func close() {
        window?.close()
        window = nil
    }

    func show() {
        if window == nil {
            let host = NSHostingController(
                rootView: SessionsView(store: store, registry: registry))
            let window = NSWindow(contentViewController: host)
            window.title = "Sessions"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1100, height: 700))
            window.isReleasedWhenClosed = false
            window.center()
            // After centering so a remembered size/position wins over it.
            window.setFrameAutosaveName("ClaudeUsageSessions")
            self.window = window
        }
        // The sidebar should be at most seconds stale when the user looks.
        store.scanActivity(force: true)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // Activation is cooperative and may be declined; regardless-front
        // keeps the window visible even if the app stays inactive.
        window?.orderFrontRegardless()
    }
}
