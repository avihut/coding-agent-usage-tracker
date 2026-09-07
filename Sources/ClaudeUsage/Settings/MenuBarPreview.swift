import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UsageCore

/// The bar as it will draw, live (0.97.0, user-directed: "a full preview
/// all of the time that reacts to changes", the iStat Menus / Bartender
/// way). Fed by `MenuBarModelBuilder` — the SAME model the status item
/// draws — so a change to any account's form, to focus expansion, to
/// focus, or to the numbers themselves shows here the instant the bar
/// shows it. Composition is arranged by dragging: an account's cell moves
/// left or right past its neighbors, and the order lands on release.
///
/// Elements (0.98.0, user-directed): the palette's tiles drop ONTO the bar
/// — before or after an account's meters, by which side of them the
/// pointer lands on — and a placed element drags across its meters or off
/// the strip to be removed. An element with nothing to say right now
/// draws as a dashed ghost HERE ONLY, so the drop never looks like it
/// failed; `simulate` dresses every cell as if a limit were running out,
/// the one way to see the real rendering on a quiet day.
struct MenuBarPreview: View {
    let registry: ProviderRegistry
    let prefs: MenuBarPreferences.Values
    var simulate = false
    var ghosts = true

    /// The order as it stands mid-drag; nil once landed.
    @State private var draftOrder: [String]?
    /// One account's element list as it stands mid-drag (nil id = every
    /// account, the uniform arrangement); nil once landed.
    @State private var draftElements: (id: String?, elements: [MenuBarElement])?

    var body: some View {
        let model = MenuBarModelBuilder.model(
            registry: registry, prefs: prefs, order: draftOrder, elements: draftElements,
            simulate: simulate, ghosts: ghosts)
        MenuBarPreviewSurface(
            items: StatusItemRenderer.itemModels(for: model),
            canDrag: registry.barProfiles.count > 1,
            onDrag: { draftOrder = $0 },
            onDrop: { order in
                draftOrder = nil
                if let order { registry.reorder(order) }
            },
            onElementDrag: { id, elements in
                draftElements = (prefs.uniform ? nil : id, elements)
            },
            onElementDrop: { id, elements in
                draftElements = nil
                if let elements { commit(elements, for: id) }
            },
            onPlaceElement: { id, element, beforeMeters in
                commit(
                    MenuBarLayout.placing(element, beforeMeters: beforeMeters, in: current(for: id)),
                    for: id)
            })
            .frame(height: MenuBarPreviewView.barHeight)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Menu bar preview")
    }

    private func current(for id: String?) -> [MenuBarElement] {
        prefs.elements(for: registry.profiles.first { $0.id == id } ?? registry.focusedProfile)
    }

    /// Where an arrangement lands: the bar-wide list while one arrangement
    /// serves every account, else the account's own record.
    private func commit(_ elements: [MenuBarElement], for id: String?) {
        if prefs.uniform {
            MenuBarPreferences.setUniformElements(elements)
        } else if let id = id ?? registry.focusedProfile?.id {
            registry.setMenuBarElements(id: id, elements: elements)
        }
    }
}

/// The AppKit surface: a strip of menu-bar ground with every item drawn on
/// it at true size, pointer tracking for the drags, a drop target for the
/// palette.
private struct MenuBarPreviewSurface: NSViewRepresentable {
    let items: [StatusItemRenderer.ItemModel]
    let canDrag: Bool
    let onDrag: ([String]) -> Void
    let onDrop: ([String]?) -> Void
    let onElementDrag: (String, [MenuBarElement]) -> Void
    let onElementDrop: (String, [MenuBarElement]?) -> Void
    let onPlaceElement: (String?, MenuBarElement, Bool) -> Void

    func makeNSView(context: Context) -> MenuBarPreviewView {
        let view = MenuBarPreviewView()
        view.items = items
        view.canDrag = canDrag
        apply(to: view)
        return view
    }

    func updateNSView(_ view: MenuBarPreviewView, context: Context) {
        apply(to: view)
        view.canDrag = canDrag
        if view.items != items {
            view.items = items
            view.needsDisplay = true
        }
    }

    private func apply(to view: MenuBarPreviewView) {
        view.onDrag = onDrag
        view.onDrop = onDrop
        view.onElementDrag = onElementDrag
        view.onElementDrop = onElementDrop
        view.onPlaceElement = onPlaceElement
    }
}

