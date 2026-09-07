import AppKit
import SwiftUI

/// Owns the one settings window. An LSUIElement app gets no Settings scene
/// wiring for free, so the window is created on first show, kept alive
/// across closes, and explicitly fronted — cooperative activation won't
/// bring a background app's window forward on its own.
@MainActor
final class SettingsWindowController {
    private let registry: ProviderRegistry
    private let navigator = SettingsNavigator()
    private var window: NSWindow?

    init(store: UsageStore, registry: ProviderRegistry) {
        self.registry = registry
        _ = store
    }

    /// Closes and drops the window. Called when the registry retires this
    /// controller's store — releasing a visible NSWindow out from under
    /// AppKit is not an option, so the switch closes it first.
    func close() {
        window?.close()
        window = nil
    }

    func show(pane: SettingsSection = .general, landing: SettingsLanding? = nil) {
        navigator.request(section: pane, landing: landing)
        if window == nil {
            let host = NSHostingController(
                rootView: SettingsView(
                    registry: registry, navigator: navigator, initialSection: pane))
            let window = NSWindow(contentViewController: host)
            window.title = "Claude Usage Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 820, height: 700))
            window.isReleasedWhenClosed = false
            window.center()
            // After centering so a remembered size/position wins over it.
            window.setFrameAutosaveName("ClaudeUsageSettings")
            self.window = window
        }
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
