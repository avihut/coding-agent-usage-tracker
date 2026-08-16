import SwiftUI

// MARK: - Dashboard header primitives

/// Muted hues for the stat tiles — each tile wears its color as a light
/// wash, a slightly stronger frame, and a corner glyph, desaturated enough
/// to sit quietly in both appearances. The prompts tile uses the provider
/// accent instead: ❯ is already the app's prompt color story.
enum StatTint {
    static let api = Color(red: 0.31, green: 0.50, blue: 0.79)
    static let tools = Color(red: 0.56, green: 0.41, blue: 0.77)
    static let agents = Color(red: 0.25, green: 0.62, blue: 0.50)
    static let compactions = Color(red: 0.74, green: 0.58, blue: 0.25)
    static let tokens = Color(red: 0.39, green: 0.44, blue: 0.54)
}

/// One dashboard stat: the whole tile wears a light wash of its color
/// under a slightly stronger frame of the same tint, and the tinted
/// glyph, number, and noun stack centered — the glyph gets its own row
/// so no width can collide it with the value. Tiles stretch — each takes
/// an equal share of the row, so the grid fills the header at any width.
struct StatTile: View {
    let symbol: String
    let tint: Color
    let value: String
    let label: String

    @State private var hovered = false

    /// The KPI number wants a touch more light than the standard label's
    /// 85%-white dark-mode ink; light mode keeps the standard label.
    private static let valueColor = Color(nsColor: NSColor(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.96)
                : .labelColor
        }))

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            VStack(spacing: 1) {
                Text(value)
                    .font(.system(size: 20, weight: .bold).monospacedDigit())
                    .foregroundStyle(Self.valueColor)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(
            // The wash deepens a touch under the cursor — the same quiet
            // lift the model grid's rows give.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(hovered ? 0.16 : 0.1)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.3), lineWidth: 1))
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// Wraps subviews into left-aligned rows the way text wraps words — the
/// context strip's chips flow to the pane's width instead of imposing one.
struct FlowLayout: Layout {
    var hSpacing: CGFloat = 16
    var vSpacing: CGFloat = 5

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        arrange(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let slots = arrange(in: bounds.width, subviews: subviews).slots
        for (subview, slot) in zip(subviews, slots) {
            subview.place(
                at: CGPoint(x: bounds.minX + slot.x, y: bounds.minY + slot.y),
                proposal: .unspecified)
        }
    }

    private func arrange(
        in width: CGFloat, subviews: Subviews
    ) -> (size: CGSize, slots: [CGPoint]) {
        var slots: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            slots.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x + size.width)
            x += size.width + hSpacing
        }
        return (CGSize(width: maxX, height: y + rowHeight), slots)
    }
}

// MARK: - Skeleton primitives

/// One placeholder bar, matched to the text heights it stands in for. An
/// accent bar suggests a prompt row. `width` is a CAP, never a constant —
/// the text a bar stands in for truncates under pressure, so the bar must
/// compress the same way. A fixed width would give the skeleton a larger
/// minimum than the loaded content and make the split view breathe on
/// every selection change.
struct SkeletonBar: View {
    var width: CGFloat?
    var height: CGFloat = 9
    var accent = false

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(accent
                ? ProviderStyle.accentColor.opacity(0.14)
                : Color.primary.opacity(0.07))
            .frame(height: height)
            .frame(maxWidth: width, alignment: .leading)
    }
}

/// A gentle breathing pulse over skeleton content — the "still working"
/// signal. Honors Reduce Motion by standing still.
struct Pulsing<Content: View>: View {
    @ViewBuilder var content: Content

    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .opacity(dimmed ? 0.45 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}
