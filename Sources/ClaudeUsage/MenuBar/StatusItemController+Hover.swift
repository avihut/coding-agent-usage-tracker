import AppKit
import SwiftUI
import UsageCore

/// Where the pointer is, and what it opens: which harness's mark or which
/// account's cell a point lands on, and the meter card that appears after a
/// dwell. Split from `StatusItemController.swift` at the house rule when
/// harness regions landed — the type above owns the items, the drawing and
/// the panel; this half owns the pointer.
///
/// A region is (cell, harness): a click or hover on a harness's MARK answers
/// for that harness's own focused account, never the bar's (0.101.0 — before
/// several harnesses there was only one mark, so nil meant "the glyph" and
/// nothing more).
@MainActor
extension StatusItemController {
    // MARK: - Hit testing

    /// Which item's button the event came from, and which account's cell
    /// the pointer sits on (nil id = the provider glyph).
    func target(for event: NSEvent) -> (item: Item, profileID: String?, harnessID: String)? {
        guard let item = items.first(where: { $0.statusItem.button?.window === event.window }),
              let button = item.statusItem.button
        else { return nil }
        let point = button.convert(pointerLocation(for: event, in: button), from: nil)
        let region = self.region(at: point, in: item)
        return (item, region?.profileID, region?.harnessID ?? registry.focusedHarnessID)
    }

    /// Where the pointer really is, in the button's window. A CLICK's event
    /// can't be trusted for this (0.101.0, user-reported "clicking an account
    /// doesn't select it", found with `--click-log`): on this macOS the
    /// mouse-up a status item's action fires on carries the button's exact
    /// CENTRE as its location, whatever was clicked, so every click resolved
    /// to the cell in the middle of the bar. The pointer's own position is
    /// the truth for a click; a move or an enter event reports it honestly.
    func pointerLocation(for event: NSEvent, in button: NSStatusBarButton) -> NSPoint {
        switch event.type {
        case .leftMouseUp, .leftMouseDown, .rightMouseUp, .rightMouseDown:
            guard let window = button.window else { return event.locationInWindow }
            return window.convertPoint(fromScreen: NSEvent.mouseLocation)
        default:
            return event.locationInWindow
        }
    }

    func region(at point: CGPoint, in item: Item) -> StatusItemRenderer.CellRect? {
        guard let button = item.statusItem.button, let image = button.image else { return nil }
        let originX = (button.bounds.width - image.size.width) / 2
        return item.rects.first { $0.rect.offsetBy(dx: originX, dy: 0).contains(point) }
    }

    /// The account a pointer landed on: the cell it is over, or — on a
    /// harness's own mark — that harness's focused account, never the bar's
    /// (0.101.0: the mark used to be the only one there was).
    func account(_ profileID: String?, inHarness harnessID: String) -> String? {
        if let profileID { return profileID }
        let mine = registry.shownProfiles.filter { $0.providerID == harnessID }
        if let focused = mine.first(where: { $0.key == registry.focusedID }) { return focused.key }
        return mine.first?.key
    }

    /// The cell's rect in button coordinates — what the hover popover
    /// anchors to, so a card points at the account it belongs to.
    func anchor(for profileID: String?, harnessID: String, in item: Item) -> NSRect {
        guard let button = item.statusItem.button else { return .zero }
        guard let image = button.image,
              let rect = item.rects.first(where: {
                  $0.profileID == profileID && $0.harnessID == harnessID
              })
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
        // The pair, not the cell alone: moving from one harness's mark to
        // another's keeps a nil cell id, and the card must still re-anchor.
        let previous = hoverTarget.map { ($0.profileID, $0.harnessID) }
        hoverTarget = target(for: event)
        let current = hoverTarget.map { ($0.profileID, $0.harnessID) }
        guard hoverPopover.isShown, current?.0 != previous?.0 || current?.1 != previous?.1
        else { return }
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
    func showHoverPopover() {
        guard let (item, profileID, harnessID) = hoverTarget, let button = item.statusItem.button
        else { return }
        let store = account(profileID, inHarness: harnessID)
            .flatMap { registry.store(for: $0) } ?? registry.focusedStore
        guard let meter = store.state.snapshot?.meters.first(where: { $0.rank == 0 })
            ?? store.state.snapshot?.meters.first
        else { return }
        let history = MeterHistoryView(
            meter: meter, samples: store.samples,
            timeline: store.tokenTimeline, pricing: store.pricing,
            prediction: store.predictions[meter.label],
            overshoot: store.forecastOvershoots[meter.label],
            outcomes: store.windowOutcomes,
            agentName: store.provider.agentName,
            providerID: store.profile.scopeKey,
            // The hover card is its own hosting controller — the harness has
            // to be handed to it, and it is the HOVERED account's.
            style: store.style,
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
            relativeTo: anchor(for: profileID, harnessID: harnessID, in: item), of: button,
            preferredEdge: .minY)
        // The hover popover carries the incident banner, so showing it
        // counts as seeing the ongoing outage — its epilogue will then
        // read "ended" rather than recount the whole incident.
        markNoticesSeen(onlyMenuBarSurfaces: true)
    }

    /// Whose card this is — shown only once more than one account is
    /// metered, so a single-account popover is unchanged.
    func accountTitle(for store: UsageStore) -> MeterHistoryView.AccountTitle? {
        guard registry.shownProfiles.count > 1 else { return nil }
        return MeterHistoryView.AccountTitle(
            monogram: registry.monogram(for: store.profile),
            label: registry.label(for: store.profile))
    }

    /// Opening the panel marks every pending notice seen; the hover
    /// popover marks only the ones it actually shows (the incident
    /// banner). Seen is not dismissed — the dot stays until a click.
    func markNoticesSeen(onlyMenuBarSurfaces: Bool) {
        // Opening the panel shows every shown harness's notices, so it marks
        // every shown harness's notices seen (0.101.0).
        guard let card = registry.pendingNotices else { return }
        let ids = card.items
            .filter { !$0.seen && (!onlyMenuBarSurfaces || $0.ownsMenuBarSurface) }
            .map(\.id)
        store.markNoticesSeen(ids)
    }
}
