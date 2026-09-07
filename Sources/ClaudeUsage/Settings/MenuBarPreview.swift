import AppKit
import SwiftUI
import UsageCore

/// The bar as it will draw, live (0.97.0, user-directed: "a full preview
/// all of the time that reacts to changes", the iStat Menus / Bartender
/// way). Fed by `MenuBarModelBuilder` — the SAME model the status item
/// draws — so a change to any account's form, to focus expansion, to
/// focus, or to the numbers themselves shows here the instant the bar
/// shows it. Composition is arranged by dragging: an account's cell moves
/// left or right past its neighbors, and the order lands on release.
struct MenuBarPreview: View {
    let registry: ProviderRegistry
    let expandsFocus: Bool

    /// The order as it stands mid-drag; nil once landed.
    @State private var draftOrder: [String]?

    var body: some View {
        let model = MenuBarModelBuilder.model(
            registry: registry, expandsFocus: expandsFocus, order: draftOrder)
        MenuBarPreviewSurface(
            items: StatusItemRenderer.itemModels(for: model),
            canDrag: registry.barProfiles.count > 1,
            onDrag: { draftOrder = $0 },
            onDrop: { order in
                draftOrder = nil
                if let order { registry.reorder(order) }
            })
            .frame(height: MenuBarPreviewView.barHeight)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Menu bar preview")
    }
}

/// The AppKit surface: a strip of menu-bar ground with every item drawn on
/// it at true size, pointer tracking for the drag.
private struct MenuBarPreviewSurface: NSViewRepresentable {
    let items: [StatusItemRenderer.ItemModel]
    let canDrag: Bool
    let onDrag: ([String]) -> Void
    let onDrop: ([String]?) -> Void

    func makeNSView(context: Context) -> MenuBarPreviewView {
        let view = MenuBarPreviewView()
        view.items = items
        view.canDrag = canDrag
        view.onDrag = onDrag
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ view: MenuBarPreviewView, context: Context) {
        view.onDrag = onDrag
        view.onDrop = onDrop
        view.canDrag = canDrag
        if view.items != items {
            view.items = items
            view.needsDisplay = true
        }
    }
}

@MainActor
final class MenuBarPreviewView: NSView {
    /// The strip's height: the real bar's thickness with a little air.
    static var barHeight: CGFloat { NSStatusBar.system.thickness + 12 }
    /// Between two items, roughly what the real bar leaves.
    private static let itemGap: CGFloat = 14
    private static let inset: CGFloat = 12

    var items: [StatusItemRenderer.ItemModel] = []
    var canDrag = false
    var onDrag: ([String]) -> Void = { _ in }
    var onDrop: ([String]?) -> Void = { _ in }

    /// One cell's rect in view coordinates, with the item image it belongs
    /// to and its rect inside that image.
    private struct Slot {
        let profileID: String?
        let itemIndex: Int
        let rect: NSRect
        let imageRect: NSRect
    }

    private struct Drag {
        let profileID: String
        let grabOffset: CGFloat
        /// The order at the grab — what a release compares against.
        let original: [String]
        var pointerX: CGFloat
        var order: [String]
    }

    private var drag: Drag?
    private var hovered: String?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Layout

    private var thickness: CGFloat { NSStatusBar.system.thickness }

    private func images() -> [NSImage] {
        items.map { StatusItemRenderer.image(for: $0.model, height: thickness) }
    }

    /// Items left to right from the inset, each at its image's width.
    private func layout(_ images: [NSImage]) -> (origins: [CGFloat], slots: [Slot]) {
        var origins: [CGFloat] = []
        var slots: [Slot] = []
        var x = Self.inset
        let y = (bounds.height - thickness) / 2
        for (index, image) in images.enumerated() {
            origins.append(x)
            for rect in StatusItemRenderer.cellRects(for: items[index].model, height: thickness) {
                slots.append(Slot(
                    profileID: rect.profileID, itemIndex: index,
                    rect: rect.rect.offsetBy(dx: x, dy: y), imageRect: rect.rect))
            }
            x += image.size.width + Self.itemGap
        }
        return (origins, slots)
    }

