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
    /// Whether ONE form applies to every account (0.97.1, user-directed:
    /// which of the two wins has to be visible) — on, the bar-wide form
    /// below is the one that draws and the per-account forms wait; off,
    /// each account's own form draws. On by default.
    static let uniformKey = "menuBarUniformForm"
    static let uniformFormKey = "menuBarUniformFormValue"
    /// The bar-wide element list (0.98.0) — what every cell holds while
    /// "Same form for every account" is on, stored as tokens. Absent =
    /// the meters alone, the pre-0.98 bar.
    static let uniformElementsKey = "menuBarUniformElements"
    /// 0.96.0's whole-bar style, read once by `migrateLegacyStyle` and
    /// removed — nobody's bar changes on update.
    static let legacyStyleKey = "menuBarStyle"

    /// Everything bar-wide, read once per render so the status item and
    /// the preview see one consistent set.
    struct Values: Equatable {
        var expandsFocus = true
        var uniform = true
        var uniformForm: MenuBarForm = .standard
        var uniformElements: [MenuBarElement] = MenuBarLayout.standard

        /// The form an account draws in under these values.
        func form(for profile: Profile?) -> MenuBarForm {
            uniform ? uniformForm : (profile?.menuBarForm ?? .standard)
        }

        /// The elements an account's cell holds under these values — the
        /// same switch decides: one arrangement for every account, or each
        /// account's own.
        func elements(for profile: Profile?) -> [MenuBarElement] {
            uniform ? uniformElements : (profile?.menuBarElements ?? MenuBarLayout.standard)
        }
    }

    static func current(in defaults: UserDefaults = .standard) -> Values {
        Values(
            expandsFocus: defaults.object(forKey: expandsFocusKey) as? Bool ?? true,
            uniform: defaults.object(forKey: uniformKey) as? Bool ?? true,
            uniformForm: defaults.string(forKey: uniformFormKey)
                .flatMap(MenuBarForm.init(rawValue:)) ?? .standard,
            uniformElements: defaults.stringArray(forKey: uniformElementsKey)
                .map(MenuBarLayout.decode(tokens:)) ?? MenuBarLayout.standard)
    }

    static func setUniformElements(_ elements: [MenuBarElement], in defaults: UserDefaults = .standard) {
        let normalized = MenuBarLayout.normalized(elements)
        if normalized == MenuBarLayout.standard {
            defaults.removeObject(forKey: uniformElementsKey)
        } else {
            defaults.set(MenuBarLayout.encode(normalized), forKey: uniformElementsKey)
        }
    }

    static func expandsFocus(in defaults: UserDefaults = .standard) -> Bool {
        current(in: defaults).expandsFocus
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
        defaults.set(true, forKey: uniformKey)
        defaults.set(form.rawValue, forKey: uniformFormKey)
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
