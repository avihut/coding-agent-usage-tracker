import SwiftUI
import UsageCore

/// The main window: the panel's account strip as a sidebar (Home, then the
/// accounts grouped by harness), and the page for what is selected in it.
///
/// Selecting in the sidebar never moves the menu bar's focus — that stays an
/// explicit act (the toolbar's Focus menu, a row's context menu) — so
/// browsing accounts here can't change what the bar shows.
struct MainWindowView: View {
    var registry: ProviderRegistry
    let navigator: MainWindowNavigator
    /// Opens the Sessions window for an account (nil = the focused one),
    /// landed on a session when one is named.
    let onOpenSessions: (_ profileKey: String?, _ sessionID: String?) -> Void
    let onOpenSettings: () -> Void

    static let homeSelection = "home"
    /// The `--snapshot` hatch's page: shown regardless of (and without
    /// writing) the stored selection.
    var fixedSelection: String?
    /// The page's name for the window's title. `.navigationTitle` bridges
    /// the subtitle from a hosting controller but leaves the title
    /// "Untitled" (macOS 26), so the controller sets it from here.
    var onTitle: (String) -> Void = { _ in }

    /// `homeSelection` or an account's `ProfileKey`. A key that no longer
    /// resolves lands on Home (or the lone account).
    @AppStorage("mainWindowSelection") private var selectionRaw = MainWindowView.homeSelection
    @State private var columns: NavigationSplitViewVisibility = .all
    /// Each account page's chosen meter, for the life of the window.
    @State private var chosenMeters: [String: String] = [:]
    /// The account page's activity navigation; reset with the page.
    @State private var activityFocus: DateInterval?
    @State private var showRefreshBlocked = false

    private var profiles: [Profile] { registry.shownProfiles }

    /// What the window shows: one account on a one-account Mac (Home and its
    /// page would be the same thing), else the stored choice if it resolves.
    private var selection: String {
        if let fixedSelection { return fixedSelection }
        if profiles.count == 1, let lone = profiles.first { return lone.key }
        if profiles.contains(where: { $0.key == selectionRaw }) { return selectionRaw }
        return Self.homeSelection
    }

    private var selectedProfile: Profile? {
        profiles.first { $0.key == selection }
    }

