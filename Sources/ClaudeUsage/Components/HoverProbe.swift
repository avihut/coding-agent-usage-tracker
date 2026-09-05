import AppKit
import SwiftUI

/// Hover tracking that survives a popover. SwiftUI's `.onHover` on a row
/// inside the panel goes quiet once a click on that row presents a child
/// popover: the exit fires, and no enter follows until the panel itself
/// closes and reopens — the notice row's × vanished exactly that way
/// (user-reported, v0.93.4). This probe owns its own NSTrackingArea instead:
/// `.activeAlways` (key-window state never gates it — the panel window is
/// rarely key in an LSUIElement app anyway), `.mouseMoved` so a cursor
/// already resting on the view re-asserts hover on its next pixel, and a
/// re-read of the live pointer position whenever the window's key state
/// flips or the tracking areas rebuild. `hitTest` returns nil, so it never
/// takes a click or a hover from the SwiftUI content it sits behind — use
/// it as a `.background`.
struct HoverProbe: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var inside = false
        private var area: NSTrackingArea?

        override init(frame: NSRect) {
            super.init(frame: frame)
            // Selector observers unregister themselves on dealloc — no
            // deinit bookkeeping, and nothing for a nonisolated deinit to
            // touch.
            let center = NotificationCenter.default
            center.addObserver(
                self, selector: #selector(windowKeyStateChanged(_:)),
                name: NSWindow.didBecomeKeyNotification, object: nil)
            center.addObserver(
                self, selector: #selector(windowKeyStateChanged(_:)),
                name: NSWindow.didResignKeyNotification, object: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("not instantiated from a nib")
        }

        /// Never the hit view: clicks and SwiftUI's own hover pass straight
        /// through to the content this probe backs.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let fresh = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil)
            addTrackingArea(fresh)
            area = fresh
            reassessLater()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reassessLater()
        }

        override func mouseEntered(with event: NSEvent) { set(true) }
        override func mouseMoved(with event: NSEvent) { set(true) }
        override func mouseExited(with event: NSEvent) { set(false) }

        @objc private func windowKeyStateChanged(_ note: Notification) {
            // Any window's flip may be the child popover coming or going
            // over us; the pointer check is cheap and decides for itself.
            reassessLater()
        }

        /// Off the current turn: these fire from inside layout and SwiftUI
        /// update passes, where writing view state is a warning.
        private func reassessLater() {
            DispatchQueue.main.async { [weak self] in self?.reassess() }
        }

        private func reassess() {
            guard let window else {
                set(false)
                return
            }
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            set(bounds.contains(point))
        }

        private func set(_ value: Bool) {
            guard value != inside else { return }
            inside = value
            onChange?(value)
        }
    }
}
