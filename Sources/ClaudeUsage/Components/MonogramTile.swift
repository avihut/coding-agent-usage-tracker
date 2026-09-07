import SwiftUI
import UsageCore

/// An account's monogram as a small rounded tile — the panel and popover
/// echo of the menu bar cell's letter (0.96.0). Identity is a letter, never
/// a color: the app's colors already mean risk and model, so the tile is
/// neutral ink and only its WEIGHT changes with focus.
struct MonogramTile: View {
    let monogram: String
    var focused: Bool = false
    var size: CGFloat = 18

    var body: some View {
        Text(monogram)
            .font(.system(size: size * 0.62, weight: .semibold, design: .rounded))
            .foregroundStyle(focused ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(Color.primary.opacity(focused ? 0.16 : 0.09)))
            .accessibilityHidden(true)
    }
}
