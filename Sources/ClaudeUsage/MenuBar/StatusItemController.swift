import AppKit
import SwiftUI
import UsageCore

/// Owns raw NSStatusItems instead of MenuBarExtra. The menu bar's appearance
/// follows wallpaper tinting, not the app's appearance — drawing the title
/// through the button (attributedTitle) keeps it in the system's own
/// appearance/vibrancy pipeline, so it stays legible on any menu bar.
///
/// NSResponder subclass so it can own the buttons' tracking areas: hovering
/// an account's cell shows that account's usage graph popover, iStat-style;
/// clicking a cell focuses that account and toggles the main panel.
///
/// Several accounts (0.96.0): ONE grouped item carries every cell under one
/// provider glyph — and an account that asked for its own item (0.97.0)
/// gets its own `NSStatusItem` (its own `autosaveName`, so ⌘-drag ordering
/// and removal work per account, and removal persists as "don't show this
/// one in the bar"). With one account the model, the item and the drawing
/// are exactly what they were before profiles existed.
@MainActor
final class StatusItemController: NSResponder {
    /// One menu bar item and what was last drawn in it.
    private final class Item {
        /// Nil = the grouped item carrying every cell.
        let profileID: String?
        let statusItem: NSStatusItem
        var model: StatusItemRenderer.Model?
        var rects: [StatusItemRenderer.CellRect] = []
        var visibility: NSKeyValueObservation?

        init(profileID: String?, statusItem: NSStatusItem) {
            self.profileID = profileID
            self.statusItem = statusItem
        }
    }

    private let registry: ProviderRegistry
    private var items: [Item] = []
    private let popover = NSPopover()
    private let hoverPopover = NSPopover()
    private var hoverTask: Task<Void, Never>?
    /// The cell the pointer is over (nil id = the glyph), as of the last
    /// mouse event — what the dwell task reads when it fires.
    private var hoverTarget: (item: Item, profileID: String?)?
    private var outsideClickMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var settingsController: SettingsWindowController?
    private var sessionsController: SessionsWindowController?
    /// The store each hosted window and the panel were built for — a focus
    /// change rebuilds the panel, and re-opening a window rebuilds it.
    private var panelStore: UsageStore
    private var settingsStore: UsageStore?
    private var sessionsStore: UsageStore?
    /// A deferrable provider switch (daily auto re-detection) parked while
    /// the panel is open; applied the moment it closes.
    private var pendingStore: UsageStore?
    private var observationGeneration = 0
    /// Set while items are being torn down and rebuilt, so the visibility
    /// KVO doesn't read our own removals as the user hiding an account.
    private var isRebuildingItems = false
    private var expandsFocus = MenuBarPreferences.expandsFocus()

    /// The account the panel, the windows and the ⋯ menu answer for.
    private var store: UsageStore { registry.focusedStore }

