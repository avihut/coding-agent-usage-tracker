import AppKit
import CoreText
import UsageCore

/// A harness's MARK: how large it draws, and where. Split out of
/// StatusItemRenderer.swift along this seam when that file passed the
/// ~600-line rule; the panel's `HarnessMark` draws through `drawMark` too.
extension StatusItemRenderer {
    /// Percent of the point size, as `NSAttributedString.Key.strokeWidth`
    /// counts it (negative = fill AND stroke).
    static let markStroke: CGFloat = 5

    static func markRun(_ glyph: String, _ color: NSColor, _ markFont: NSFont) -> Run {
        markFont == font ? .text(glyph, color, markFont) : .mark(glyph, color, markFont)
    }

    /// Draws a mark with its INK centred in `box` — vertically always,
    /// horizontally unless `x` names where its line starts (a bar run's own
    /// origin, so its measured width still holds). Through CoreText at an
    /// exact BASELINE, never `draw(at:)` (user-reported the day it landed:
    /// ⬡ sat right and ✳︎ rode high): `draw(at:)` places a line box, and
    /// where the baseline falls inside it depends on which FALLBACK font
    /// serves the glyph — these marks are not in the system font, and no
    /// descender read off `markFont` is the right one for both.
    static func drawMark(
        _ glyph: String, color: NSColor, font markFont: NSFont, shadow: NSShadow? = nil,
        x: CGFloat? = nil, in box: NSRect
    ) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: glyph,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): markFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
                NSAttributedString.Key(kCTStrokeColorAttributeName as String): color.cgColor,
                NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -markStroke,
            ]))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        shadow?.set()
        context.textMatrix = .identity
        context.textPosition = .zero
        // Relative to the baseline origin: exactly what has to be centred.
        let ink = CTLineGetImageBounds(line, context)
        context.textPosition = CGPoint(
            x: x ?? box.midX - ink.midX, y: box.midY - ink.midY)
        CTLineDraw(line, context)
    }

    /// How much larger a mark draws when it heads a harness's block.
    static let headingScale: CGFloat = 1.2

    /// A mark's font, sized by its INK (0.101.0, user-reported: Codex's ⬡
    /// drew far smaller than the designs). Vendors' marks are arbitrary
    /// Unicode, and at one point size their ink differs wildly. Each mark is
    /// scaled until its ink fills the bundled mark's; the bundled mark
    /// itself scales by exactly 1, which is what keeps every pinned
    /// one-harness snapshot byte-identical. Clamped: a mark with almost no
    /// ink (a dot, a dash) must not balloon.
    ///
    /// `heading` (user-directed, the same day): in a bar of SEVERAL harnesses
    /// a mark heads its block, and every mark — the bundled one included —
    /// draws a step larger. Never in a one-harness bar, whose pixels are
    /// pinned to v0.100.1.
    static func glyphFont(for glyph: String, heading: Bool = false) -> NSFont {
        let fitted = fittedGlyphFont(for: glyph)
        guard heading else { return fitted }
        return .monospacedDigitSystemFont(ofSize: fitted.pointSize * headingScale, weight: .semibold)
    }

    static func fittedGlyphFont(for glyph: String) -> NSFont {
        let reference = HarnessStyle.bundled.glyph
        guard glyph != reference else { return font }
        func ink(_ string: String) -> CGSize {
            NSAttributedString(string: string, attributes: [.font: font])
                .boundingRect(with: .zero, options: [.usesDeviceMetrics]).size
        }
        let (mine, target) = (ink(glyph), ink(reference))
        guard min(mine.width, mine.height) > 0.5 else { return font }
        // Until it fills the reference in BOTH dimensions: ⬡ is narrower
        // than it is short (6.5 × 7.5 against 8.3 × 8.3), and an outline
        // matched on height alone still read as the small one.
        let scale = min(1.5, max(target.width / mine.width, target.height / mine.height))
        guard scale > 1.02 else { return font }
        return .monospacedDigitSystemFont(ofSize: font.pointSize * scale, weight: .semibold)
    }
}
