import SwiftUI

/// The main window's one layout: its sections flow into as many columns as
/// the width holds, each at least the popover's width. One column IS the
/// popover — the same sections in the same order — and every extra column a
/// wider window affords puts more of them side by side, so the page fills
/// the window instead of sitting in the middle of it, and scrolls only when
/// the sections really don't fit.
///
/// Placement is masonry in reading order: each section goes into the
/// column that is shortest so far, so the first row reads left to right in
/// the sections' own order and nothing leaves a hole under a short one.
struct DashboardFlow: Layout {
    /// The popover's width: its sections are drawn for at least this.
    var minColumnWidth: CGFloat = 360
    var maxColumns = 4
    var spacing: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.map { $0.isFinite ? $0 : minColumnWidth } ?? minColumnWidth
        let placed = place(subviews, width: width)
        return CGSize(width: width, height: placed.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = place(subviews, width: bounds.width)
        for (subview, frame) in zip(subviews, placed.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    /// How many columns `width` holds, and how wide each one is.
    func columns(for width: CGFloat) -> (count: Int, width: CGFloat) {
        let fits = Int(((width + spacing) / (minColumnWidth + spacing)).rounded(.down))
        let count = min(maxColumns, max(1, fits))
        let columnWidth = max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
        return (count, columnWidth)
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let (count, columnWidth) = columns(for: width)
        var heights = Array(repeating: CGFloat(0), count: count)
        var frames: [CGRect] = []
        for subview in subviews {
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let size = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            let y = heights[column] == 0 ? 0 : heights[column] + spacing
            frames.append(CGRect(
                x: CGFloat(column) * (columnWidth + spacing), y: y,
                width: columnWidth, height: size.height))
            heights[column] = y + size.height
        }
        return (frames, heights.max() ?? 0)
    }
}

/// One section of the window: its content on a quiet rounded ground, so
/// the flow's columns read as a set of panels. Every section is one, which
/// is what keeps any of them from looking foreign.
struct DashboardTile<Content: View>: View {
    @ViewBuilder let content: Content

    /// The ground's inset — the panel's own 14pt margin.
    static var inset: CGFloat { 14 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(Self.inset)
        // minWidth 0: a frame with no lower bound takes its child's width
        // when the child is wider, so one wide chart could push a tile past
        // its column. The column decides; the content fits it.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension DashboardFlow {
    /// The inner width of one tile when the flow is `width` wide — what a
    /// chart inside a tile is drawn at. Computed from the PAGE's width, which
    /// only the window decides, never measured from a tile, whose width a
    /// wide chart could otherwise hold open after the window narrows.
    func tileInnerWidth(forPageWidth width: CGFloat) -> CGFloat {
        columns(for: width).width - 2 * DashboardTile<EmptyView>.inset
    }
}

extension View {
    /// The width this view is given, reported as it changes.
    func reportingWidth(_ width: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
            if new > 0, abs(new - width.wrappedValue) > 0.5 { width.wrappedValue = new }
        }
    }
}
