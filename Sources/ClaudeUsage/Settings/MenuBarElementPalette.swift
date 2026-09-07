import AppKit
import SwiftUI
import UsageCore

/// What can be added to the bar (0.98.0, user-directed): a tile per
/// element, pictured with the account's own numbers, dragged onto the
/// preview or clicked into place. The one element so far is "Runs out",
/// and its condition is said right here, beside the tile — an element
/// that draws nothing on a quiet day has to announce that where it is
/// placed, or a drop looks like it failed.
struct MenuBarElementPalette: View {
    let registry: ProviderRegistry
    /// The account the tile is pictured with (nil = the focused one).
    let profile: Profile?
    /// The arrangement being edited — bar-wide or one account's.
    let elements: [MenuBarElement]
    let onChange: ([MenuBarElement]) -> Void

    private var scope: RunsOutScope? { MenuBarLayout.runsOutScope(in: elements) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RunsOutTile(
                cell: MenuBarModelBuilder.runsOutSample(
                    for: profile, registry: registry, scope: scope ?? .earliest),
                profileID: profile?.id,
                placed: scope != nil,
                onAdd: { onChange(MenuBarLayout.settingRunsOut(.earliest, in: elements)) })
                .fixedSize()
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Runs out")
                        .font(.callout.weight(.semibold))
                    if scope != nil {
                        Text("In the bar")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }
                Text(
                    "The expected time until a limit is reached. Appears only while a limit is"
                        + " forecast to run out before it resets — or, once one is spent, counts"
                        + " down to its reset. On a quiet day it draws nothing at all.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let scope {
                    HStack(spacing: 10) {
                        Picker("Shows", selection: Binding(
                            get: { scope },
                            set: { onChange(MenuBarLayout.settingRunsOut($0, in: elements)) })
                        ) {
                            ForEach(RunsOutScope.allCases) { candidate in
                                Text(candidate.title).tag(candidate)
                            }
                        }
                        .fixedSize()
                        .help(scope.caption)
                        Button("Remove") { onChange(MenuBarLayout.removingRunsOut(from: elements)) }
                            .help("Or drag it off the preview")
                    }
                    .controlSize(.small)
                } else {
                    Text("Drag it onto the preview, or click the tile to add it after the meters.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// The tile: the element drawn as it would look with the session limit
/// half an hour out, on a swatch of bar. It is an AppKit DRAG SOURCE — a
/// real `NSDraggingSession` carrying the element's token (SwiftUI's
/// `.onDrag` on a Button never started one, and the preview is an AppKit
/// drop target: v0.98.1, user-reported "nothing happened"); a click adds
/// the element in the default place.
private struct RunsOutTile: View {
    let cell: StatusItemRenderer.Cell
    /// The account the tile belongs to, so its drop lands on that
    /// account's cell wherever the pointer lets go.
    let profileID: String?
    let placed: Bool
    let onAdd: () -> Void

    @State private var hovering = false

    private var thumbnail: NSImage {
        StatusItemRenderer.elementImage(
            MenuBarLayout.runsOutScope(in: cell.elements).map { .runsOut($0) } ?? .runsOut(.earliest),
            in: cell, height: NSStatusBar.system.thickness)
    }

    var body: some View {
        let image = thumbnail
        VStack(spacing: 4) {
            MenuBarSwatch(image: image, selected: placed, hovering: hovering)
                .overlay(
                    ElementDragSource(
                        element: .runsOut(.earliest), profileID: profileID, image: image,
                        onClick: { if !placed { onAdd() } },
                        onHover: { hovering = $0 }))
            Text(placed ? "Added" : "Add")
                .font(.caption2.weight(placed ? .semibold : .regular))
                .foregroundStyle(placed ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .pointerStyle(placed ? .grabIdle : .link)
        .help("Runs out — drag onto the preview")
        .accessibilityLabel("Runs out")
    }
}

/// A transparent view over the swatch that turns a press-and-move into an
/// AppKit drag of the element and a plain click into `onClick`.
private struct ElementDragSource: NSViewRepresentable {
    let element: MenuBarElement
    let profileID: String?
    let image: NSImage
    let onClick: () -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> ElementDragSourceView {
        let view = ElementDragSourceView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: ElementDragSourceView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: ElementDragSourceView) {
        view.element = element
        view.profileID = profileID
        view.image = image
        view.onClick = onClick
        view.onHover = onHover
    }
}

@MainActor
final class ElementDragSourceView: NSView, NSDraggingSource {
    var element: MenuBarElement = .runsOut(.earliest)
    var profileID: String?
    var image = NSImage()
    var onClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }

    private var pressedAt: NSPoint?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) {
        pressedAt = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressedAt else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressedAt.x, point.y - pressedAt.y) > 4 else { return }
        self.pressedAt = nil
        let item = NSPasteboardItem()
        item.setString(element.token, forType: MenuBarElementDrag.pasteboardType)
        item.setString(element.token, forType: .string)
        if let profileID { item.setString(profileID, forType: MenuBarElementDrag.profileType) }
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        // The swatch as it looks here rides under the pointer, so what is
        // dragged is what will land.
        dragItem.setDraggingFrame(bounds, contents: dragImage())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if pressedAt != nil { onClick() }
        pressedAt = nil
    }

    private func dragImage() -> NSImage {
        let size = bounds.size
        let element = image
        return NSImage(size: size, flipped: false) { rect in
            NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 0.95).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            element.draw(
                at: NSPoint(x: (rect.width - element.size.width) / 2, y: (rect.height - element.size.height) / 2),
                from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }
}
