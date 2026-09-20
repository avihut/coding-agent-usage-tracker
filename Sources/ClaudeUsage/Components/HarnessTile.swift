import AppKit
import SwiftUI
import UsageCore

/// A harness's own mark as a small rounded tile — the panel echo of the menu
/// bar's leading glyph (v0.101.0, per the approved mocks). It stands where an
/// account's `MonogramTile` stands and is exactly its size, so a strip mixing
/// both keeps one column.
///
/// WHEN each is used is the mocks' rule, and it is about what identifies the
/// row: "A harness with one account needs no letter: the glyph is its name."
/// So a lone account of a harness wears the vendor's mark, and an account of a
/// harness that has several wears its own letter under a heading that carries
/// the mark once.
///
/// The glyph keeps its vendor accent whether or not the row is focused —
/// unlike a monogram, whose ink is what focus moves. Colour here says which
/// vendor, and it would be a lie for it to fade with attention.
/// A vendor's mark drawn to a given INK size (0.101.0, user-reported: "very
/// small"). The marks are arbitrary Unicode whose ink differs wildly at one
/// point size — ⬡ is 6.5 × 7.5 where ✳︎ is 8.3 × 8.3 — so a font size can't
/// make them agree. This scales each until its larger ink dimension is
/// `ink` points, centres it on that ink, and strokes it in its own colour
/// (an outline glyph's hair stays a hair however large). The menu bar's
/// marks follow the same rule through `StatusItemRenderer.glyphFont`.
struct HarnessMark: View {
    let style: HarnessStyle
    let ink: CGFloat

    var body: some View {
        Image(nsImage: Self.image(glyph: style.glyph, color: style.nsAccent, ink: ink))
            .accessibilityHidden(true)
    }

    static func image(glyph: String, color: NSColor, ink: CGFloat) -> NSImage {
        func bounds(_ font: NSFont) -> NSRect {
            NSAttributedString(string: glyph, attributes: [.font: font])
                .boundingRect(with: .zero, options: [.usesDeviceMetrics])
        }
        let probe = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let measured = bounds(probe)
        let larger = max(measured.width, measured.height)
        let font = NSFont.systemFont(
            ofSize: larger > 0.5 ? 12 * ink / larger : ink, weight: .semibold)
        let side = (ink * 1.25).rounded(.up)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            StatusItemRenderer.drawMark(
                glyph, color: color, font: font,
                in: NSRect(x: 0, y: 0, width: side, height: side))
            return true
        }
    }
}

struct HarnessTile: View {
    let style: HarnessStyle
    var focused: Bool = false
    var size: CGFloat = 18

    var body: some View {
        HarnessMark(style: style, ink: size * 0.64)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(Color.primary.opacity(focused ? 0.16 : 0.09)))
            .accessibilityHidden(true)
    }
}

/// The heading above a harness's accounts, drawn only when it has more than
/// one — otherwise its single row's tile already carries the mark. The glyph
/// sits in an 18pt slot at the same leading inset as the tiles below it, so
/// it reads as a label for that column rather than as a row of its own.
struct HarnessHeading: View {
    let style: HarnessStyle
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            HarnessMark(style: style, ink: 11)
                .frame(width: 18)
            Text(name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        // Aligns the glyph over the tiles: a row's 6pt inset plus its 2pt
        // focus rail plus the 8pt gap puts a tile's leading edge here.
        .padding(.leading, 16)
        .padding(.top, 4)
        .padding(.bottom, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
    }
}
