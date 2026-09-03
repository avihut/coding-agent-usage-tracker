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
    private let registry: ProviderRegistry
    private var store: UsageStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let hoverPopover = NSPopover()
    private var hoverTask: Task<Void, Never>?
    private var outsideClickMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var settingsController: SettingsWindowController?
    private var sessionsController: SessionsWindowController?
    /// A deferrable provider switch (daily auto re-detection) parked while
    /// the panel is open; applied the moment it closes.
    private var pendingStore: UsageStore?

    init(registry: ProviderRegistry) {
        self.registry = registry
        self.store = registry.activeStore
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.contentViewController = makePanelHost()
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

        registry.onActiveChange = { [weak self] newStore, deferrable in
            guard let self else { return }
            if deferrable, self.popover.isShown {
                self.pendingStore = newStore
            } else {
                self.adopt(newStore)
            }
        }

        observeState()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not instantiated from a nib")
    }

    private func makePanelHost() -> NSHostingController<UsagePanelView> {
        let host = NSHostingController(
            rootView: UsagePanelView(
                store: store, registry: registry,
                onOpenSettings: { [weak self] in
                    self?.showSettings()
                },
                onOpenSessions: { [weak self] in
                    self?.showSessions()
                },
                onOpenSession: { [weak self] id in
                    self?.showSessions(selecting: id)
                }))
        host.sizingOptions = .preferredContentSize
        return host
    }

    /// Re-binds every surface to a new active store and retires the old
    /// one. The registry already installed the new provider's model catalog
    /// before calling here, so the rebuilt views name models correctly.
    private func adopt(_ newStore: UsageStore) {
        guard newStore !== store else { return }
        hoverTask?.cancel()
        if hoverPopover.isShown { hoverPopover.performClose(nil) }
        if popover.isShown { popover.performClose(nil) }
        settingsController?.close()
        settingsController = nil
        // Close before nil — never dealloc a visible NSWindow — and both
        // before the outgoing store shuts down under the window's views.
        sessionsController?.close()
        sessionsController = nil
        let outgoing = store
        store = newStore
        outgoing.shutdown()
        popover.contentViewController = makePanelHost()
        observeState()
        render()
    }

    private func observeState() {
        // Tracking is one-shot and re-arms itself; the identity guard keeps
        // a stale registration (the retired store's last change landing
        // after an adopt) from re-arming against the new store twice.
        let observed = store
        withObservationTracking {
            _ = observed.state
            _ = observed.predictions
            _ = observed.serviceStatus
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.store === observed else { return }
                self.render()
                self.observeState()
            }
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let model = StatusItemRenderer.model(
            for: store.state, predictions: store.predictions,
            glyph: store.provider.menuBarGlyph,
            serviceStatus: store.serviceStatus)
        // Drawn as literal pixels, not attributedTitle: the dot and badge
        // are filled geometry no attributed string can carry. Fixed colors
        // keep the image immune to the appearance-context lies a tinted
        // menu bar tells.
        button.image = StatusItemRenderer.image(
            for: model, height: NSStatusBar.system.thickness)
        button.attributedTitle = NSAttributedString()
        button.imagePosition = .imageOnly
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
            //
            // During an incident the panel's own banner rides on top
            // (surface S5): the same view, so the phrasing and the ticking
            // duration can never drift between the two popovers.
            let history = MeterHistoryView(
                meter: meter, samples: self.store.samples,
                timeline: self.store.tokenTimeline, pricing: self.store.pricing,
                prediction: self.store.predictions[meter.label],
                outcomes: self.store.windowOutcomes,
                agentName: self.store.provider.agentName,
                providerID: self.store.provider.id)
            let incidentCard = self.store.serviceStatus.flatMap {
                $0.hasIncident ? $0 : nil
            }
            let host = NSHostingController(
                rootView: HoverPopoverContent(card: incidentCard, history: history))
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
            // A window opening on an aging status card asks for a fresh one
            // (decision D6). Fire-and-forget, and rationed by the feed's own
            // cache window — this is here rather than in the panel's
            // `onAppear` because the hosting view never leaves the hierarchy,
            // so onAppear fires exactly once per app run.
            store.pokeServiceStatus()
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
        if settingsController == nil {
            settingsController = SettingsWindowController(store: store, registry: registry)
        }
        settingsController?.show(pane: pane)
    }

    /// Opens the Sessions window; also the `--sessions` launch hatch. A
    /// session id (the panel shortlist's click) lands the sidebar on it.
    func showSessions(selecting sessionID: String? = nil) {
        if popover.isShown { popover.performClose(nil) }
        if sessionsController == nil {
            sessionsController = SessionsWindowController(store: store, registry: registry)
        }
        sessionsController?.show(selecting: sessionID)
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
        if let pendingStore {
            self.pendingStore = nil
            adopt(pendingStore)
        }
    }
}

/// The hover popover's content: the meter history, with the incident banner
/// stacked above it while something is wrong (surface S5). A tiny wrapper
/// type rather than an inline `AnyView` so the hosting controller keeps a
/// concrete root view and its `preferredContentSize` sizing still works.
private struct HoverPopoverContent: View {
    let card: ServiceStatusCard?
    let history: MeterHistoryView

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let card {
                ServiceStatusBanner(card: card, compact: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
            }
            history
        }
    }
}

extension Notification.Name {
    /// Posted whenever the main panel closes, on every close path. The
    /// panel's hosting controller is created once and its view never leaves
    /// the hierarchy on close, so SwiftUI `.onDisappear` never fires in
    /// there — views with per-show state listen for this instead.
    static let panelDidClose = Notification.Name("panelDidClose")
}
