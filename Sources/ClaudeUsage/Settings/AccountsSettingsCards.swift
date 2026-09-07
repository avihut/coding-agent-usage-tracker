import AppKit
import SwiftUI
import UsageCore

/// The Accounts card (0.96.0): every home this app meters for the active
/// agent, what each one is signed in as, and the two switches that decide
/// whether it is metered at all and whether it takes a menu bar cell. Plus
/// the homes discovery found and nobody has decided about.
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
                    + " you meter it."
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

/// One metered account: identity, home, where its credential is read from,
/// its state — and the switches.
private struct AccountRow: View {
    var registry: ProviderRegistry
    let profile: Profile

    @State private var nickname: String
    @State private var confirmingRemove = false
    @FocusState private var editingNickname: Bool

    init(registry: ProviderRegistry, profile: Profile) {
        self.registry = registry
        self.profile = profile
        _nickname = State(initialValue: profile.nickname ?? "")
    }

    private var store: UsageStore? { registry.store(for: profile.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                MonogramTile(
                    monogram: registry.monogram(for: profile),
                    focused: profile.id == registry.focusedID)
                // Seeded in init, committed on Return or when the field
                // gives up focus — never per keystroke: every commit
                // rewrites the profile list, tells the engine, and rebuilds
                // the faces, which is not a thing to do once per letter.
                TextField("Nickname", text: $nickname)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    .focused($editingNickname)
                    .onSubmit { commitNickname() }
                    .onChange(of: editingNickname) { _, focused in
                        if !focused { commitNickname() }
                    }
                Text(registry.label(for: profile))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            HStack(spacing: 16) {
                Toggle("Metered", isOn: Binding(
                    get: { profile.enabled },
                    set: { registry.setProfileEnabled(id: profile.id, enabled: $0) }))
                Toggle("Show in menu bar", isOn: Binding(
                    get: { profile.showInMenuBar },
                    set: { registry.setShowInMenuBar(id: profile.id, shown: $0) }))
                    .disabled(!profile.enabled)
                Spacer()
                if !profile.isDefault {
                    Button("Remove…") { confirmingRemove = true }
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
            .toggleStyle(.switch)
            .controlSize(.small)
            infoRow("Home", profile.displayHome() ?? "—")
            if let credentials = credentialLine { infoRow("Credential", credentials) }
            if let identity = registry.provider(for: profile).accountIdentity {
                infoRow("Account identity", "\(identity.displayPath) (read-only)")
            }
            infoRow("State", stateLine)
        }
    }

    private func commitNickname() {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = profile.nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed != stored else { return }
        registry.rename(id: profile.id, nickname: trimmed.isEmpty ? nil : trimmed)
    }

    /// The chain in order, in the sources' own words — the file it looks
    /// for and the keychain item it falls back to. Named here so the
    /// privacy inventory stays complete per account.
    private var credentialLine: String? {
        let names = registry.provider(for: profile).credentials.sources.map(\.name)
        return names.isEmpty ? nil : names.joined(separator: " → ")
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

/// How the menu bar presents several accounts, and which one it expands.
struct MenuBarSettingsCard: View {
    var registry: ProviderRegistry
    @AppStorage(MenuBarStyle.key) private var styleRaw = MenuBarStyle.standard.rawValue

    private var style: MenuBarStyle { MenuBarStyle(rawValue: styleRaw) ?? .standard }

    var body: some View {
        if registry.shownProfiles.count > 1 {
            SettingsCard("Menu bar", footer: style.caption) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Style")
                    Spacer()
                    Picker("Style", selection: $styleRaw) {
                        ForEach(MenuBarStyle.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
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
                note(
                    "Focus decides whose numbers the bar spells out and which account the panel"
                        + " opens on. Following activity picks the account this Mac has worked in"
                        + " most over the last two weeks.")
            }
        }
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
