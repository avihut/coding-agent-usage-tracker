import AppKit
import SwiftUI
import UsageCore

/// Owns a raw NSStatusItem instead of MenuBarExtra. The menu bar's appearance
/// follows wallpaper tinting, not the app's appearance — MenuBarExtra
/// rasterizes its label in the app's appearance and produced dark-on-dark
/// text. Setting the image on the status button lets AppKit draw it inside
/// the button's own appearance context, where the dynamic system colors
/// resolve correctly.
@MainActor
final class StatusItemController: NSObject {
    private let store: UsageStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var appearanceObservation: NSKeyValueObservation?

    init(store: UsageStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let host = NSHostingController(rootView: UsagePanelView(store: store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            // Theme flips and wallpaper-tint changes re-resolve the colors.
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.render() }
            }
        }

        observeState()
        render()
    }

    private func observeState() {
        withObservationTracking {
            _ = store.state
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.render()
                self.observeState()
            }
        }
    }

    private func render() {
        statusItem.button?.attributedTitle = StatusItemRenderer.attributedText(
            for: StatusItemRenderer.model(for: store.state))
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
