import Foundation
import UsageCore

/// The bar-wide half of how several accounts draw (0.97.0). The per-account
/// half — each cell's `MenuBarForm`, whether it takes its own item — lives
/// on the `Profile` record; this is the one switch that is nobody's in
/// particular: whether the FOCUSED account expands to today's digits
/// whatever its form. On by default, which is what keeps a fresh install's
/// bar exactly what it was — bars for the others, the focused account's
/// numbers spelled out — and a one-account bar byte-identical.
enum MenuBarPreferences {
    static let expandsFocusKey = "menuBarExpandsFocus"
    /// 0.96.0's whole-bar style, read once by `migrateLegacyStyle` and
    /// removed — nobody's bar changes on update.
    static let legacyStyleKey = "menuBarStyle"

    static func expandsFocus(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: expandsFocusKey) as? Bool ?? true
    }

    static func setExpandsFocus(_ expands: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(expands, forKey: expandsFocusKey)
    }

    /// The six named styles of 0.96.0 were combinations of the three
    /// choices that exist now; a stored one is spelled out into them for
    /// every record of the provider that had it, then forgotten.
    static func migrateLegacyStyle(provider: any UsageProvider, defaults: UserDefaults = .standard) {
        guard let raw = defaults.string(forKey: legacyStyleKey) else { return }
        defaults.removeObject(forKey: legacyStyleKey)
        let (form, expands, own): (MenuBarForm, Bool, Bool)
        switch raw {
        case "barsExpandedFocus": (form, expands, own) = (.bars, true, false)
        case "bars": (form, expands, own) = (.bars, false, false)
        case "rings": (form, expands, own) = (.rings, false, false)
        case "compactDigits": (form, expands, own) = (.compactDigits, false, false)
        case "focusedSentinels": (form, expands, own) = (.dot, true, false)
        case "itemPerProfile": (form, expands, own) = (.digits, false, true)
        default: return
        }
        setExpandsFocus(expands, in: defaults)
        var stored = ProfileStore.load(from: defaults)
        var sawDefault = false
        for index in stored.indices where stored[index].providerID == provider.id {
            stored[index].menuBarForm = form
            stored[index].ownMenuBarItem = own
            sawDefault = sawDefault || stored[index].isDefault
        }
        // The implicit default record only exists once it differs from the
        // standard — which a migrated style makes it.
        if !sawDefault, form != .standard || own {
            var standard = Profile.standard(for: provider, addedAt: Date())
            standard.menuBarForm = form
            standard.ownMenuBarItem = own
            stored.insert(standard, at: 0)
        }
        ProfileStore.save(stored, to: defaults)
    }
}
