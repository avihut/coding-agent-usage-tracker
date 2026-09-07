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

/// One metered account: who it is first, then its name and whether it is
/// metered, then what it has been doing. How it draws in the bar is the
/// Menu bar pane's; the paths it is read from are inventory, not settings,
/// and live in the privacy card.
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
            // How it draws in the bar lives under Settings → Menu bar
            // (0.98.1, user-directed: styling among the accounts was
            // confusing); here is only whether it is metered at all.
            HStack(spacing: 16) {
                Toggle("Meter this account", isOn: Binding(
                    get: { profile.enabled },
                    set: { registry.setProfileEnabled(id: profile.id, enabled: $0) }))
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