    init(registry: ProviderRegistry) {
        self.registry = registry
        self.panelStore = registry.focusedStore
        super.init()

        popover.contentViewController = makePanelHost()
        popover.behavior = .transient
        popover.delegate = self

        hoverPopover.behavior = .applicationDefined
        hoverPopover.animates = false

        registry.onActiveChange = { [weak self] newStore, deferrable in
            guard let self else { return }
            if deferrable, self.popover.isShown {
                self.pendingStore = newStore
            } else {
                self.adopt(newStore)
            }
        }
        registry.onProfilesChange = { [weak self] in self?.render() }

        // Focus expansion is a plain @AppStorage in Settings; the bar has
        // to notice it change. Cheap: `render` skips an identical model.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.expandsFocus != MenuBarPreferences.expandsFocus() else { return }
                self.expandsFocus = MenuBarPreferences.expandsFocus()
                self.render()
            }
        }

        observeState()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not instantiated from a nib")
    }

    // No deinit: the controller is owned by the app delegate for the whole
    // process lifetime, so its observers never outlive it — and a
    // nonisolated deinit can't touch main-actor state under strict
    // concurrency anyway.

    /// The panel follows the registry's focus on its own, so this is built
    /// once per PROVIDER, not per focus change.
    private func makePanelHost() -> NSHostingController<UsagePanelView> {
        panelStore = registry.focusedStore
        let host = NSHostingController(
            rootView: UsagePanelView(
                registry: registry,
                onOpenSettings: { [weak self] landing in
                    self?.showSettings(pane: .accounts, landing: landing)
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

    /// Re-binds every surface to a new focused store — a focus change or a
    /// provider switch. The registry retires faces (a face's engine is the
    /// host's, its client reader its own) and already installed the new
    /// provider's model catalog before calling here, so the rebuilt views
    /// name models correctly. A mere focus change keeps open windows as
    /// they are: they show the account the person opened them for, and
    /// re-opening them rebuilds for whoever is focused then.
    private func adopt(_ newStore: UsageStore) {
        guard newStore !== panelStore else { return }
        let providerChanged = newStore.provider.id != panelStore.provider.id
        panelStore = newStore
        hoverTask?.cancel()
        if hoverPopover.isShown { hoverPopover.performClose(nil) }
        if providerChanged {
            if popover.isShown { popover.performClose(nil) }
            settingsController?.close()
            settingsController = nil
            settingsStore = nil
            // Close before nil — never dealloc a visible NSWindow.
            sessionsController?.close()
            sessionsController = nil
            sessionsStore = nil
            popover.contentViewController = makePanelHost()
        }
        observeState()
        render()
    }

    /// Tracking is one-shot and re-arms itself; the generation guard keeps
    /// a stale registration (a retired store's last change landing after an
    /// adopt) from re-arming twice.
    private func observeState() {
        observationGeneration += 1
        let generation = observationGeneration
        let observed = registry.focusedStore
        withObservationTracking {
            _ = registry.menuBarCells
            _ = registry.focusedID
            _ = registry.shownProfiles.map(\.id)
            _ = observed.state
            _ = observed.predictions
            _ = observed.serviceStatus
            _ = observed.notices
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.render()
                self.observeState()
            }
        }
    }

    // MARK: - Items

    /// What the bar should show right now — built by the one builder the
    /// Settings preview also draws from, split into one model per item.
    private func render() {
        let model = MenuBarModelBuilder.model(registry: registry, expandsFocus: expandsFocus)
        let height = NSStatusBar.system.thickness
        let itemModels = StatusItemRenderer.itemModels(for: model)
        let wanted = itemModels.map(\.profileID)
        if items.map(\.profileID) != wanted { rebuildItems(for: wanted) }
        for (item, drawn) in zip(items, itemModels) {
            guard item.model != drawn.model else { continue }
            item.model = drawn.model
            item.rects = StatusItemRenderer.cellRects(for: drawn.model, height: height)
            draw(StatusItemRenderer.image(for: drawn.model, height: height), in: item)
        }
    }

    /// Drawn as literal pixels, not attributedTitle: the bars, dots and
    /// badges are filled geometry no attributed string can carry. Fixed
    /// colors keep the image immune to the appearance-context lies a tinted
    /// menu bar tells.
    private func draw(_ image: NSImage, in item: Item) {
        guard let button = item.statusItem.button else { return }
        button.image = image
        button.attributedTitle = NSAttributedString()
        button.imagePosition = .imageOnly
    }

    private func rebuildItems(for wanted: [String?]) {
        isRebuildingItems = true
        defer { isRebuildingItems = false }
        for item in items {
            item.visibility = nil
            NSStatusBar.system.removeStatusItem(item.statusItem)
        }
        items = wanted.map { profileID in
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let item = Item(profileID: profileID, statusItem: statusItem)
            if let profileID {
                // Per-account items are the user's to arrange and to remove;
                // a removal is the same fact as the Settings toggle.
                statusItem.autosaveName = "profile.\(profileID)"
                statusItem.behavior = .removalAllowed
                // The observation's callback is nonisolated: read the new
                // value (a Bool) out of the change, never the item itself.
                item.visibility = statusItem.observe(\.isVisible, options: [.new]) { [weak self] _, change in
                    let visible = change.newValue ?? true
                    Task { @MainActor [weak self] in
                        guard let self, !self.isRebuildingItems, !visible else { return }
                        self.registry.setShowInMenuBar(id: profileID, shown: false)
                    }
                }
            }
            if let button = statusItem.button {
                button.target = self
                button.action = #selector(togglePopover(_:))
                button.addTrackingArea(NSTrackingArea(
                    rect: .zero,
                    options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                    owner: self, userInfo: nil))
            }
            return item
        }
    }

    // MARK: - Hit testing

    /// Which item's button the event came from, and which account's cell
    /// the pointer sits on (nil id = the provider glyph).
    private func target(for event: NSEvent) -> (item: Item, profileID: String?)? {
        guard let item = items.first(where: { $0.statusItem.button?.window === event.window }),
              let button = item.statusItem.button
        else { return nil }
        let point = button.convert(event.locationInWindow, from: nil)
        return (item, cellID(at: point, in: item))
    }

    private func cellID(at point: CGPoint, in item: Item) -> String? {
        guard let button = item.statusItem.button, let image = button.image else { return nil }
        let originX = (button.bounds.width - image.size.width) / 2
        return item.rects.first { $0.rect.offsetBy(dx: originX, dy: 0).contains(point) }?.profileID
    }

    /// The cell's rect in button coordinates — what the hover popover
    /// anchors to, so a card points at the account it belongs to.
    private func anchor(for profileID: String?, in item: Item) -> NSRect {
        guard let button = item.statusItem.button else { return .zero }
        guard let image = button.image,
              let rect = item.rects.first(where: { $0.profileID == profileID })
        else { return button.bounds }
        let originX = (button.bounds.width - image.size.width) / 2
        return rect.rect.offsetBy(dx: originX, dy: 0)
    }

    // MARK: - Hover graph

    override func mouseEntered(with event: NSEvent) {
        guard !popover.isShown else { return }
        hoverTarget = target(for: event)
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled, !self.popover.isShown, !self.hoverPopover.isShown
            else { return }
            self.showHoverPopover()
        }
    }

    /// Moving between cells re-anchors the card immediately — the dwell is
    /// for arriving at the bar, not for crossing it. Close-then-show, with
    /// animation off, so the swap reads as one card moving.
    override func mouseMoved(with event: NSEvent) {
        guard !popover.isShown else { return }
        let previous = hoverTarget?.profileID
        hoverTarget = target(for: event)
        guard hoverPopover.isShown, hoverTarget?.profileID != previous else { return }
        showHoverPopover()
    }

    override func mouseExited(with event: NSEvent) {
        hoverTask?.cancel()
        hoverTarget = nil
        if hoverPopover.isShown { hoverPopover.performClose(nil) }
    }

    /// The hovered account's 5h meter card — the same view as clicking its
    /// row in the panel, so it wakes with the span and frame pickers exactly
    /// as last set (they share the per-account @AppStorage keys). The glyph
    /// (or anywhere outside a cell) shows the focused account's.
    ///
    /// During an incident the panel's own banner rides on top (surface S5):
    /// the same view, so the phrasing and the ticking duration can never
    /// drift between the two popovers.
    private func showHoverPopover() {
        guard let (item, profileID) = hoverTarget, let button = item.statusItem.button else { return }
        let store = profileID.flatMap { registry.store(for: $0) } ?? registry.focusedStore
        guard let meter = store.state.snapshot?.meters.first(where: { $0.rank == 0 })
            ?? store.state.snapshot?.meters.first
        else { return }
        let history = MeterHistoryView(
            meter: meter, samples: store.samples,
            timeline: store.tokenTimeline, pricing: store.pricing,
            prediction: store.predictions[meter.label],
            outcomes: store.windowOutcomes,
            agentName: store.provider.agentName,
            providerID: store.profile.scopeKey,
            accountTitle: accountTitle(for: store),
            outages: store.outages,
            onOpenOutage: { [weak self] span in
                guard let self,
                      let url = self.store.provider.outageDestination(url: span.url)
                else { return }
                NSWorkspace.shared.open(url)
            })
        let incidentCard = store.serviceStatus.flatMap { $0.hasIncident ? $0 : nil }
        let host = NSHostingController(
            rootView: HoverPopoverContent(card: incidentCard, history: history))
        host.sizingOptions = .preferredContentSize
        if hoverPopover.isShown { hoverPopover.performClose(nil) }
        hoverPopover.contentViewController = host
        hoverPopover.show(
            relativeTo: anchor(for: profileID, in: item), of: button, preferredEdge: .minY)
        // The hover popover carries the incident banner, so showing it
        // counts as seeing the ongoing outage — its epilogue will then
        // read "ended" rather than recount the whole incident.
        markNoticesSeen(onlyMenuBarSurfaces: true)
    }

    /// Whose card this is — shown only once more than one account is
    /// metered, so a single-account popover is unchanged.
    private func accountTitle(for store: UsageStore) -> MeterHistoryView.AccountTitle? {
        guard registry.shownProfiles.count > 1 else { return nil }
        return MeterHistoryView.AccountTitle(
            monogram: registry.monogram(for: store.profile),
            label: registry.label(for: store.profile))
    }

    /// Opening the panel marks every pending notice seen; the hover
    /// popover marks only the ones it actually shows (the incident
    /// banner). Seen is not dismissed — the dot stays until a click.
    private func markNoticesSeen(onlyMenuBarSurfaces: Bool) {
        guard let card = store.notices else { return }
        let ids = card.items
            .filter { !$0.seen && (!onlyMenuBarSurfaces || $0.ownsMenuBarSurface) }
            .map(\.id)
        store.markNoticesSeen(ids)
    }

    // MARK: - Main panel

    /// A click on a cell focuses that account and opens the panel on it; a
    /// click on the account already shown closes the panel, the way the one
    /// item has always toggled.
    @objc private func togglePopover(_ sender: Any?) {
        hoverTask?.cancel()
        if hoverPopover.isShown { hoverPopover.performClose(nil) }
        let clicked = NSApp.currentEvent.flatMap { target(for: $0) }
        let clickedID = clicked?.profileID
        if popover.isShown {
            if let clickedID, clickedID != registry.focusedID {
                registry.focus(clickedID)
                return
            }
            popover.performClose(sender)
            return
        }
        if let clickedID, clickedID != registry.focusedID { registry.focus(clickedID) }
        let button = (clicked?.item ?? items.first)?.statusItem.button
        guard let button else { return }
        openPanel(from: button)
    }

    private func openPanel(from button: NSStatusBarButton) {
        let store = registry.focusedStore
        store.scanActivity()
        // A window opening on an aging status card asks for a fresh one
        // (decision D6). Fire-and-forget, and rationed by the feed's own
        // cache window — this is here rather than in the panel's
        // `onAppear` because the hosting view never leaves the hierarchy,
        // so onAppear fires exactly once per app run.
        store.pokeServiceStatus()
        // Focus stays put while the panel is open: an account starting to
        // write must not swap the panel out from under the pointer.
        registry.holdFocus(true)
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        markNoticesSeen(onlyMenuBarSurfaces: false)
        // Cooperative activation usually leaves this app inactive, and a
        // non-key window consumes the first click just to focus itself —
        // SwiftUI tap targets (day drill-down, meter rows) then need two
        // clicks, while NSControl-backed pickers (acceptsFirstMouse)
        // mask the problem. Claiming key at show makes first clicks land.
        popover.contentViewController?.view.window?.makeKey()
        beginDismissMonitoring()
    }

    /// Opens the main panel if it isn't showing — the `--panel` launch
    /// hatch's entry point: synthetic AX clicks on the status item proved
    /// unreliable, and the popover never registers in AXWindows anyway.
    func showPanel() {
        guard !popover.isShown, let button = items.first?.statusItem.button else { return }
        openPanel(from: button)
    }

    /// Opens the settings window; also the `--settings` launch hatch, since
    /// the ⋯ menu itself can't be scripted for verification. `pane` only
    /// matters on the first show (the hatch always launches fresh).
    func showSettings(pane: SettingsSection = .general, landing: SettingsLanding? = nil) {
        if popover.isShown { popover.performClose(nil) }
        let store = registry.focusedStore
        if settingsController == nil || settingsStore !== store {
            settingsController?.close()
            settingsController = SettingsWindowController(store: store, registry: registry)
            settingsStore = store
        }
        settingsController?.show(pane: pane, landing: landing)
    }

    /// Opens the Sessions window; also the `--sessions` launch hatch. A
    /// session id (the panel shortlist's click) lands the sidebar on it.
    func showSessions(selecting sessionID: String? = nil) {
        if popover.isShown { popover.performClose(nil) }
        let store = registry.focusedStore
        if sessionsController == nil || sessionsStore !== store {
            sessionsController?.close()
            sessionsController = SessionsWindowController(store: store, registry: registry)
            sessionsStore = store
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
        // The click's focus is forgotten and activity rules again; a switch
        // decided while the panel was open lands now.
        registry.holdFocus(false)
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
