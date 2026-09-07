import Foundation

/// How ONE account's cell draws in the menu bar (0.97.0, user-directed:
/// "set it per account, to be rings, bars, etc." — with one control that
/// sets every account at once). A per-account fact, stored on the
/// `Profile` record, so the six whole-bar styles of 0.96.0 dissolve into
/// three orthogonal choices: each account's form, whether the focused
/// account is expanded to digits whatever its form, and whether an account
/// takes its own menu bar item.
///
/// The renderer is app-side and the digest carries no form: the daemon
/// reads the record and ignores the field.
public enum MenuBarForm: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Today's full item — every meter's tag and number.
    case digits
    /// Three stacked bars: session, weekly, scoped.
    case bars
    /// Two rings — outer weekly, inner session; the scoped meter folds
    /// into the outer ring's color.
    case rings
    /// Session and weekly percents, no tags, no scoped number.
    case compactDigits
    /// A 7pt dot painted by the account's worst risk.
    case dot

    /// What a fresh record draws as: with the focused account expanded
    /// (the default), a one-account Mac's bar is exactly the pre-profile
    /// item.
    public static let standard: MenuBarForm = .bars

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .digits: "Digits"
        case .bars: "Bars"
        case .rings: "Rings"
        case .compactDigits: "Compact"
        case .dot: "Dot"
        }
    }

    public var caption: String {
        switch self {
        case .digits: "Every meter's tag and number, the full item."
        case .bars: "Three small bars — session, weekly, scoped."
        case .rings: "Two rings — outer weekly, inner session."
        case .compactDigits: "Session and weekly percents, no tags."
        case .dot: "One dot colored by the account's worst risk."
        }
    }
}
