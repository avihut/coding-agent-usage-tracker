import Foundation

/// How the menu bar shows several accounts (decision D5, user-directed:
/// every style ships as a Settings picker; bars with the focused account
/// expanded is the default). With ONE account every style draws today's
/// single item — the style only decides how cells beyond the first fold.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    /// The focused account as today's digits, every other as a monogram
    /// and three stacked bars.
    case barsExpandedFocus
    /// Every account as a monogram and three stacked bars.
    case bars
    /// Every account as a monogram and two rings — outer weekly, inner
    /// session; the scoped meter folds into the outer ring's color.
    case rings
    /// Every account as a monogram and its session·weekly percents, no
    /// tags, no scoped number.
    case compactDigits
    /// The focused account as today's digits; every other a 7pt sentinel
    /// painted by its worst severity.
    case focusedSentinels
    /// One status item per account, each today's digits — ⌘-drag orders
    /// and removes them one by one.
    case itemPerProfile

    static let key = "menuBarStyle"
    static let standard: MenuBarStyle = .barsExpandedFocus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .barsExpandedFocus: "Bars, focused expanded"
        case .bars: "Bars"
        case .rings: "Rings"
        case .compactDigits: "Compact digits"
        case .focusedSentinels: "Focused + sentinels"
        case .itemPerProfile: "One item per account"
        }
    }

    var caption: String {
        switch self {
        case .barsExpandedFocus: "The focused account's numbers; the others as three small bars."
        case .bars: "Three small bars per account — session, weekly, scoped."
        case .rings: "Two rings per account — outer weekly, inner session."
        case .compactDigits: "Session and weekly percents per account, no tags."
        case .focusedSentinels: "The focused account's numbers; the others as a dot colored by risk."
        case .itemPerProfile: "A separate menu bar item per account; ⌘-drag to order or remove."
        }
    }

    /// Whether every account gets its own `NSStatusItem`.
    var isItemPerProfile: Bool { self == .itemPerProfile }

    static func stored(in defaults: UserDefaults = .standard) -> MenuBarStyle {
        defaults.string(forKey: key).flatMap(MenuBarStyle.init(rawValue:)) ?? standard
    }

    static func store(_ style: MenuBarStyle, in defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: key)
    }
}
