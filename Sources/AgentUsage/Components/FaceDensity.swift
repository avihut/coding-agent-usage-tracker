import SwiftUI

/// How much room the popover's components are drawn with. The panel is a
/// 360pt popover set in the menu-scale caption sizes; the main window gives
/// the same components the macOS text scale (section headers `headline`,
/// meter percentages the largest numbers on the page, captions
/// `subheadline`). Dense grids and chart axes keep their size everywhere —
/// they are read as structure, not as text.
///
/// `.panel` returns the popover's literal fonts, and the popover never sets
/// the value, so it draws exactly as it always has.
enum FaceDensity {
    case panel
    case window

    var isWindow: Bool { self == .window }

    /// A section's title (Activity, Sessions).
    var sectionHeader: Font {
        isWindow ? .headline : .caption.bold()
    }

    var meterLabel: Font {
        isWindow ? .body : .callout
    }

    var meterPercent: Font {
        isWindow ? .title3.monospacedDigit().weight(.semibold) : .callout.monospacedDigit().bold()
    }

    var meterBarHeight: CGFloat {
        isWindow ? 6 : 5
    }

    /// "resets in 2h · runs out in 1h".
    var meterCaption: Font {
        isWindow ? .subheadline : .caption2
    }

    /// The breakdown grid's "≈ $396": demoted below the meters in a window,
    /// where the percentages are the page's largest numbers.
    var costHeadline: Font {
        isWindow
            ? .title3.weight(.semibold).monospacedDigit()
            : .system(size: 18, weight: .semibold).monospacedDigit()
    }

    /// The pipeline line ("Updated 12:56 · next in 4m") and the plan.
    var statusLine: Font {
        isWindow ? .footnote : .caption
    }

    /// The pipeline line's second tier.
    var statusDetail: Font {
        isWindow ? .footnote : .caption2
    }
}

private struct FaceDensityKey: EnvironmentKey {
    static let defaultValue = FaceDensity.panel
}

extension EnvironmentValues {
    /// Set at the root of a main-window page; absent (`.panel`) everywhere
    /// else.
    var faceDensity: FaceDensity {
        get { self[FaceDensityKey.self] }
        set { self[FaceDensityKey.self] = newValue }
    }
}
