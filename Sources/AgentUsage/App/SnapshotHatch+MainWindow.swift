import AppKit
import SwiftUI
import UsageCore

/// The main window's half of the `--snapshot <dir>` hatch: every shown
/// account's page as `main-account-<key>-dark.png` / `-light.png`, drawn the
/// way the panel is — the real view hosted in a window parked off every
/// screen, through AppKit's `cacheDisplay`. The page's CONTENT is drawn,
/// without its scroll view (rendered blank off-screen) and without the
/// window's chrome (a borderless window has no toolbar); `mise run axdump`
/// against a `--main-window` demo is how the chrome is checked.
@MainActor
extension AppDelegate {
    /// The detail column's width at the window's default size.
    static let mainWindowDetailWidth: CGFloat = 880

    static func stageMainWindowSnapshots(registry: ProviderRegistry) -> [(name: String, window: NSWindow)] {
        var staged: [(name: String, window: NSWindow)] = []
        for profile in registry.shownProfiles {
            guard let store = registry.store(for: profile.key) else { continue }
            let page = AccountPageContent(
                registry: registry, profile: profile, store: store,
                chosenMeterID: .constant(nil), activityFocus: .constant(nil),
                onOpenSessions: {}, onOpenSession: { _ in })
                .padding(20)
            staged += stage(page, named: "main-account-\(profile.key)")
        }
        return staged
    }

    /// The whole window, chrome included: a titled window parked off every
    /// screen, its frame view (title bar, toolbar, sidebar) drawn as the
    /// page is: Home in both themes, the first account's page in dark.
    static func stageMainWindowFrames(registry: ProviderRegistry) -> [(name: String, window: NSWindow)] {
        var pages: [(file: String, selection: String, appearance: NSAppearance.Name)] = [
            ("main-window-home-dark.png", MainWindowView.homeSelection, .darkAqua),
            ("main-window-home-light.png", MainWindowView.homeSelection, .aqua),
        ]
        if let first = registry.shownProfiles.first {
            pages.append(("main-window-account-dark.png", first.key, .darkAqua))
        }
        return pages.map { file, selection, appearance in
            let host = NSHostingController(
                rootView: MainWindowView(
                    registry: registry, navigator: MainWindowNavigator(),
                    onOpenSessions: { _, _ in }, onOpenSettings: {}, fixedSelection: selection))
            host.sceneBridgingOptions = [.title, .toolbars]
            host.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: host)
            host.rootView.onTitle = { [weak window] in window?.title = $0 }
            window.isReleasedWhenClosed = false
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.appearance = NSAppearance(named: appearance)
            window.setFrame(NSRect(x: -20_000, y: -20_000, width: 1100, height: 720), display: false)
            window.orderFrontRegardless()
            return (file, window)
        }
    }

    /// `view` at the detail column's width, in both appearances.
    static func stage(_ view: some View, named name: String) -> [(name: String, window: NSWindow)] {
        [("\(name)-dark.png", NSAppearance.Name.darkAqua), ("\(name)-light.png", .aqua)].map { file, appearance in
            let host = NSHostingController(
                rootView: view
                    .frame(width: mainWindowDetailWidth, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor)))
            host.sizingOptions = .preferredContentSize
            let window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: mainWindowDetailWidth, height: 800),
                styleMask: .borderless, backing: .buffered, defer: false)
            // The array owns it: a released-when-closed window would be
            // freed twice once `writePanelSnapshots` closes it.
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentViewController = host
            window.orderFrontRegardless()
            return (file, window)
        }
    }

    static func writeWindowFrames(_ frames: [(name: String, window: NSWindow)], to directory: URL) {
        for (name, window) in frames {
            guard let frameView = window.contentView?.superview,
                  let rep = retinaBitmap(of: frameView)
            else { continue }
            try? rep.representation(using: .png, properties: [:])?
                .write(to: directory.appending(path: name))
            window.close()
        }
    }
}
