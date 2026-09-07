import SwiftUI
import UsageCore

/// Settings → Menu bar (0.98.1, user-directed: styling the bar among the
/// accounts was confusing): everything about how the bar DRAWS — the live
/// preview, one form or each account's own, the elements, focus expansion,
/// focus — and, per account, whether it takes a cell, an item of its own,
/// and its own form and elements. Whether an account is metered at all
/// stays under Accounts. Every provider has the pane: a one-account Mac
/// styles its bar too.
struct MenuBarSettingsPane: View {
    var registry: ProviderRegistry

    var body: some View {
        SettingsPaneScroll {
            MenuBarSettingsCard(registry: registry)
            AccountsInBarCard(registry: registry)
        }
    }
}

/// The bar as a whole (0.97.0): the live preview first — drag the accounts
/// into order — then the controls that are nobody's in particular. Which
/// form wins is a SWITCH, not a precedence rule to remember (0.97.1,
/// user-directed): "Same form for every account" on means the form here
/// draws; off means each account's own, set on its row below.
struct MenuBarSettingsCard: View {
    var registry: ProviderRegistry
    @AppStorage(MenuBarPreferences.expandsFocusKey) private var expandsFocus = true
    @AppStorage(MenuBarPreferences.uniformKey) private var uniform = true
    @AppStorage(MenuBarPreferences.uniformFormKey) private var uniformFormRaw = MenuBarForm.standard.rawValue
    @AppStorage(MenuBarPreferences.focusedElementsOnlyKey) private var focusedElementsOnly = true
    /// The bar-wide element list (a string array, which @AppStorage can't
    /// bind): mirrored from the defaults on every defaults change so the
    /// card re-renders the instant a drop lands.
    @State private var uniformElements = MenuBarPreferences.current().uniformElements
    /// Dress the preview as if a limit were running out — the only way to
    /// see the conditional element on a quiet day. Never persisted.
    @State private var simulateCrossing = false

    private var prefs: MenuBarPreferences.Values {
        MenuBarPreferences.Values(
            expandsFocus: expandsFocus, uniform: uniform,
            uniformForm: MenuBarForm(rawValue: uniformFormRaw) ?? .standard,
            uniformElements: uniformElements, focusedElementsOnly: focusedElementsOnly)
    }
    private var several: Bool { registry.barProfiles.count > 1 }

