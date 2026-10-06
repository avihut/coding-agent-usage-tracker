import AppKit
import SwiftUI
import UsageCore

@main
struct AgentUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // No windows — StatusItemController owns all UI. No Settings scene
        // either (v0.97.2, user-reported): SwiftUI bound ⌘, to it, and an
        // empty scene is an empty, dead window. ⌘, is a local key monitor
        // in the delegate and opens the real window.
        MenuBarExtra("", isInserted: .constant(false)) { EmptyView() }
            // The main menu exists while a window is open (DockPresence makes
            // the app `.regular`); the window is listed in its Window menu.
            // ⌘0 itself is the delegate's key monitor, which sees the key
            // first and also works from the panel, where no menu is.
            .commands {
                CommandGroup(before: .windowList) {
                    Button("\(AppIdentity.displayName)") { delegate.showMainWindow() }
                        .keyboardShortcut("0", modifiers: .command)
                    Divider()
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?
    private var settingsKeyMonitor: Any?
    /// Whether the person launched the app (Finder, Dock, Spotlight, `open`)
    /// rather than the system (a login item) or the updater — read off the
    /// launch's Apple event, which is gone by `didFinishLaunching`.
    private var launchedByPerson = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedByPerson = Self.isPersonLaunch(NSAppleEventManager.shared().currentAppleEvent)
    }

    /// A launch the person asked for arrives as an "open application" Apple
    /// event; a login item's carries the launched-as-login-item property,
    /// and a launch with no event at all (launchd, a direct exec — every
    /// hatch run) is nobody's request. The updater's relaunch is a person's
    /// `open` in shape, so it says `--relaunched`.
    private static func isPersonLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == kCoreEventClass, event.eventID == kAEOpenApplication
        else { return false }
        if event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return false
        }
        return !CommandLine.arguments.contains("--relaunched")
    }

    /// Opens (or fronts) the main window.
    func showMainWindow() {
        controller?.showMainWindow()
    }

    /// A Dock click, a Spotlight or Finder launch of the running app: the
    /// window, always — there is nothing else to reopen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showMainWindow()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? AppIdentity.bundleID
        // Before anything opens a file or reads a setting: an install that
        // was ClaudeUsage (through 0.101.0) carries its data and settings
        // over to this identity, once. A copy of the old app still running
        // would go on hosting the engine against the old directories, so it
        // is asked to quit first — the one AppKit piece of the migration.
        if IdentityMigration.isPending(defaults: .standard) {
            let old = NSRunningApplication.runningApplications(
                withBundleIdentifier: AppIdentity.legacyBundleID)
            old.forEach { $0.terminate() }
            let deadline = Date().addingTimeInterval(3)
            while old.contains(where: { !$0.isTerminated }), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            IdentityMigration.standard(defaults: .standard)
        }
        // Older layouts step forward before any store opens a file:
        // pre-registry singletons into the claude scope (v1), and every
        // provider's per-account artifacts into its default profile (v3).
        StorageMigration.standard(
            bundleID: bundleID,
            providerIDs: HarnessResolution.standardProviders().map(\.id))
        // The registry meters every harness found on this Mac and installs
        // the union model catalog before any UI renders.
        // `--demo-digest <live-state.json>` renders every face from that
        // file and nothing else (scripts/demo-digest.py writes a synthetic
        // one) — how the README's pictures show nobody's real usage. Its
        // own storage scope keeps this Mac's history out of the charts.
        let demo = Self.launchDemoDigest()
        let registry = ProviderRegistry(
            bundleID: demo == nil ? bundleID : bundleID + ".demo", demo: demo)
        controller = StatusItemController(registry: registry)
        // ⌘, wherever this app is key — the panel, a hosted window. A
        // LOCAL monitor rather than a main-menu item: SwiftUI owns that
        // menu and rebuilds it on its own schedule (an item inserted at
        // launch or on activation never survived to be seen), and the
        // monitor sees the key equivalent before the menu would anyway.
        // ⌘0 the same way, for the main window.
        settingsKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            else { return event }
            switch event.charactersIgnoringModifiers {
            case ",": self?.controller?.showSettings()
            case "0": self?.controller?.showMainWindow()
            default: return event
            }
            return nil
        }
        // Touch the updater so its init sweeps a previous update's aside
        // bundle — lazily it would only wake when the NEXT release's chip
        // renders, leaving a hidden stale app copy beside this one.
        _ = AppUpdater.shared
        // A real outage can't be scheduled, so the status surfaces get their
        // own hatch: `--fake-status <minor|major|critical|maintenance|
        // unknown|resolved|none>` installs a synthetic card carrying real
        // incident copy, and every surface renders it exactly as it would
        // render the live one.
        if let fake = Self.launchFakeStatus() {
            registry.activeStore.installFakeServiceStatus(fake)
        }
        // The updater's own hatch: `--fake-update <version|current>`
        // installs a synthetic release card so the chip, menu item, and
        // Settings card can be click-verified before the release they'd
        // announce exists. No asset URL rides along, so a click on the fake
        // opens the releases page instead of swapping anything.
        if let fake = Self.launchFakeUpdate() {
            registry.activeStore.installFakeAppUpdate(fake)
        }
        // `--fake-channel <release|source>` forces the distribution
        // flavor's presentation, so both update bodies (one-click install
        // vs pull-and-rebuild) can be click-verified on one machine —
        // whichever flavor that machine actually is.
        if let fake = Self.launchFakeChannel() {
            registry.activeStore.installFakeDistribution(fake)
        }
        // `--fake-accounts` installs a two-account presence card: the D9
        // two-line status row, the Settings account rows, and the session
        // labels auto-show only once a SECOND identity has been observed,
        // which a single-account machine can't produce on demand.
        if let fake = Self.launchFakeAccounts() {
            registry.activeStore.installFakeAccountPresence(fake)
        }
        // `--fake-notices <morning|live>` installs a synthetic notices card:
        // `morning` is the wake-up shape (yesterday's vendor reset plus an
        // overnight outage that ended before anyone looked — menu bar dot,
        // both rows dismissable); `live` is a running outage seen an hour
        // in plus the reset (pair it with `--fake-status major` to see the
        // capsule and the dot together). Dismissing edits the fake in place.
        if let fake = Self.launchFakeNotices() {
            registry.activeStore.installFakeNotices(fake.card, outages: fake.outages)
        }
        // `--fake-bar <light|dark>` forces the ground the status item is
        // inked for (read by StatusItemController) — the other wallpaper
        // can't be summoned on demand.
        // `--fake-profiles` installs a second, synthetic account ("Work",
        // S 42% and a watched W 80%, no scoped meter) as a fixed-digest
        // face, so the account strip, the menu bar cells and the Accounts
        // settings card can be verified on a machine with one real
        // account. It borrows the live digest for everything else, so the
        // charts and sessions below the meters stay realistic.
        if CommandLine.arguments.contains("--fake-profiles") {
            Self.installFakeProfile(into: registry)
        }
        // `--fake-harnesses` meters a SECOND vendor beside the real one, so
        // the harness blocks in the bar and the strip's headings can be
        // verified on a Mac where only one agent is installed.
        if CommandLine.arguments.contains("--fake-harnesses") {
            Self.installFakeHarness(into: registry)
        }
        // Verification hatches: `AgentUsage --settings [--pane-cost]` /
        // `--panel` open UI straight away (the ⋯ menu can't be scripted,
        // and AX row selection can't drive the sidebar).
        if CommandLine.arguments.contains("--settings") {
            controller?.showSettings(
                pane: CommandLine.arguments.contains("--pane-cost") ? .apiCost
                    : CommandLine.arguments.contains("--pane-accounts") ? .accounts
                    : CommandLine.arguments.contains("--pane-menubar") ? .menuBar : .general)
        } else if CommandLine.arguments.contains("--panel") {
            controller?.showPanel()
        } else if CommandLine.arguments.contains("--sessions") {
            controller?.showSessions()
        } else if CommandLine.arguments.contains("--main-window") {
            // `--main-window [--select home|<account key>]`.
            controller?.showMainWindow(selecting: Self.launchArgument(after: "--select"))
        } else if launchedByPerson, demo == nil {
            // Launched by the person, not at login: they came for the window.
            controller?.showMainWindow()
        }
        // `--snapshot <dir>` renders the Notifications section, the weekly
        // meter card and (while an incident is open) the menu bar's hover
        // card headlessly to PNGs and quits — the harness's eyes when the live
        // popover can't be caught (any real click dismisses it, and a user
        // at the machine is always clicking). NSViewRepresentable pieces
        // (swipe catchers) render blank; everything SwiftUI renders as is.
        if let directory = Self.launchSnapshotDirectory() {
            Task { @MainActor in
                // Let the digest, the scan and the first layout land.
                try? await Task.sleep(for: .seconds(3))
                // The panel is staged first and written a beat later: a
                // hosted SwiftUI tree lays out and draws its charts over
                // the next few turns of the run loop, not on insertion.
                let panels = Self.stagePanelSnapshots(registry: registry)
                try? await Task.sleep(for: .seconds(1))
                Self.fitPanelSnapshots(panels)
                try? await Task.sleep(for: .seconds(1))
                Self.writePanelSnapshots(panels, to: directory)
                let pages = Self.stageMainWindowSnapshots(registry: registry)
                try? await Task.sleep(for: .seconds(1))
                Self.fitPanelSnapshots(pages)
                try? await Task.sleep(for: .seconds(1))
                Self.writePanelSnapshots(pages, to: directory)
                let frames = Self.stageMainWindowFrames(registry: registry)
                try? await Task.sleep(for: .seconds(2))
                Self.writeWindowFrames(frames, to: directory)
                Self.writeSnapshots(registry: registry, to: directory)
                NSApp.terminate(nil)
            }
        }
    }

    private static func launchArgument(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    private static func launchSnapshotDirectory() -> URL? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--snapshot"),
              arguments.indices.contains(flag + 1)
        else { return nil }
        return URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
    }
}
