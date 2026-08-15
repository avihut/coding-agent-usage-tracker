import AppKit
import SwiftUI

/// Carries "open to this session" requests from outside surfaces (the
/// panel's shortlist) into the sidebar. Consume-once: the view applies the
/// id to its selection and clears it — a plain init parameter couldn't
/// retarget a window that's already open.
@MainActor @Observable
final class SessionsNavigator {
    var requested: String?
}

/// Owns the one Sessions window. Same contract as SettingsWindowController:
/// an LSUIElement app gets no scene wiring for free, so the window is created
/// on first show, kept alive across closes, and explicitly fronted —
/// cooperative activation won't bring a background app's window forward on
/// its own.
@MainActor
final class SessionsWindowController {
    private let store: UsageStore
    private let registry: ProviderRegistry
    private let navigator = SessionsNavigator()
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

    func show(selecting sessionID: String? = nil) {
        if window == nil {
            let host = NSHostingController(
                rootView: SessionsView(store: store, registry: registry, navigator: navigator))
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
        if let sessionID { navigator.requested = sessionID }
        // The sidebar should be at most seconds stale when the user looks.
        store.scanActivity(force: true)
        // Dock tile + Cmd+Tab entry ride window visibility; the policy must
        // flip before activation so the menu bar comes along.
        if let window { DockPresence.shared.adopt(window) }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // Activation is cooperative and may be declined; regardless-front
        // keeps the window visible even if the app stays inactive.
        window?.orderFrontRegardless()
    }
}
