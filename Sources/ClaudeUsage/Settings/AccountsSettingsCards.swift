import AppKit
import SwiftUI
import UsageCore

/// The Accounts card (0.96.0, rows restructured 0.97.0): every home this
/// app meters for the active agent, what each one is signed in as, how its
/// cell draws in the menu bar, and the switches that decide whether it is
/// metered at all, whether it takes a cell, and whether that cell is an
/// item of its own. Plus the homes discovery found and nobody has decided
/// about.
///
/// "Profile" in code, "Account" here: what a person sees is which sign-in a
/// home carries (decision D1). The card renders for a provider that can
/// have several homes; a one-home agent (Codex, Gemini) never shows it.
struct AccountsCard: View {
    var registry: ProviderRegistry

    var body: some View {
        if registry.activeProvider.supportsMultipleHomes {
            SettingsCard(
                "Accounts",
                footer: "Each account is one \(registry.activeProvider.agentName) configuration"
                    + " directory with its own sign-in. Everything is read from that directory the"
                    + " same way the default one is read, and nothing is read from an account until"
                    + " you meter it. What is read from where is listed under General → About."
            ) {
                ForEach(Array(registry.profiles.filter(\.isEnrolled).enumerated()), id: \.element.id) { index, profile in
                    if index > 0 { Divider() }
                    AccountRow(registry: registry, profile: profile)
                }
                ForEach(registry.discoveredHomes, id: \.profileID) { home in
                    Divider()
                    DiscoveredAccountRow(registry: registry, home: home)
                }
                Divider()
                HStack {
                    Button("Add folder…") { addFolder() }
                    Button("Look again") { registry.discover() }
                        .help("Scan for other \(registry.activeProvider.agentName) configuration directories")
                    Spacer()
                }
            }
        }
    }

    /// Directories only, hidden files shown — every agent home on this Mac
    /// is a dot directory, so a picker that hides them would be useless.
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Meter"
        panel.message = "Choose a \(registry.activeProvider.agentName) configuration directory"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        registry.enroll(home: url)
    }
}

/// One metered account: who it is first, then what you can change about
/// it — name, form in the bar, the switches — then what it has been doing.
/// The paths it is read from are inventory, not settings, and live in the
/// privacy card.
private struct AccountRow: View {
    var registry: ProviderRegistry
    let profile: Profile

    @State private var nickname: String
    @State private var confirmingRemove = false
    @FocusState private var editingNickname: Bool
    @AppStorage(MenuBarPreferences.uniformKey) private var uniformForm = true

    init(registry: ProviderRegistry, profile: Profile) {
        self.registry = registry
        self.profile = profile
        _nickname = State(initialValue: profile.nickname ?? "")
    }

