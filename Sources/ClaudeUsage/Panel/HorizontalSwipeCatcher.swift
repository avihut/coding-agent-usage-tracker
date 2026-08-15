import AppKit
import SwiftUI

/// Turns a two-finger horizontal trackpad swipe over the modified view into
/// one navigation step — the same action as the ‹ › arrows it accompanies.
///
/// Mechanics: a bounds-scoped LOCAL event monitor, not responder-chain
/// interception. The activity surfaces live inside the panel's vertical
/// ScrollView (and 30D/All carry scroll views of their own), so a plain
/// NSView never reliably sees the wheel events — siblings aren't in the
/// responder chain, and an overlay that hit-tests steals clicks and hovers.
/// The monitor sees every scroll event first, claims only gesture-phased,
/// horizontally-dominant ones inside this view's bounds, and passes
/// everything else through untouched (vertical panel scrolling, the All
/// grid's own horizontal scroller when the cursor is there — its deeper
/// scroll view never lets those reach us anyway).
struct HorizontalSwipeCatcher: NSViewRepresentable {
    /// +1 = fingers moved left, toward LATER content; -1 = fingers moved
    /// right, toward earlier — the pager arrows' sign convention.
    var onStep: (Int) -> Void

    func makeNSView(context: Context) -> SwipeView {
        let view = SwipeView()
        view.onStep = onStep
        return view
    }

    func updateNSView(_ view: SwipeView, context: Context) {
        // The closure captures per-render state (the drilled day, its rows);
        // refresh it so a swipe never fires against a stale capture.
        view.onStep = onStep
    }

    final class SwipeView: NSView {
        var onStep: ((Int) -> Void)?

        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var fired = false
        /// One step needs a deliberate swipe, not a grazed touch.
        private static let threshold: CGFloat = 55

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window == nil ? removeMonitor() : installMonitor()
        }

        deinit {
            removeMonitor()
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                guard let self else { return event }
                return self.claim(event) ? nil : event
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// True when the event was ours — consumed so the panel's scroll
        /// view can't rubber-band sideways under the swipe.
        fileprivate func claim(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            guard bounds.contains(convert(event.locationInWindow, from: nil))
            else { return false }
            // Momentum tails and legacy mouse wheels never step; only the
            // live gesture does.
            guard event.momentumPhase == [] else { return false }
            guard event.phase == .began || event.phase == .changed
                    || event.phase == .ended || event.phase == .cancelled
            else { return false }
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            else { return false }

            switch event.phase {
            case .began:
                accumulated = 0
                fired = false
            case .changed:
                accumulated += event.scrollingDeltaX
                if !fired, abs(accumulated) >= Self.threshold {
                    fired = true
                    // scrollingDeltaX honors the user's natural-scrolling
                    // preference: negative = fingers left = later content.
                    onStep?(accumulated < 0 ? 1 : -1)
                }
            default:
                accumulated = 0
            }
            return true
        }
    }
}

/// The swipe catcher's continuous sibling: streams horizontal pan deltas —
/// live gesture AND momentum tail, so panning glides — to the handler along
/// with the view's width, for point→data-unit conversion. Same bounds-scoped
/// local-monitor mechanics, same reasons.
struct HorizontalPanCatcher: NSViewRepresentable {
    /// The catcher goes inert (events pass through) while disabled — the
    /// unzoomed chart has nothing to pan.
    var enabled: Bool
    /// (scrollingDeltaX in points, view width in points).
    var onPan: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> PanView {
        let view = PanView()
        view.enabled = enabled
        view.onPan = onPan
        return view
    }

    func updateNSView(_ view: PanView, context: Context) {
        view.enabled = enabled
        view.onPan = onPan
    }

    final class PanView: NSView {
        var enabled = false
        var onPan: ((CGFloat, CGFloat) -> Void)?

        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window == nil ? removeMonitor() : installMonitor()
        }

        deinit {
            removeMonitor()
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                guard let self else { return event }
                return self.claim(event) ? nil : event
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func claim(_ event: NSEvent) -> Bool {
            guard enabled, let window, event.window === window else { return false }
            guard bounds.contains(convert(event.locationInWindow, from: nil))
            else { return false }
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            else { return false }
            guard event.scrollingDeltaX != 0 else { return true }
            onPan?(event.scrollingDeltaX, bounds.width)
            return true
        }
    }
}
