import AppKit
import SwiftUI

/// Owns the one settings window. An LSUIElement app gets no Settings scene
/// wiring for free, so the window is created on first show, kept alive
/// across closes, and explicitly fronted — cooperative activation won't
/// bring a background app's window forward on its own.
@MainActor
final class SettingsWindowController {
    private let store: UsageStore
    private var window: NSWindow?

    init(store: UsageStore) {
        self.store = store
    }

    func show(pane: SettingsSection = .general) {
        if window == nil {
            let host = NSHostingController(
                rootView: SettingsView(store: store, initialSection: pane))
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
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // Activation is cooperative and may be declined; regardless-front
        // keeps the window visible even if the app stays inactive.
        window?.orderFrontRegardless()
    }
}