    private var store: UsageStore? { registry.store(for: profile.id) }
    private var inBar: Bool { profile.enabled && profile.showInMenuBar }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            identity
            LabeledContent("Nickname") {
                // Seeded in init, committed on Return or when the field
                // gives up focus — never per keystroke: every commit
                // rewrites the profile list, tells the engine, and rebuilds
                // the faces, which is not a thing to do once per letter.
                TextField("Optional", text: $nickname)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .focused($editingNickname)
                    .onSubmit { commitNickname() }
                    .onChange(of: editingNickname) { _, focused in
                        if !focused { commitNickname() }
                    }
            }
            // Its own form only once the bar is set to draw each account
            // in its own (the Menu bar card's switch); under one form for
            // all, the row says so rather than offering a picker that
            // would not draw.
            if registry.barProfiles.count > 1 {
                if uniformForm {
                    LabeledContent("Menu bar") {
                        Text("Same form as every account — set under Menu bar")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Menu bar")
                        MenuBarFormPicker(
                            cell: MenuBarModelBuilder.sampleCell(for: profile, registry: registry),
                            selection: profile.menuBarForm,
                            onSelect: { registry.setMenuBarForm(id: profile.id, form: $0) })
                        // Its own elements, too (0.98.0): the arrangement
                        // follows the same switch as the form.
                        MenuBarElementPalette(
                            registry: registry, profile: profile, elements: profile.menuBarElements,
                            onChange: { registry.setMenuBarElements(id: profile.id, elements: $0) })
                    }
                    .opacity(inBar ? 1 : 0.45)
                    .disabled(!inBar)
                }
            }
            HStack(spacing: 16) {
                Toggle("Meter this account", isOn: Binding(
                    get: { profile.enabled },
                    set: { registry.setProfileEnabled(id: profile.id, enabled: $0) }))
                Toggle("Show in menu bar", isOn: Binding(
                    get: { profile.showInMenuBar },
                    set: { registry.setShowInMenuBar(id: profile.id, shown: $0) }))
                    .disabled(!profile.enabled)
                // Its own item only means something beside a shared one.
                if registry.barProfiles.count > 1 {
                    Toggle("Own menu bar item", isOn: Binding(
                        get: { profile.ownMenuBarItem },
                        set: { registry.setOwnMenuBarItem(id: profile.id, own: $0) }))
                        .disabled(!inBar)
                        .help("A separate menu bar item for this account — ⌘-drag it anywhere along the bar")
                }
                Spacer()
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            infoRow("Activity", stateLine)
        }
    }

    /// The account, named the way the strip names it, with what that name
    /// stands for beneath: the sign-in when a nickname covers it, the home
    /// otherwise.
    private var identity: some View {
        HStack(alignment: .center, spacing: 10) {
            MonogramTile(
                monogram: registry.monogram(for: profile),
                focused: profile.id == registry.focusedID, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(registry.label(for: profile))
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if profile.id == registry.focusedID {
                        Text("Focused")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }
                Text(secondaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !profile.isDefault {
                Button("Remove…") { confirmingRemove = true }
                    .controlSize(.small)
                    .confirmationDialog(
                        "Stop metering \(registry.label(for: profile))?",
                        isPresented: $confirmingRemove, titleVisibility: .visible
                    ) {
                        Button("Stop metering") { registry.remove(id: profile.id, deletingData: false) }
                        Button("Stop metering and delete its data", role: .destructive) {
                            registry.remove(id: profile.id, deletingData: true)
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(
                            "Removing forgets the account here. Its history and caches stay"
                                + " unless you delete them, and nothing inside"
                                + " \(profile.displayHome() ?? "the folder") is ever touched.")
                    }
            }
        }
    }

    /// The sign-in when a nickname stands in for it, then the home.
    private var secondaryLine: String {
        let home = profile.displayHome() ?? "—"
        if let email = store?.accountPresence?.current?.email, email != registry.label(for: profile) {
            return "\(email) · \(home)"
        }
        return home
    }

    private func commitNickname() {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = profile.nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed != stored else { return }
        registry.rename(id: profile.id, nickname: trimmed.isEmpty ? nil : trimmed)
    }

    private var stateLine: String {
        guard let store else { return "Not metered" }
        return UsageFormatting.profileStateLine(
            lastWrite: store.lastActivityAt,
            fetchedAt: store.state.snapshot?.fetchedAt, now: Date())
    }
}

/// A home discovery found beside the standard one, with the two answers:
/// meter it, or not now.
private struct DiscoveredAccountRow: View {
    var registry: ProviderRegistry
    let home: DiscoveredHome

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.folder")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(home.identity?.email ?? home.displayPath)
                        .font(.callout)
                    Text(home.displayPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Meter") { registry.enroll(home: home.home) }
                Button("Not now") { registry.dismissDiscovered(home) }
            }
            note(
                "Found on this Mac. Nothing has been read from it beyond the folder listing and its"
                    + " sign-in record — no credential, no usage.")
        }
    }
}

/// The bar as a whole (0.97.0): the live preview first — drag the accounts
/// into order — then the controls that are nobody's in particular. Which
/// form wins is a SWITCH, not a precedence rule to remember (0.97.1,
/// user-directed): "Same form for every account" on means the form here
/// draws; off means each account's own, set on its row.
struct MenuBarSettingsCard: View {
    var registry: ProviderRegistry
    @AppStorage(MenuBarPreferences.expandsFocusKey) private var expandsFocus = true
    @AppStorage(MenuBarPreferences.uniformKey) private var uniform = true
    @AppStorage(MenuBarPreferences.uniformFormKey) private var uniformFormRaw = MenuBarForm.standard.rawValue
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
            uniformElements: uniformElements)
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
                note("Each account draws in the form set on its own row under Accounts, with the elements added there.")
            }
            if several {
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
            return "With the focused account expanded, its numbers are spelled out whatever its"
                + " form — and focus decides which account the panel opens on. Following activity"
                + " picks the account this Mac has worked in most over the last two weeks; picking"
                + " an account in the panel pins it until Auto."
        }
        return "With the numbers spelled out the item is exactly what it has always been; turn that"
            + " off to draw your account in the form chosen above."
    }
}

/// How the panel presents several accounts.
struct PanelSettingsCard: View {
    var registry: ProviderRegistry
    @AppStorage(PanelAccountForm.key) private var formRaw = PanelAccountForm.standard.rawValue

    private var form: PanelAccountForm { PanelAccountForm(rawValue: formRaw) ?? .standard }

    var body: some View {
        if registry.shownProfiles.count > 1 {
            SettingsCard("Panel", footer: form.caption) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Accounts")
                    Spacer()
                    SegmentedPicker(
                        title: "Accounts", selection: $formRaw,
                        options: PanelAccountForm.allCases.map { ($0.title, $0.rawValue) },
                        size: .regular)
                }
            }
        }
    }
}