    override var intrinsicContentSize: NSSize {
        let width = images().reduce(0) { $0 + $1.size.width }
            + CGFloat(max(0, items.count - 1)) * Self.itemGap + 2 * Self.inset
        return NSSize(width: width, height: Self.barHeight)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // The ground: a dark strip like a menu bar over a dark wallpaper —
        // the pixels are fixed bright colors and read on it as they do up
        // there.
        let ground = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        NSGradient(
            starting: NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1),
            ending: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1))?
            .draw(in: ground, angle: -90)
        NSColor.white.withAlphaComponent(0.08).setStroke()
        ground.lineWidth = 1
        ground.stroke()

        let images = images()
        let (origins, slots) = layout(images)
        let y = (bounds.height - thickness) / 2

        // A grabbable cell under the pointer wears a faint wash.
        if drag == nil, let hovered, canDrag,
           let slot = slots.first(where: { $0.profileID == hovered }) {
            NSColor.white.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: slot.rect.insetBy(dx: -3, dy: -2), xRadius: 5, yRadius: 5).fill()
        }

        for (index, image) in images.enumerated() {
            let origin = NSPoint(x: origins[index], y: y)
            guard let drag, let slot = slots.first(where: { $0.profileID == drag.profileID && $0.itemIndex == index })
            else {
                image.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
                continue
            }
            // The dragged cell rides with the pointer; the rest of its
            // item stays put with that cell's slice knocked out.
            NSGraphicsContext.current?.saveGraphicsState()
            let keep = NSBezierPath(rect: bounds)
            keep.append(NSBezierPath(rect: slot.rect))
            keep.windingRule = .evenOdd
            keep.addClip()
            image.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.current?.restoreGraphicsState()
            let lifted = NSRect(
                x: drag.pointerX - drag.grabOffset, y: y,
                width: slot.imageRect.width, height: thickness)
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: lifted.insetBy(dx: -3, dy: -2), xRadius: 5, yRadius: 5).fill()
            image.draw(in: lifted, from: slot.imageRect, operation: .sourceOver, fraction: 0.95)
        }
    }

    // MARK: - Pointer

    private func slot(at point: NSPoint) -> Slot? {
        let (_, slots) = layout(images())
        return slots.first { $0.profileID != nil && $0.rect.insetBy(dx: -3, dy: -2).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        guard canDrag, drag == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let over = slot(at: point)?.profileID
        if over != hovered {
            hovered = over
            needsDisplay = true
        }
        if over != nil { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) {
        guard drag == nil else { return }
        hovered = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard canDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let slot = slot(at: point), let id = slot.profileID else { return }
        let order = cellOrder()
        drag = Drag(
            profileID: id, grabOffset: point.x - slot.rect.minX, original: order,
            pointerX: point.x, order: order)
        NSCursor.closedHand.set()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var current = drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        current.pointerX = point.x
        // Past a neighbor's midpoint, the dragged cell takes its place —
        // the order the bar would then have, shown at once.
        let (_, slots) = layout(images())
        let centers = current.order.compactMap { id -> (String, CGFloat)? in
            guard let slot = slots.first(where: { $0.profileID == id }) else { return nil }
            return (id, slot.rect.midX)
        }
        let liftedCenter = point.x - current.grabOffset
            + (slots.first { $0.profileID == current.profileID }?.rect.width ?? 0) / 2
        var order = current.order.filter { $0 != current.profileID }
        let insertAt = centers.filter { $0.0 != current.profileID }
            .firstIndex { liftedCenter < $0.1 } ?? order.count
        order.insert(current.profileID, at: insertAt)
        if order != current.order {
            current.order = order
            drag = current
            onDrag(order)
        } else {
            drag = current
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let current = drag else { return }
        drag = nil
        NSCursor.openHand.set()
        onDrop(current.order != current.original ? current.order : nil)
        needsDisplay = true
    }

    /// The bar's order as drawn: every cell across every item.
    private func cellOrder() -> [String] {
        items.flatMap { $0.model.cells.map(\.profileID) }
    }

    /// The `--snapshot` hatch's eyes: the view drawn into a bitmap without
    /// a window (an NSViewRepresentable renders as a placeholder under
    /// ImageRenderer, so the preview has to draw itself).
    func snapshot(scale: CGFloat = 2) -> NSBitmapImageRep? {
        let size = intrinsicContentSize
        frame = NSRect(origin: .zero, size: NSSize(width: max(size.width, 320), height: size.height))
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        rep.size = bounds.size
        cacheDisplay(in: bounds, to: rep)
        return rep
    }
}

/// Every form an account can take, each drawn with that account's own
/// numbers on a swatch of menu bar — pick by picture, never by name alone
/// (0.97.0, user-directed). `selection` nil = the accounts differ.
struct MenuBarFormPicker: View {
    let cell: StatusItemRenderer.Cell
    let selection: MenuBarForm?
    let onSelect: (MenuBarForm) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(MenuBarForm.allCases) { form in
                FormTile(
                    cell: cell, form: form, selected: form == selection,
                    onSelect: { onSelect(form) })
            }
        }
    }
}

private struct FormTile: View {
    let cell: StatusItemRenderer.Cell
    let form: MenuBarForm
    let selected: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    private var thumbnail: NSImage {
        var sample = cell
        sample.form = form
        return StatusItemRenderer.cellImage(sample, height: NSStatusBar.system.thickness)
    }

    var body: some View {
        let image = thumbnail
        Button(action: onSelect) {
            VStack(spacing: 4) {
                Image(nsImage: image)
                    .frame(minWidth: 44)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                selected ? Color(ProviderStyle.accent) : Color.primary.opacity(hovering ? 0.25 : 0.1),
                                lineWidth: selected ? 1.5 : 1))
                Text(form.title)
                    .font(.caption2.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .help(form.caption)
        .accessibilityLabel(form.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