    var body: some View {
        card.onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let current = MenuBarPreferences.current().uniformElements
            if current != uniformElements { uniformElements = current }
        }
    }

    private var card: some View {
        SettingsCard("Menu bar", footer: footer) {
            VStack(alignment: .leading, spacing: 6) {
                MenuBarPreview(registry: registry, prefs: prefs, simulate: simulateCrossing)
                HStack(alignment: .firstTextBaseline) {
                    Text(several
                        ? "Drag an account to reorder; drag an element across its meters, or off the bar to remove it."
                        : "Drag an element across the meters, or off the bar to remove it.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Toggle("Preview as if a limit were running out", isOn: $simulateCrossing)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.caption)
                        .help("Dresses the preview as if the session limit were half an hour from running out, so a conditional element shows")
                }
            }
            Divider()
            if uniform || !several {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add to the bar")
                    MenuBarElementPalette(
                        registry: registry, profile: registry.focusedProfile,
                        elements: prefs.elements(for: registry.focusedProfile),
                        onChange: { elements in
                            if uniform {
                                MenuBarPreferences.setUniformElements(elements)
                            } else if let id = registry.focusedProfile?.id {
                                registry.setMenuBarElements(id: id, elements: elements)
                            }
                        })
                }
                Divider()
            }
            if several {
                Toggle("Same form for every account", isOn: $uniform)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if uniform || !several {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Form")
                    MenuBarFormPicker(
                        cell: MenuBarModelBuilder.sampleCell(
                            for: registry.focusedProfile, registry: registry),
                        selection: prefs.form(for: registry.focusedProfile),
                        onSelect: { form in
                            if uniform {
                                uniformFormRaw = form.rawValue
                            } else if let id = registry.focusedProfile?.id {
                                registry.setMenuBarForm(id: id, form: form)
                            }
                        })
                }
            } else {
                note("Each account draws in the form set on its own row below, with the elements added there.")
            }
            if several {
                Toggle("Added elements for the focused account only", isOn: $focusedElementsOnly)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("On: one \"Runs out\" in the bar, the focused account's. Off: every account's cell carries its own.")
                Toggle("Expand the focused account", isOn: $expandsFocus)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                HStack(alignment: .firstTextBaseline) {
                    Text("Focus")
                    Spacer()
                    Picker("Focus", selection: Binding(
                        get: { registry.pinnedID ?? "" },
                        set: { registry.pin($0.isEmpty ? nil : $0) })
                    ) {
                        Text("Follows activity").tag("")
                        ForEach(registry.shownProfiles) { profile in
                            Text(registry.label(for: profile)).tag(profile.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } else {
                Toggle("Spell out the numbers", isOn: $expandsFocus)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }

    private var footer: String {
        if several {
            return "Added elements such as Runs out draw for the focused account only unless every"
                + " account is asked to carry its own. With the focused account expanded, its"
                + " numbers are spelled out whatever its form — and focus decides which account the"
                + " panel opens on. Following activity"
                + " picks the account this Mac has worked in most over the last two weeks; picking"
                + " an account in the panel pins it until Auto."
        }
        return "With the numbers spelled out the item is exactly what it has always been; turn that"
            + " off to draw your account in the form chosen above."
    }
}


/// Each metered account's place in the bar: whether it shows, whether it
/// takes an item of its own, and — while the bar draws each account its
/// own way — its form and its elements. Only with more than one account
/// enrolled; a lone account's form and elements are the card above.
private struct AccountsInBarCard: View {
    var registry: ProviderRegistry
    @AppStorage(MenuBarPreferences.uniformKey) private var uniform = true

    private var enrolled: [Profile] { registry.profiles.filter(\.isEnrolled) }

    var body: some View {
        if registry.activeProvider.supportsMultipleHomes, enrolled.count > 1 {
            SettingsCard(
                "Accounts in the bar",
                footer: uniform
                    ? "Turn off \"Same form for every account\" above to give each account its own form and elements."
                    : "Each account draws in its own form, with its own elements, as set here."
            ) {
                ForEach(Array(enrolled.enumerated()), id: \.element.id) { index, profile in
                    if index > 0 { Divider() }
                    AccountInBarRow(registry: registry, profile: profile, uniform: uniform)
                }
            }
        }
    }
}

private struct AccountInBarRow: View {
    var registry: ProviderRegistry
    let profile: Profile
    let uniform: Bool

    private var inBar: Bool { profile.enabled && profile.showInMenuBar }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                MonogramTile(
                    monogram: registry.monogram(for: profile),
                    focused: profile.id == registry.focusedID, size: 24)
                Text(registry.label(for: profile))
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !profile.enabled {
                    Text("Not metered")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 16) {
                Toggle("Show in menu bar", isOn: Binding(
                    get: { profile.showInMenuBar },
                    set: { registry.setShowInMenuBar(id: profile.id, shown: $0) }))
                    .disabled(!profile.enabled)
                Toggle("Own menu bar item", isOn: Binding(
                    get: { profile.ownMenuBarItem },
                    set: { registry.setOwnMenuBarItem(id: profile.id, own: $0) }))
                    .disabled(!inBar)
                    .help("A separate menu bar item for this account — ⌘-drag it anywhere along the bar")
                Spacer()
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            if !uniform {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Form")
                    MenuBarFormPicker(
                        cell: MenuBarModelBuilder.sampleCell(for: profile, registry: registry),
                        selection: profile.menuBarForm,
                        onSelect: { registry.setMenuBarForm(id: profile.id, form: $0) })
                    Text("Add to the bar")
                    MenuBarElementPalette(
                        registry: registry, profile: profile, elements: profile.menuBarElements,
                        onChange: { registry.setMenuBarElements(id: profile.id, elements: $0) })
                }
                .opacity(inBar ? 1 : 0.45)
                .disabled(!inBar)
            }
        }
    }
}
