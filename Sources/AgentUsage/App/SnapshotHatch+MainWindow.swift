import AppKit
import SwiftUI
import UsageCore

/// The main window's half of the `--snapshot <dir>` hatch, drawn the way the
/// panel is — the real view hosted in a window parked off every screen,
/// through AppKit's `cacheDisplay`:
///
/// - `main-home-<width>-<theme>.png` and `main-account-<key>-<width>-<theme>
///   .png`: a page's CONTENT (without its scroll view, which renders blank
///   off-screen) at detail-column widths that make one, two and three
///   columns of the flow — the page reflows, so one width proves nothing;
/// - `main-window-<page>-<width>-<theme>.png`: the whole window, chrome
///   included (see `stageMainWindowFrames`).
@MainActor
extension AppDelegate {
    /// Detail-column widths for one, two and three columns of the flow.
    static let mainWindowPageWidths: [CGFloat] = [400, 800, 1200]

    static func stageMainWindowSnapshots(registry: ProviderRegistry) -> [(name: String, window: NSWindow)] {
        var staged: [(name: String, window: NSWindow)] = []
        for width in mainWindowPageWidths {
            let home = HomePageContent(
                registry: registry, activityFocus: .constant(nil),
                onOpenAccount: { _, _ in }, onOpenSessions: { _, _ in })
                .padding(16)
            staged += stage(home, named: "main-home-\(Int(width))", width: width)
        }
        for profile in registry.shownProfiles {
            guard let store = registry.store(for: profile.key) else { continue }
            let page = AccountPageContent(
                registry: registry, profile: profile, store: store,
                chosenMeterID: .constant(nil), activityFocus: .constant(nil),
                flowWidth: 800 - 2 * AccountPageContent.margin,
                onOpenSessions: {}, onOpenSession: { _ in })
                .padding(AccountPageContent.margin)
            staged += stage(page, named: "main-account-\(profile.key)-800", width: 800)
        }
        return staged
    }

    /// The whole window, chrome included: a titled window parked off every
    /// screen, its frame view (title bar, toolbar, sidebar) drawn as the
    /// page is. Home narrow, default and wide; the first account's page at
    /// the default size. Dark, and Home's default in light too.
    static func stageMainWindowFrames(registry: ProviderRegistry) -> [(name: String, window: NSWindow)] {
        let home = MainWindowView.homeSelection
        var pages: [(file: String, selection: String, size: NSSize, appearance: NSAppearance.Name)] = [
            ("main-window-home-700-dark.png", home, NSSize(width: 700, height: 760), .darkAqua),
            ("main-window-home-1100-dark.png", home, NSSize(width: 1100, height: 720), .darkAqua),
            ("main-window-home-1100-light.png", home, NSSize(width: 1100, height: 720), .aqua),
            ("main-window-home-1600-dark.png", home, NSSize(width: 1600, height: 900), .darkAqua),
        ]
        if let first = registry.shownProfiles.first {
            pages.append(("main-window-account-1100-dark.png", first.key, NSSize(width: 1100, height: 720), .darkAqua))
            // Laid out wide first, narrowed before it is drawn: a chart that
            // held its tile open after the window narrowed clipped off the
            // window's edge, and a page drawn fresh at one width can't show it.
            pages.append((Self.narrowedFrameName, first.key, NSSize(width: 1600, height: 900), .darkAqua))
        }
        return pages.map { file, selection, size, appearance in
            let host = NSHostingController(
                rootView: MainWindowView(
                    registry: registry, navigator: MainWindowNavigator(),
                    onOpenSessions: { _, _ in }, onOpenSettings: {}, fixedSelection: selection))
            host.sceneBridgingOptions = [.title, .toolbars]
            host.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: host)
            window.title = selection == home
                ? "Home"
                : registry.shownProfiles.first { $0.key == selection }
                    .map { registry.rowTitle(for: $0).title } ?? ""
            window.isReleasedWhenClosed = false
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.appearance = NSAppearance(named: appearance)
            window.setFrame(NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size), display: false)
            window.orderFrontRegardless()
            return (file, window)
        }
    }

    static let narrowedFrameName = "main-window-account-1600to1100-dark.png"

    /// The narrowing half of `narrowedFrameName`, a beat after staging.
    static func narrowMainWindowFrames(_ frames: [(name: String, window: NSWindow)]) {
        for (name, window) in frames where name == narrowedFrameName {
            var frame = window.frame
            frame.size = NSSize(width: 1100, height: 720)
            window.setFrame(frame, display: true)
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

    /// Once laid out: each page's window cut to the height its content takes
    /// at its width.
    static func fitPageSnapshots(_ pages: [(name: String, window: NSWindow)]) {
        for (_, window) in pages {
            guard let host = window.contentViewController as? NSHostingController<AnyView> else { continue }
            let width = window.frame.width
            let fitting = host.sizeThatFits(in: CGSize(width: width, height: 10_000))
            window.setContentSize(NSSize(width: width, height: ceil(fitting.height)))
        }
    }

    /// `view` at `width`, sized to its own height, in both appearances.
    static func stage(_ view: some View, named name: String, width: CGFloat) -> [(name: String, window: NSWindow)] {
        [("\(name)-dark.png", NSAppearance.Name.darkAqua), ("\(name)-light.png", .aqua)].map { file, appearance in
            let host = NSHostingController(
                rootView: AnyView(view
                    .frame(width: width, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor))))
            // Not sized by its content, as the panel's stage is: a window
            // that animates to a hosted meter card's size overflows the main
            // thread's stack in Auto Layout (macOS 26 SDK). Laid out tall,
            // then cut to the measured height (`fitPageSnapshots`).
            host.sizingOptions = []
            let window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 4000),
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
}