/// The palette's drag payload: the element's token under the app's own
/// pasteboard type, and again as plain text so a receiver that only
/// speaks text still gets the token.
enum MenuBarElementDrag {
    static let typeIdentifier = "com.avihu.ClaudeUsage.menubar-element"
    static let pasteboardType = NSPasteboard.PasteboardType(typeIdentifier)

    static func itemProvider(for element: MenuBarElement) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(element.token.utf8)
        for identifier in [typeIdentifier, UTType.utf8PlainText.identifier] {
            provider.registerDataRepresentation(forTypeIdentifier: identifier, visibility: .ownProcess) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }

    /// The element a pasteboard carries, if it carries one of ours.
    static func element(on pasteboard: NSPasteboard) -> MenuBarElement? {
        for type in [pasteboardType, .string] {
            if let data = pasteboard.data(forType: type),
               let element = MenuBarElement(token: String(decoding: data, as: UTF8.self)) {
                return element
            }
            if let string = pasteboard.string(forType: type), let element = MenuBarElement(token: string) {
                return element
            }
        }
        return nil
    }
}

@MainActor
final class MenuBarPreviewView: NSView {
    /// The strip's height: the real bar's thickness with a little air.
    static var barHeight: CGFloat { NSStatusBar.system.thickness + 12 }
    /// Between two items, roughly what the real bar leaves.
    private static let itemGap: CGFloat = 14
    private static let inset: CGFloat = 12
    /// How far past the strip's edge a dragged element counts as dropped
    /// off the bar.
    private static let removalReach: CGFloat = 18

    var items: [StatusItemRenderer.ItemModel] = []
    var canDrag = false
    var onDrag: ([String]) -> Void = { _ in }
    var onDrop: ([String]?) -> Void = { _ in }
    var onElementDrag: (String, [MenuBarElement]) -> Void = { _, _ in }
    var onElementDrop: (String, [MenuBarElement]?) -> Void = { _, _ in }
    var onPlaceElement: (String?, MenuBarElement, Bool) -> Void = { _, _, _ in }

    /// One cell's rect in view coordinates, with the item image it belongs
    /// to and its rect inside that image.
    private struct Slot {
        let profileID: String?
        let itemIndex: Int
        let rect: NSRect
        let imageRect: NSRect
    }

    /// One (cell, element) rect, the same way.
    private struct ElementSlot {
        let profileID: String?
        let element: MenuBarElement?
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

    private struct ElementDrag {
        let profileID: String
        let element: MenuBarElement
        let grabOffset: CGFloat
        let original: [MenuBarElement]
        var pointer: NSPoint
        var elements: [MenuBarElement]
        /// Off the strip: the release removes it.
        var outside = false
    }

    /// A palette drag hovering over the strip: which account's meters it
    /// would land beside, and on which side.
    private struct DropHint: Equatable {
        let profileID: String?
        let beforeMeters: Bool
    }

