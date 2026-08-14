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
    private var outsideClickMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private lazy var settingsController = SettingsWindowController(store: store)

    init(store: UsageStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let host = NSHostingController(
            rootView: UsagePanelView(store: store, onOpenSettings: { [weak self] in
                self?.showSettings()
            }))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self

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
                  let button = self.statusItem.button,
                  let meter = self.store.state.snapshot?.meters.first(where: { $0.rank == 0 })
            else { return }
            // The 5h session meter's full popover — the same view as
            // clicking its row in the panel, so it wakes with the span
            // and frame pickers exactly as last set (they share the
            // per-meter @AppStorage keys).
            let host = NSHostingController(rootView: MeterHistoryView(
                meter: meter, samples: self.store.samples,
                timeline: self.store.tokenTimeline, pricing: self.store.pricing,
                prediction: self.store.predictions[meter.label]))
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
            // Cooperative activation usually leaves this app inactive, and a
            // non-key window consumes the first click just to focus itself —
            // SwiftUI tap targets (day drill-down, meter rows) then need two
            // clicks, while NSControl-backed pickers (acceptsFirstMouse)
            // mask the problem. Claiming key at show makes first clicks land.
            popover.contentViewController?.view.window?.makeKey()
            beginDismissMonitoring()
        }
    }

    /// Opens the main panel if it isn't showing — the `--panel` launch
    /// hatch's entry point: synthetic AX clicks on the status item proved
    /// unreliable, and the popover never registers in AXWindows anyway.
    func showPanel() {
        guard !popover.isShown else { return }
        togglePopover(nil)
    }

    /// Opens the settings window; also the `--settings` launch hatch, since
    /// the ⋯ menu itself can't be scripted for verification. `pane` only
    /// matters on the first show (the hatch always launches fresh).
    func showSettings(pane: SettingsSection = .general) {
        if popover.isShown { popover.performClose(nil) }
        settingsController.show(pane: pane)
    }

    // MARK: - Outside-interaction dismissal

    // .transient alone can't dismiss the panel in an LSUIElement app: it
    // closes on app deactivation, but cooperative activation (macOS 14+)
    // means NSApp.activate() often leaves this app inactive, so clicking
    // another app never produces the deactivation. Global monitors only see
    // events delivered to *other* apps — clicks and scrolls inside the
    // panel never reach them — so any hit means "the user went elsewhere".

    private func beginDismissMonitoring() {
        endDismissMonitoring()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] _ in
            Task { @MainActor in self?.dismissPanel() }
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dismissPanel() }
        }
    }

    private func endDismissMonitoring() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        if let resignActiveObserver { NotificationCenter.default.removeObserver(resignActiveObserver) }
        resignActiveObserver = nil
    }

    private func dismissPanel() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }
}

extension StatusItemController: NSPopoverDelegate {
    // Runs on every close path — toggle, Esc, transient, or our monitors —
    // so the monitors never outlive the panel.
    func popoverDidClose(_ notification: Notification) {
        endDismissMonitoring()
        NotificationCenter.default.post(name: .panelDidClose, object: nil)
    }
}

extension Notification.Name {
    /// Posted whenever the main panel closes, on every close path. The
    /// panel's hosting controller is created once and its view never leaves
    /// the hierarchy on close, so SwiftUI `.onDisappear` never fires in
    /// there — views with per-show state listen for this instead.
    static let panelDidClose = Notification.Name("panelDidClose")
}