    /// The account the toolbar and the status bar answer for: the page's,
    /// or on Home the one focused in the menu bar.
    private var shownStore: UsageStore {
        selectedProfile.flatMap { registry.store(for: $0.key) } ?? registry.focusedStore
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            MainSidebar(
                registry: registry,
                selection: Binding(
                    get: { selection },
                    set: { if let key = $0 { selectionRaw = key } }),
                onOpenSettings: onOpenSettings)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            detail
                .toolbar { toolbar }
                // On the detail column: the split view's own title wins
                // over one set outside it (the window read "Untitled").
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
        }
        .onChange(of: title, initial: true) { _, title in onTitle(title) }
        .onAppear {
            applyRequest()
            // A lone account needs no sidebar: Home and its page coincide.
            if profiles.count <= 1 { columns = .detailOnly }
        }
        .onChange(of: navigator.requested) { applyRequest() }
        .onChange(of: selection) { _, _ in
            activityFocus = nil
            showRefreshBlocked = false
        }
    }

    private func applyRequest() {
        guard let requested = navigator.requested else { return }
        selectionRaw = requested
        navigator.requested = nil
    }

    @ViewBuilder private var detail: some View {
        if let profile = selectedProfile, let store = registry.store(for: profile.key) {
            AccountPage(
                registry: registry, profile: profile, store: store,
                chosenMeterID: Binding(
                    get: { chosenMeters[profile.key] },
                    set: { chosenMeters[profile.key] = $0 }),
                activityFocus: $activityFocus,
                onOpenSessions: { onOpenSessions(profile.key, nil) },
                onOpenSession: { onOpenSessions(profile.key, $0) })
                .id(profile.key)
        } else {
            HomePage(
                registry: registry, activityFocus: $activityFocus,
                onOpenAccount: { key, meterID in
                    if let meterID { chosenMeters[key] = meterID }
                    selectionRaw = key
                },
                onOpenSessions: onOpenSessions)
        }
    }

    // MARK: - Title

    private var title: String {
        guard let profile = selectedProfile else { return "Home" }
        return registry.rowTitle(for: profile).title
    }

    /// "<agent> · <sign-in>" under an account's own name; the
    /// sign-in alone under an agent's; the account count on Home.
    private var subtitle: String {
        guard let profile = selectedProfile else {
            return profiles.count == 1 ? "1 account" : "\(profiles.count) accounts"
        }
        let row = registry.rowTitle(for: profile)
        let agent = registry.provider(for: profile).agentName
        let signIn = registry.store(for: profile.key)?.accountPresence?.current?.label
        return [row.title == agent ? nil : agent, row.detail ?? signIn]
            .compactMap { $0 }
            .filter { $0 != row.title }
            .joined(separator: " · ")
    }

    // MARK: - Toolbar

    /// Three groups, each its own glass platter: the sidebar toggle at the
    /// leading edge; then Refresh, the page's one frequent act; the ways
    /// out of the window (Sessions, the vendor's usage page); and the menu
    /// bar's pin, the one control that changes something outside it.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if profiles.count > 1 {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
                } label: {
                    Label("Sidebar", systemImage: "sidebar.left")
                }
                .help(columns == .detailOnly ? "Show the sidebar" : "Hide the sidebar")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            RefreshButton(store: shownStore, showBlocked: $showRefreshBlocked, tintsWhenCalm: false)
                .keyboardShortcut("r", modifiers: .command)
        }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if shownStore.providesSessions {
                Button {
                    onOpenSessions(shownStore.profile.key, nil)
                } label: {
                    Label("Sessions", systemImage: "list.bullet.rectangle")
                }
                .keyboardShortcut("1", modifiers: .command)
                .help("Browse this account's sessions (⌘1)")
            }
            if let usage = shownStore.provider.links.usageSettings {
                // A Button, not a Link: a toolbar item keeps the toolbar's
                // ink, where a Link draws in the link color.
                Button {
                    NSWorkspace.shared.open(usage)
                } label: {
                    Label("Usage", systemImage: "arrow.up.right.square")
                }
                .help("Open \(usage.host() ?? shownStore.provider.serviceName) usage settings")
            }
        }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            MenuBarPin(registry: registry, pageProfile: selectedProfile)
        }
    }
}

/// Which account the menu bar shows, said and changed from the toolbar —
/// the window's one way to move focus, so browsing pages never does. On an
/// account page it is a split button: the pin itself pins THIS account (or
/// hands the bar back to activity when it already holds it), the arrow
/// lists the rest. On Home it is the list alone.
struct MenuBarPin: View {
    var registry: ProviderRegistry
    /// The account page's account; nil on Home.
    let pageProfile: Profile?

    private var pinnedHere: Bool {
        guard let pageProfile else { return false }
        return registry.pinnedID == pageProfile.key
    }

    var body: some View {
        if let pageProfile {
            Menu {
                choices
            } label: {
                Label(pinnedHere ? "Pinned to the Menu Bar" : "Pin to the Menu Bar",
                      systemImage: pinnedHere ? "pin.fill" : "pin")
            } primaryAction: {
                if pinnedHere { registry.pin(nil) } else { registry.focus(pageProfile.key) }
            }
            .help(pinnedHere
                ? "The menu bar shows this account — click to follow activity again"
                : "Show this account in the menu bar")
        } else {
            Menu {
                choices
            } label: {
                Label("Menu Bar", systemImage: registry.pinnedID == nil ? "pin" : "pin.fill")
            }
            .help(summary)
        }
    }

    @ViewBuilder private var choices: some View {
        Toggle("Follow Activity", isOn: Binding(
            get: { registry.pinnedID == nil },
            set: { if $0 { registry.pin(nil) } }))
        Divider()
        ForEach(registry.shownProfiles, id: \.key) { profile in
            Toggle(registry.qualifiedLabel(for: profile), isOn: Binding(
                get: { registry.pinnedID == profile.key },
                set: { if $0 { registry.focus(profile.key) } else { registry.pin(nil) } }))
        }
    }

    private var summary: String {
        guard let focused = registry.focusedProfile else { return "Menu bar" }
        let name = registry.rowTitle(for: focused).title
        return registry.pinnedID == nil
            ? "The menu bar follows activity — now \(name)"
            : "The menu bar is pinned to \(name)"
    }
}