    private var drag: Drag?
    private var elementDrag: ElementDrag?
    private var dropHint: DropHint?
    private var hovered: String?
    private var hoveredElement: (String, MenuBarElement)?
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([MenuBarElementDrag.pasteboardType, .string])
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not instantiated from a nib") }

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
    private func layout(_ images: [NSImage]) -> (origins: [CGFloat], slots: [Slot], elements: [ElementSlot]) {
        var origins: [CGFloat] = []
        var slots: [Slot] = []
        var elements: [ElementSlot] = []
        var x = Self.inset
        let y = (bounds.height - thickness) / 2
        for (index, image) in images.enumerated() {
            origins.append(x)
            for rect in StatusItemRenderer.cellRects(for: items[index].model, height: thickness) {
                slots.append(Slot(
                    profileID: rect.profileID, itemIndex: index,
                    rect: rect.rect.offsetBy(dx: x, dy: y), imageRect: rect.rect))
            }
            for rect in StatusItemRenderer.elementRects(for: items[index].model, height: thickness) {
                elements.append(ElementSlot(
                    profileID: rect.profileID, element: rect.element, itemIndex: index,
                    rect: rect.rect.offsetBy(dx: x, dy: y), imageRect: rect.rect))
            }
            x += image.size.width + Self.itemGap
        }
        return (origins, slots, elements)
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
        NSColor.white.withAlphaComponent(dropHint == nil ? 0.08 : 0.25).setStroke()
        ground.lineWidth = 1
        ground.stroke()

        let images = images()
        let (origins, slots, elementSlots) = layout(images)
        let y = (bounds.height - thickness) / 2

        // A grabbable cell or element under the pointer wears a faint wash.
        if drag == nil, elementDrag == nil {
            if let hoveredElement,
               let slot = elementSlots.first(where: { $0.profileID == hoveredElement.0 && $0.element == hoveredElement.1 }) {
                NSColor.white.withAlphaComponent(0.09).setFill()
                NSBezierPath(roundedRect: slot.rect.insetBy(dx: -2, dy: -2), xRadius: 5, yRadius: 5).fill()
            } else if let hovered, canDrag, let slot = slots.first(where: { $0.profileID == hovered }) {
                NSColor.white.withAlphaComponent(0.09).setFill()
                NSBezierPath(roundedRect: slot.rect.insetBy(dx: -3, dy: -2), xRadius: 5, yRadius: 5).fill()
            }
        }

        for (index, image) in images.enumerated() {
            let origin = NSPoint(x: origins[index], y: y)
            if let drag, let slot = slots.first(where: { $0.profileID == drag.profileID && $0.itemIndex == index }) {
                // The dragged cell rides with the pointer; the rest of its
                // item stays put with that cell's slice knocked out.
                drawKnockedOut(image, at: origin, hole: slot.rect)
                let lifted = NSRect(
                    x: drag.pointerX - drag.grabOffset, y: y,
                    width: slot.imageRect.width, height: thickness)
                drawLifted(image, from: slot.imageRect, in: lifted)
                continue
            }
            if let elementDrag,
               let slot = elementSlots.first(where: {
                   $0.profileID == elementDrag.profileID && $0.element == elementDrag.element && $0.itemIndex == index
               }) {
                drawKnockedOut(image, at: origin, hole: slot.rect)
                if !elementDrag.outside {
                    let lifted = NSRect(
                        x: elementDrag.pointer.x - elementDrag.grabOffset, y: y,
                        width: slot.imageRect.width, height: thickness)
                    drawLifted(image, from: slot.imageRect, in: lifted)
                }
                continue
            }
            image.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        }

        // A palette drag's landing mark: a bright bar at the side of the
        // meters it would sit on.
        if let dropHint,
           let meters = elementSlots.first(where: { $0.profileID == dropHint.profileID && $0.element == .meters }) {
            let x = dropHint.beforeMeters ? meters.rect.minX - 3 : meters.rect.maxX + 2
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: x, y: y - 2, width: 2, height: thickness + 4),
                xRadius: 1, yRadius: 1).fill()
        }
    }

    private func drawKnockedOut(_ image: NSImage, at origin: NSPoint, hole: NSRect) {
        NSGraphicsContext.current?.saveGraphicsState()
        let keep = NSBezierPath(rect: bounds)
        keep.append(NSBezierPath(rect: hole))
        keep.windingRule = .evenOdd
        keep.addClip()
        image.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func drawLifted(_ image: NSImage, from imageRect: NSRect, in lifted: NSRect) {
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: lifted.insetBy(dx: -3, dy: -2), xRadius: 5, yRadius: 5).fill()
        image.draw(in: lifted, from: imageRect, operation: .sourceOver, fraction: 0.95)
    }

    // MARK: - Pointer

    private func slot(at point: NSPoint) -> Slot? {
        let (_, slots, _) = layout(images())
        return slots.first { $0.profileID != nil && $0.rect.insetBy(dx: -3, dy: -2).contains(point) }
    }

    /// A placed element under the pointer — anything but the meters,
    /// which are the account's own body.
    private func elementSlot(at point: NSPoint) -> ElementSlot? {
        let (_, _, elements) = layout(images())
        return elements.first {
            $0.profileID != nil && $0.element != nil && $0.element != .meters
                && $0.rect.insetBy(dx: -2, dy: -2).contains(point)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil, elementDrag == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let overElement = elementSlot(at: point).flatMap { slot -> (String, MenuBarElement)? in
            guard let id = slot.profileID, let element = slot.element else { return nil }
            return (id, element)
        }
        let over = overElement == nil ? slot(at: point)?.profileID : nil
        let changed = over != hovered
            || overElement?.0 != hoveredElement?.0 || overElement?.1 != hoveredElement?.1
        hovered = over
        hoveredElement = overElement
        if changed { needsDisplay = true }
        if overElement != nil || (over != nil && canDrag) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard drag == nil, elementDrag == nil else { return }
        hovered = nil
        hoveredElement = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let slot = elementSlot(at: point), let id = slot.profileID, let element = slot.element {
            let elements = items.flatMap(\.model.cells).first { $0.profileID == id }?.elements ?? []
            elementDrag = ElementDrag(
                profileID: id, element: element, grabOffset: point.x - slot.rect.minX,
                original: elements, pointer: point, elements: elements)
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }
        guard canDrag, let slot = slot(at: point), let id = slot.profileID else { return }
        let order = cellOrder()
        drag = Drag(
            profileID: id, grabOffset: point.x - slot.rect.minX, original: order,
            pointerX: point.x, order: order)
        NSCursor.closedHand.set()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if var current = elementDrag {
            current.pointer = point
            // Off the strip by a margin: the element is being thrown away.
            let outside = !bounds.insetBy(dx: -Self.removalReach, dy: -Self.removalReach).contains(point)
            current.outside = outside
            let (_, _, elementSlots) = layout(images())
            let meters = elementSlots.first { $0.profileID == current.profileID && $0.element == .meters }
            let liftedCenter = point.x - current.grabOffset
                + (elementSlots.first { $0.profileID == current.profileID && $0.element == current.element }?.rect.width ?? 0) / 2
            let arranged: [MenuBarElement]
            if outside {
                arranged = MenuBarLayout.removingRunsOut(from: current.original)
            } else if let meters {
                arranged = MenuBarLayout.placing(
                    current.element, beforeMeters: liftedCenter < meters.rect.midX, in: current.original)
            } else {
                arranged = current.original
            }
            if arranged != current.elements {
                current.elements = arranged
                onElementDrag(current.profileID, arranged)
            }
            elementDrag = current
            (outside ? NSCursor.disappearingItem : NSCursor.closedHand).set()
            needsDisplay = true
            return
        }
        guard var current = drag else { return }
        current.pointerX = point.x
        // Past a neighbor's midpoint, the dragged cell takes its place —
        // the order the bar would then have, shown at once.
        let (_, slots, _) = layout(images())
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
        if let current = elementDrag {
            elementDrag = nil
            NSCursor.arrow.set()
            let landed = current.outside
                ? MenuBarLayout.removingRunsOut(from: current.original) : current.elements
            onElementDrop(current.profileID, landed != current.original ? landed : nil)
            needsDisplay = true
            return
        }
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

    // MARK: - Drop target (the palette)

    /// The account whose meters a point is nearest, and which side of them
    /// it is on. With no cell drawn at all (nothing fetched yet) the drop
    /// still lands — on whichever account the arrangement resolves to.
    private func hint(at point: NSPoint) -> DropHint {
        let (_, _, elementSlots) = layout(images())
        let meters = elementSlots.filter { $0.profileID != nil && $0.element == .meters }
        guard let nearest = meters.min(by: { abs($0.rect.midX - point.x) < abs($1.rect.midX - point.x) })
        else { return DropHint(profileID: nil, beforeMeters: false) }
        return DropHint(profileID: nearest.profileID, beforeMeters: point.x < nearest.rect.midX)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard MenuBarElementDrag.element(on: sender.draggingPasteboard) != nil else { return [] }
        dropHint = hint(at: convert(sender.draggingLocation, from: nil))
        needsDisplay = true
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard MenuBarElementDrag.element(on: sender.draggingPasteboard) != nil else { return [] }
        let next = hint(at: convert(sender.draggingLocation, from: nil))
        if next != dropHint {
            dropHint = next
            needsDisplay = true
        }
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropHint = nil
        needsDisplay = true
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        MenuBarElementDrag.element(on: sender.draggingPasteboard) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer {
            dropHint = nil
            needsDisplay = true
        }
        guard let element = MenuBarElementDrag.element(on: sender.draggingPasteboard) else { return false }
        let landing = hint(at: convert(sender.draggingLocation, from: nil))
        onPlaceElement(landing.profileID, element, landing.beforeMeters)
        return true
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
        // Each tile at its own width — the digits swatch is three times
        // the dot's, and a squeezed row clipped it and wrapped its title.
        HStack(alignment: .top, spacing: 8) {
            ForEach(MenuBarForm.allCases) { form in
                FormTile(
                    cell: cell, form: form, selected: form == selection,
                    onSelect: { onSelect(form) })
                    .fixedSize()
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
        sample.elements = MenuBarLayout.standard
        return StatusItemRenderer.cellImage(sample, height: NSStatusBar.system.thickness)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 4) {
                MenuBarSwatch(image: thumbnail, selected: selected, hovering: hovering)
                Text(form.title)
                    .font(.caption2.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
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

/// A rendered piece of the bar on a swatch of menu-bar ground — the form
/// tiles and the element palette share it, so a picture in either place
/// reads like the bar.
struct MenuBarSwatch: View {
    let image: NSImage
    var selected = false
    var hovering = false

    var body: some View {
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
    }
}
