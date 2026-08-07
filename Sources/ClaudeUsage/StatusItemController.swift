import AppKit
import SwiftUI
import UsageCore

/// Owns a raw NSStatusItem instead of MenuBarExtra. The menu bar's appearance
/// follows wallpaper tinting, not the app's appearance — drawing the title
/// through the button (attributedTitle) keeps it in the system's own
/// appearance/vibrancy pipeline, so it stays legible on any menu bar.
///
/// NSResponder subclass so it can own the button's tracking area: hovering
/// the item shows the usage graph popover, iStat-style; clicking toggles the
/// main panel.
@MainActor
final class StatusItemController: NSResponder {
    private let store: UsageStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let hoverPopover = NSPopover()
    private var hoverTask: Task<Void, Never>?

    init(store: UsageStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let host = NSHostingController(rootView: UsagePanelView(store: store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        hoverPopover.behavior = .applicationDefined
        hoverPopover.animates = false

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil))
        }

        observeState()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not instantiated from a nib")
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

    // MARK: - Hover graph

    override func mouseEntered(with event: NSEvent) {
        guard !popover.isShown else { return }
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled,
                  !self.popover.isShown, !self.hoverPopover.isShown,
                  let button = self.statusItem.button
            else { return }
            let host = NSHostingController(rootView: HoverGraphView(samples: self.store.samples))
            host.sizingOptions = .preferredContentSize
            self.hoverPopover.contentViewController = host
            self.hoverPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverTask?.cancel()
        if hoverPopover.isShown { hoverPopover.performClose(nil) }
    }

    // MARK: - Main panel

    @objc private func togglePopover(_ sender: Any?) {
        hoverTask?.cancel()
        if hoverPopover.isShown { hoverPopover.performClose(nil) }
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            store.scanActivity()
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
