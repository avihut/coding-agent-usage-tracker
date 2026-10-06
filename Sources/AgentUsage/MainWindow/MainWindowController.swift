import AppKit
import Observation
import SwiftUI
import UsageCore

/// A request from outside the window (a hatch, a notice's click-through) to
/// land it on one page.
@MainActor
@Observable
final class MainWindowNavigator {
    /// `MainWindowView.homeSelection` or a `ProfileKey`.
    var requested: String?
}

/// Owns the main window (user-directed 2026-10-06: "the
/// popover, given room"). The Settings contract exactly: created on first
/// show, kept alive across closes, explicitly fronted — cooperative
/// activation won't bring a background app's window forward on its own —
/// and enrolled with DockPresence so the app is in the Dock while it is
/// open. Bound to the registry, never to one store: it shows every account,
/// and a focus change moves nothing here.
@MainActor
final class MainWindowController {
    private let registry: ProviderRegistry
    private let navigator = MainWindowNavigator()
    private let onOpenSessions: (_ profileKey: String?, _ sessionID: String?) -> Void
    private let onOpenSettings: () -> Void
    private var window: NSWindow?
    /// The page's name as last reported — it can arrive while the window
    /// is still being built, before `window` is set.
    private var pageTitle: String?

    init(
        registry: ProviderRegistry,
        onOpenSessions: @escaping (_ profileKey: String?, _ sessionID: String?) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.registry = registry
        self.onOpenSessions = onOpenSessions
        self.onOpenSettings = onOpenSettings
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Fronts the window, building it on first use; `selecting` lands it on
    /// Home or one account.
    func show(selecting selection: String? = nil) {
        if let selection { navigator.requested = selection }
        if window == nil {
            let host = NSHostingController(
                rootView: MainWindowView(
                    registry: registry, navigator: navigator,
                    onOpenSessions: onOpenSessions, onOpenSettings: onOpenSettings,
                    onTitle: { [weak self] title in
                        self?.pageTitle = title
                        self?.window?.title = title
                    }))
            // The SwiftUI tree's title, subtitle and toolbar become the
            // window's own (unified toolbar over a full-height sidebar).
            host.sceneBridgingOptions = [.title, .toolbars]
            // The content's minimum only: the window is the person's to size,
            // never pinned to what the page would ideally take.
            host.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: host)
            window.title = pageTitle ?? AppIdentity.displayName
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.tabbingMode = .disallowed
            window.setContentSize(NSSize(width: 1100, height: 720))
            window.contentMinSize = NSSize(width: 900, height: 600)
            window.isReleasedWhenClosed = false
            window.center()
            // After centering so a remembered size/position wins over it.
            window.setFrameAutosaveName("AgentUsageMain")
            self.window = window
        }
        for store in registry.shownProfiles.compactMap({ registry.store(for: $0.key) }) {
            // A window opening on an aging status card asks for a fresh one
            // (the panel's rule, decision D6) — rationed by the feed's cache.
            store.pokeServiceStatus()
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
