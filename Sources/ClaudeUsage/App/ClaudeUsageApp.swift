import AppKit
import SwiftUI
import UsageCore

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // No windows — StatusItemController owns all UI. No Settings scene
        // either (v0.97.2, user-reported): SwiftUI bound ⌘, to it, and an
        // empty scene is an empty, dead window. ⌘, is a local key monitor
        // in the delegate and opens the real window.
        MenuBarExtra("", isInserted: .constant(false)) { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?
    private var settingsKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.avihu.ClaudeUsage"
        // Older layouts step forward before any store opens a file:
        // pre-registry singletons into the claude scope (v1), and every
        // provider's per-account artifacts into its default profile (v3).
        StorageMigration.standard(
            bundleID: bundleID,
            providerIDs: HarnessResolution.standardProviders().map(\.id))
        // The registry chooses the vendor (detection or the user's Metering
        // pick) and installs its model catalog before any UI renders.
        let registry = ProviderRegistry(
            bundleID: bundleID, launchOverride: Self.launchProviderOverride())
        controller = StatusItemController(registry: registry)
        // ⌘, wherever this app is key — the panel, a hosted window. A
        // LOCAL monitor rather than a main-menu item: SwiftUI owns that
        // menu and rebuilds it on its own schedule (an item inserted at
        // launch or on activation never survived to be seen), and the
        // monitor sees the key equivalent before the menu would anyway.
        settingsKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == ","
            else { return event }
            self?.controller?.showSettings()
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
        // `--fake-profiles` installs a second, synthetic account ("Work",
        // S 42% and a watched W 80%, no scoped meter) as a fixed-digest
        // face, so the account strip, the menu bar cells and the Accounts
        // settings card can be verified on a machine with one real
        // account. It borrows the live digest for everything else, so the
        // charts and sessions below the meters stay realistic.
        if CommandLine.arguments.contains("--fake-profiles") {
            Self.installFakeProfile(into: registry)
        }
        // Verification hatches: `ClaudeUsage --settings [--pane-cost]` /
        // `--panel` open UI straight away (the ⋯ menu can't be scripted,
        // and AX row selection can't drive the sidebar); `--provider <id>`
        // forces a harness for this launch without persisting the choice.
        if CommandLine.arguments.contains("--settings") {
            controller?.showSettings(
                pane: CommandLine.arguments.contains("--pane-cost") ? .apiCost
                    : CommandLine.arguments.contains("--pane-accounts") ? .accounts : .general)
        } else if CommandLine.arguments.contains("--panel") {
            controller?.showPanel()
        } else if CommandLine.arguments.contains("--sessions") {
            controller?.showSessions()
        }
        // `--snapshot <dir>` renders the Notifications section and the
        // weekly meter card headlessly to PNGs and quits — the harness's eyes when the live
        // popover can't be caught (any real click dismisses it, and a user
        // at the machine is always clicking). NSViewRepresentable pieces
        // (swipe catchers) render blank; everything SwiftUI renders as is.
        if let directory = Self.launchSnapshotDirectory() {
            Task { @MainActor in
                // Let the digest, the scan and the first layout land.
                try? await Task.sleep(for: .seconds(3))
                Self.writeSnapshots(registry: registry, to: directory)
                NSApp.terminate(nil)
            }
        }
    }

    private static func launchSnapshotDirectory() -> URL? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--snapshot"),
              arguments.indices.contains(flag + 1)
        else { return nil }
        return URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
    }

    private static func writeSnapshots(registry: ProviderRegistry, to directory: URL) {
        let store = registry.focusedStore
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writeStatusItemSnapshots(to: directory)
        func write(_ renderer: ImageRenderer<some View>, _ name: String) {
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { return }
            try? png.write(to: directory.appending(path: name))
        }
        // The Notifications section on its own: ImageRenderer leaves a
        // ScrollView's content blank, so the panel can't be rendered whole.
        if let notices = store.notices, !notices.items.isEmpty {
            let section = NoticesSection(
                card: notices, onDismiss: { _ in }, onDismissAll: {},
                canOpen: { store.provider.noticeDestination(for: $0) != nil }, onOpen: { _ in })
            write(ImageRenderer(content: section.padding(14).frame(width: 360)), "notices.png")
        }
        // The account strip, both selector forms — the panel can't be
        // rendered whole (ImageRenderer leaves a ScrollView's content
        // blank), and with `--fake-profiles` this is the only way to see
        // the multi-account panel head on a one-account Mac.
        if registry.shownProfiles.count > 1 {
            for form in [PanelAccountForm.stripRows, .chips] {
                let strip = AccountStrip(
                    registry: registry, form: form, onToggleForm: {}, onFocus: { _ in })
                write(
                    ImageRenderer(content: strip.padding(14).frame(width: 360)),
                    form == .chips ? "strip-chips.png" : "strip.png")
            }
        }
        // The Menu bar card's live preview and one account's form picker —
        // the preview is an NSView (drawn by itself: ImageRenderer would
        // show a placeholder), the picker plain SwiftUI.
        let prefs = MenuBarPreferences.current()
        let preview = MenuBarPreviewView()
        preview.items = StatusItemRenderer.itemModels(
            for: MenuBarModelBuilder.model(registry: registry, prefs: prefs))
        preview.canDrag = registry.barProfiles.count > 1
        if let rep = preview.snapshot() {
            try? rep.representation(using: .png, properties: [:])?
                .write(to: directory.appending(path: "menubar-preview.png"))
        }
        let picker = MenuBarFormPicker(
            cell: MenuBarModelBuilder.sampleCell(for: registry.focusedProfile, registry: registry),
            selection: prefs.form(for: registry.focusedProfile), onSelect: { _ in })
        write(ImageRenderer(content: picker.padding(14).background(Color(nsColor: .windowBackgroundColor))), "form-picker.png")
        // The "Runs out" element (0.98.0) placed after the meters, three
        // ways: as the preview ghosts it on a quiet day, as the "as if"
        // switch dresses it, and the palette tile with its condition.
        let arranged = [MenuBarElement.meters, .runsOut(.earliest)]
        for (name, simulate) in [("menubar-preview-ghost.png", false), ("menubar-preview-forecast.png", true)] {
            let staged = MenuBarPreviewView()
            staged.items = StatusItemRenderer.itemModels(
                for: MenuBarModelBuilder.model(
                    registry: registry, prefs: prefs, elements: (nil, arranged),
                    simulate: simulate, ghosts: true))
            if let rep = staged.snapshot() {
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: directory.appending(path: name))
            }
        }
        let palette = MenuBarElementPalette(
            registry: registry, profile: registry.focusedProfile, elements: arranged, onChange: { _ in })
        write(
            ImageRenderer(content: palette.padding(14).frame(width: 520).background(Color(nsColor: .windowBackgroundColor))),
            "element-palette.png")
        // The weekly meter's card, lit at the first pending reset notice
        // exactly as a click on that notice would open it.
        if let meters = store.state.snapshot?.meters,
           let meter = meters.first(where: { $0.rank == 1 }) ?? meters.first {
            let reset = store.notices?.items.first { $0.kind == "reset" }?.occurredAt
            let card = MeterHistoryView(
                meter: meter, samples: store.samples, timeline: store.tokenTimeline,
                pricing: store.pricing, prediction: store.predictions[meter.label],
                outcomes: store.windowOutcomes, agentName: store.provider.agentName,
                providerID: store.provider.id, highlightReset: reset,
                outages: store.outages)
            write(ImageRenderer(content: card), "meter.png")
        }
        // The weekly meter's week-span audit chart — the other face of the
        // outage floor. This span rather than today's drill because a
        // resolved outage sits in the past week where it's visible, while
        // anything dated "today" may still be in the future at render time.
        if let meters = store.state.snapshot?.meters,
           let meter = meters.first(where: { $0.rank == 1 }) ?? meters.first,
           let window = meter.limitWindow {
            let now = Date()
            // A trailing window rather than a calendar week: it always holds
            // the fake's resolved outage (three days back) whatever weekday
            // the render lands on, and reaches a few hours past now so the
            // live now rule shows too.
            let span = DateInterval(
                start: now.addingTimeInterval(-5 * 86400), end: now.addingTimeInterval(6 * 3600))
            let chart = AuditWindowChart(
                model: AuditWindow.build(
                    domain: span, meterLabel: meter.label, window: window,
                    samples: store.samples, sessions: store.sessions,
                    outcomes: store.windowOutcomes, outages: store.outages, now: now),
                domain: span, window: window, accent: ProviderStyle.accentColor,
                timeline: store.tokenTimeline, plotHeight: 114)
            write(ImageRenderer(content: chart.padding(14).frame(width: 360)), "audit.png")
        }
    }

    /// The menu bar item over FIXED models — one PNG per dressing the
    /// renderer knows (plain digits, the ramp dot, the badge, stale, an
    /// incident capsule with the notice dot, no data) at 2× over a dark
    /// ground. Synthetic on purpose: a render of the live digits would
    /// differ between two runs on data alone, and these exist to be
    /// `cmp`-ed across renderer changes — the single-cell bar must stay
    /// byte-identical when the multi-account cells land.
    private static func writeStatusItemSnapshots(to directory: URL) {
        func segment(_ tag: String, _ percent: Int, _ level: DisplayLevel, _ severity: Double?) -> MenuBarSegment {
            MenuBarSegment(tag: tag, percent: percent, level: level, severity: severity)
        }
        let clean = [
            segment("S", 42, .normal, 0), segment("W", 80, .warning, 0.55), segment("F", 25, .normal, nil),
        ]
        let alarmed = [
            segment("S", 97, .critical, 0.9), segment("W", 80, .warning, 0.55), segment("F", 25, .normal, nil),
        ]
        let cases: [(String, StatusItemRenderer.Model)] = [
            ("clean", .init(segments: clean, stale: false, glyph: "✳︎")),
            ("badge", .init(segments: alarmed, stale: false, glyph: "✳︎")),
            ("stale", .init(segments: clean, stale: true, glyph: "✳︎")),
            ("incident", .init(segments: clean, stale: false, glyph: "✳︎", incident: .major, indicator: true)),
            ("empty", .init(segments: nil, stale: true, glyph: "✳︎")),
        ]
        // Two accounts, one per style: work quiet across all three meters,
        // personal with its weekly meter under watch and NO scoped meter
        // (the absent bar). Distinct numbers so a style's cells can be told
        // apart by eye; `clean`/`alarmed` above stay as they are, since the
        // single-cell PNGs are `cmp`-ed against the pre-0.96 baseline.
        let work = StatusItemRenderer.Cell(
            profileID: "default", monogram: "W",
            segments: [
                segment("S", 15, .normal, 0), segment("W", 19, .normal, 0),
                segment("F", 25, .normal, 0),
            ],
            stale: false, focused: true)
        let personal = StatusItemRenderer.Cell(
            profileID: "c982130e", monogram: "P",
            segments: [segment("S", 42, .normal, 0), segment("W", 80, .warning, 0.55)],
            stale: false, focused: false)
        let alarmedCell = StatusItemRenderer.Cell(
            profileID: "c982130e", monogram: "P", segments: alarmed, stale: false, focused: false)
        func dressed(_ cell: StatusItemRenderer.Cell, _ form: MenuBarForm, own: Bool = false) -> StatusItemRenderer.Cell {
            var copy = cell
            copy.form = form
            copy.ownItem = own
            return copy
        }
        var everyCase = cases
        // Every form on both cells with focus not expanded, then the
        // default arrangement (bars, focus expanded) and a mixed one.
        for form in MenuBarForm.allCases {
            everyCase.append((
                "form-\(form.rawValue)",
                StatusItemRenderer.Model(
                    glyph: "✳︎", cells: [dressed(work, form), dressed(personal, form)],
                    expandsFocus: false)))
        }
        everyCase.append((
            "expanded-focus", StatusItemRenderer.Model(glyph: "✳︎", cells: [work, personal])))
        everyCase.append((
            "mixed",
            StatusItemRenderer.Model(
                glyph: "✳︎", cells: [dressed(work, .digits), dressed(personal, .rings)],
                expandsFocus: false)))
        everyCase.append((
            "cells-badge",
            StatusItemRenderer.Model(glyph: "✳︎", cells: [work, alarmedCell], expandsFocus: false)))
        everyCase.append((
            "cells-stale",
            StatusItemRenderer.Model(glyph: "✳︎", cells: [
                StatusItemRenderer.Cell(
                    profileID: "default", monogram: "W", segments: clean, stale: true, focused: true),
                StatusItemRenderer.Cell(
                    profileID: "c982130e", monogram: "P", segments: nil, stale: true, focused: false),
            ], expandsFocus: false)))
        // The runs-out element (0.98.0): a crossing half an hour out, the
        // scoped meter days out, a spent session counting to its reset —
        // after the meters, before them, and every limit at once. The
        // clock is pinned so the PNGs are `cmp`-able.
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let crossing = [
            MenuBarSegment(
                tag: "S", percent: 82, level: .critical, severity: 1,
                exhaustsAt: clock.addingTimeInterval(31 * 60), resetsAt: clock.addingTimeInterval(2 * 3600)),
            segment("W", 80, .warning, 0.55),
            MenuBarSegment(
                tag: "F", percent: 61, level: .normal, severity: 1,
                exhaustsAt: clock.addingTimeInterval(2 * 86400 + 3 * 3600), resetsAt: clock.addingTimeInterval(5 * 86400)),
        ]
        let spent = [
            MenuBarSegment(
                tag: "S", percent: 100, level: .critical, severity: 1,
                exhaustsAt: clock.addingTimeInterval(-600), resetsAt: clock.addingTimeInterval(2 * 3600 + 10 * 60)),
            segment("W", 80, .warning, 0.55), segment("F", 25, .normal, nil),
        ]
        for (name, segments, elements) in [
            ("runsout", crossing, [MenuBarElement.meters, .runsOut(.earliest)]),
            ("runsout-before", crossing, [.runsOut(.earliest), .meters]),
            ("runsout-each", crossing, [.meters, .runsOut(.each)]),
            ("runsout-spent", spent, [.meters, .runsOut(.earliest)]),
            ("runsout-quiet", clean, [.meters, .runsOut(.earliest)]),
        ] {
            everyCase.append((name, StatusItemRenderer.Model(
                segments: segments, stale: false, glyph: "✳︎", elements: elements, now: clock)))
        }
        // The preview's ghost for a quiet element — the bar itself never
        // draws one, so a fixed case is the one way to see it.
        var ghosted = StatusItemRenderer.Model(
            segments: clean, stale: false, glyph: "✳︎", elements: [.meters, .runsOut(.earliest)], now: clock)
        ghosted.ghosts = true
        everyCase.append(("runsout-ghost", ghosted))
        everyCase.append((
            "runsout-cells",
            StatusItemRenderer.Model(
                glyph: "✳︎",
                cells: [
                    work,
                    StatusItemRenderer.Cell(
                        profileID: "c982130e", monogram: "P", segments: crossing, stale: false,
                        focused: false, form: .bars, elements: [.meters, .runsOut(.earliest)]),
                ],
                expandsFocus: true, now: clock)))
        everyCase.append((
            "cells-incident",
            StatusItemRenderer.Model(
                glyph: "✳︎", incident: .major, indicator: true, cells: [work, personal],
                expandsFocus: false)))
        // An account in its own item draws apart from the shared one —
        // render each item the way the controller will.
        let split = StatusItemRenderer.Model(
            glyph: "✳︎", incident: .major, indicator: true,
            cells: [work, dressed(personal, .rings, own: true)])
        for item in StatusItemRenderer.itemModels(for: split) {
            everyCase.append(("item-\(item.profileID ?? "shared")", item.model))
        }

        let height = NSStatusBar.system.thickness
        let ground = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        // The hit rectangles beside the pixels: a sidecar naming which
        // account each x-range belongs to, so a layout regression shows as
        // a diff rather than as a hover landing on the wrong card.
        var sidecar: [String] = []
        for (name, model) in everyCase {
            let bar = StatusItemRenderer.image(for: model, height: height)
            sidecar.append("\(name)  width \(Int(bar.size.width.rounded()))")
            for rect in StatusItemRenderer.cellRects(for: model, height: height) {
                sidecar.append(String(
                    format: "  %-10@ x %6.1f … %6.1f", rect.profileID ?? "(glyph)",
                    rect.rect.minX, rect.rect.maxX))
            }
            let padded = NSSize(width: ceil(bar.size.width) + 16, height: height + 8)
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(padded.width * 2), pixelsHigh: Int(padded.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { continue }
            rep.size = padded
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            ground.setFill()
            NSRect(origin: .zero, size: padded).fill()
            bar.draw(in: NSRect(x: 8, y: 4, width: bar.size.width, height: height))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?
                .write(to: directory.appending(path: "statusitem-\(name).png"))
        }
        try? sidecar.joined(separator: "\n").appending("\n")
            .write(to: directory.appending(path: "statusitem-cells.txt"), atomically: true, encoding: .utf8)
    }

    /// The synthetic second account. Its digest is the live one with two
    /// meters rewritten and the third dropped — the absent scoped bar is
    /// exactly the case a one-account Mac can't otherwise produce.
    private static func installFakeProfile(into registry: ProviderRegistry) {
        let url = LiveState.fileURL(bundleID: Bundle.main.bundleIdentifier ?? "com.avihu.ClaudeUsage")
        guard let data = try? Data(contentsOf: url),
              let live = try? LiveState.decoder().decode(LiveState.self, from: data)
        else { return }
        func rewrite(_ meter: LiveMeter, percent: Int, level: String, severity: Double?) -> LiveMeter {
            LiveMeter(
                id: meter.id, label: meter.label, tag: meter.tag, percent: percent, level: level,
                rank: meter.rank, rateWindowSeconds: meter.rateWindowSeconds,
                forcesWarning: meter.forcesWarning,
                risk: severity.flatMap { RiskRamp.color(severity: $0) },
                resetsAt: meter.resetsAt, limitWindow: meter.limitWindow,
                scopedModelName: meter.scopedModelName, resetCaption: meter.resetCaption,
                forecast: meter.forecast, series: meter.series, stretches: meter.stretches,
                modelSeries: meter.modelSeries)
        }
        var meters: [LiveMeter] = []
        if let session = live.meters.first(where: { $0.rank == 0 }) {
            meters.append(rewrite(session, percent: 42, level: "normal", severity: nil))
        }
        if let weekly = live.meters.first(where: { $0.rank == 1 }) {
            meters.append(rewrite(weekly, percent: 80, level: "warning", severity: 0.55))
        }
        let menuBar = meters.map { meter in
            SegmentStatus(
                tag: meter.tag, percent: meter.percent, level: meter.level,
                severity: meter.forecast?.severity, risk: meter.risk)
        }
        // The face reads its own SECTION out of the digest, so the fake
        // has to name itself — a digest with no profiles answers only for
        // `default`, and the fake would render as "no data yet".
        let section = ProfileState(
            id: "fake-work", providerID: live.engine.providerID, label: "Work", nickname: "Work",
            monogram: "W", enabled: true, isFocused: false, dormant: false,
            lastActivityAt: Date(), homeDisplayPath: "~/.claude-work",
            engine: live.engine, meters: meters, menuBar: menuBar, models: live.models,
            activity: live.activity, sessions: live.sessions, accountPresence: nil)
        let fake = LiveState(
            schemaVersion: live.schemaVersion, sessionsCap: live.sessionsCap,
            engine: live.engine, meters: meters,
            menuBar: menuBar,
            models: live.models, activity: live.activity, sessions: live.sessions,
            serviceStatus: live.serviceStatus, appUpdate: live.appUpdate,
            accountPresence: nil, notices: live.notices, outages: live.outages,
            focusedProfile: "fake-work", profiles: [section])
        let profile = Profile(
            id: "fake-work", providerID: registry.activeProvider.id,
            home: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude-work"),
            nickname: "Work", addedAt: Date())
        registry.installFakeProfile(
            profile,
            store: UsageStore(
                profile: profile, provider: registry.activeProvider,
                bundleID: Bundle.main.bundleIdentifier ?? "com.avihu.ClaudeUsage", fixed: fake))
    }

    private static func launchProviderOverride() -> String? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--provider"),
              arguments.indices.contains(flag + 1)
        else { return nil }
        return arguments[flag + 1]
    }

    /// Builds the `--fake-update` card: `current` renders the up-to-date
    /// Settings card, any version string renders the offer.
    private static func launchFakeUpdate() -> AppUpdateCard? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--fake-update"),
              arguments.indices.contains(flag + 1)
        else { return nil }
        let version = arguments[flag + 1]
        let now = Date()
        if version == "current" {
            return AppUpdateCard(
                latestVersion: AppIdentity.version,
                url: "\(AppIdentity.releasesPage)/tag/v\(AppIdentity.version)",
                publishedAt: now.addingTimeInterval(-86_400), assetName: nil,
                assetURL: nil, assetBytes: nil, checkedAt: now.addingTimeInterval(-120),
                updateAvailable: false)
        }
        return AppUpdateCard(
            latestVersion: version,
            url: "\(AppIdentity.releasesPage)/tag/v\(version)",
            publishedAt: now.addingTimeInterval(-3_600), assetName: nil,
            assetURL: nil, assetBytes: nil, checkedAt: now.addingTimeInterval(-120),
            updateAvailable: true)
    }

    /// Builds the `--fake-channel` channel. `source` roots its checkout at
    /// the bundle's parent — on a machine that isn't actually a checkout
    /// the probe just degrades to a bare channel line, which is fine for a
    /// presentation hatch.
    private static func launchFakeChannel() -> (any DistributionChannel)? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--fake-channel"),
              arguments.indices.contains(flag + 1)
        else { return nil }
        switch arguments[flag + 1] {
        case "release":
            return GitHubChannel(flavor: .releaseInstall)
        case "source":
            return GitHubChannel(flavor: .sourceCheckout(
                root: Bundle.main.bundleURL.deletingLastPathComponent()))
        default:
            return nil
        }
    }

    /// Builds the `--fake-accounts` card: a personal account switched to a
    /// work account an hour ago, so recent sessions land in the second
    /// epoch and one spanning the switch shows both labels.
    private static func launchFakeAccounts() -> AccountPresenceCard? {
        guard CommandLine.arguments.contains("--fake-accounts") else { return nil }
        let now = Date()
        let personal = AccountRef(
            label: "personal@example.com", accountUuid: "fake-personal",
            organizationUuid: nil, email: "personal@example.com",
            displayName: "Personal Person", organizationName: nil,
            tier: "default_claude_max_20x")
        let work = AccountRef(
            label: "work@example.com", accountUuid: "fake-work",
            organizationUuid: nil, email: "work@example.com",
            displayName: "Work Person", organizationName: "Work Inc",
            tier: "default_claude_max_5x")
        return AccountPresenceCard(
            current: work,
            since: now.addingTimeInterval(-3_600),
            observedAt: now,
            attributionSince: now.addingTimeInterval(-14 * 86_400),
            distinctAccounts: 2,
            accounts: [
                AccountUsage(
                    ref: work, todayTokens: 1_234_567, todayCost: 4.21,
                    windowTokens: 456_789, windowCost: 1.68),
                AccountUsage(
                    ref: personal, todayTokens: 8_901_234, todayCost: 31.75,
                    windowTokens: 0, windowCost: nil),
            ],
            ambiguous: nil,
            unattributed: nil,
            epochs: [
                AccountEpochCard(
                    label: "personal@example.com", organizationName: nil,
                    firstObservedAt: now.addingTimeInterval(-14 * 86_400),
                    lastObservedAt: now.addingTimeInterval(-3_600), closed: true),
                AccountEpochCard(
                    label: "work@example.com", organizationName: "Work Inc",
                    firstObservedAt: now.addingTimeInterval(-3_600),
                    lastObservedAt: now, closed: false),
            ])
    }

    /// Builds the `--fake-notices` card through the digest's own phrasing,
    /// so what gets click-verified is exactly what the engine would publish
    /// for these facts — and the same incidents as outage spans, so the
    /// charts' outage floor shows the very outage the section lists (plus a
    /// resolved one from earlier in the week, for a past page).
    private static func launchFakeNotices() -> (card: NoticesCard, outages: [OutageSpan])? {
        guard let facts = launchFakeNoticeFacts() else { return nil }
        let now = Date()
        let calendar = Calendar.current
        let earlier = calendar.date(byAdding: .day, value: -3, to: now) ?? now
        let earlierStart = calendar.date(bySettingHour: 14, minute: 30, second: 0, of: earlier) ?? now
        let earlierOutage = Notice(
            id: Notice.outageID(incidentID: "fake-earlier"), kind: "outage",
            occurredAt: earlierStart, endedAt: earlierStart.addingTimeInterval(2_700),
            ongoing: false, seenAt: now, dismissedAt: now, recordedAt: now,
            subject: "Degraded performance for Claude Opus", impact: "minor",
            phase: "resolved", components: ["Claude API (api.anthropic.com)"],
            url: "https://stspg.io/tcsfmtc03xgm")
        return (
            NoticePhrasing.card(pending: facts, serviceName: "Claude", now: now),
            OutageTimeline.spans(from: facts + [earlierOutage], now: now))
    }

    private static func launchFakeNoticeFacts() -> [Notice]? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--fake-notices"),
              arguments.indices.contains(flag + 1)
        else { return nil }
        let now = Date()
        let calendar = Calendar.current
        // Yesterday 21:10 local — the 2026-09-04 reset's shape.
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let resetAt = calendar.date(bySettingHour: 21, minute: 10, second: 0, of: yesterday) ?? now
        let reset = Notice(
            id: Notice.resetID(at: resetAt), kind: "reset", occurredAt: resetAt,
            endedAt: resetAt, recordedAt: resetAt.addingTimeInterval(180),
            meterLabel: "Weekly (all)", fromPercent: 71)
        let components = ["Claude Code", "Claude API (api.anthropic.com)"]
        switch arguments[flag + 1] {
        case "morning":
            let start = calendar.date(bySettingHour: 1, minute: 10, second: 0, of: now) ?? now
            let outage = Notice(
                id: Notice.outageID(incidentID: "fake-night"), kind: "outage",
                occurredAt: start, endedAt: start.addingTimeInterval(7_800),
                ongoing: false, seenWhileOngoing: false, recordedAt: now,
                subject: "Elevated errors on Claude Code and the API", impact: "major",
                phase: "resolved", components: components, url: "https://stspg.io/tcsfmtc03xgm")
            return [outage, reset]
        case "live":
            let outage = Notice(
                id: Notice.outageID(incidentID: "fake-major"), kind: "outage",
                occurredAt: now.addingTimeInterval(-1_800), ongoing: true,
                seenAt: now.addingTimeInterval(-600), recordedAt: now,
                subject: "Elevated errors on Claude Code", impact: "major",
                phase: "identified",
                message: "We have identified the cause and are rolling out a fix.",
                components: components, url: "https://stspg.io/tcsfmtc03xgm")
            return [outage, reset]
        default:
            return nil
        }
    }

    /// Builds the `--fake-status` card. The copy is the real 2026-08-18
    /// incident's, so what gets click-verified reads like the genuine
    /// article rather than lorem.
    private static func launchFakeStatus() -> ServiceStatusCard? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--fake-status"),
              arguments.indices.contains(flag + 1)
        else { return nil }
        let kind = arguments[flag + 1]
        let now = Date()
        let components = [
            StatusComponent(name: "claude.ai", status: "operational"),
            StatusComponent(name: "Claude Console (platform.claude.com)", status: "operational"),
            StatusComponent(name: "Claude API (api.anthropic.com)", status: "operational"),
            StatusComponent(name: "Claude Code", status: "operational"),
            StatusComponent(name: "Claude Cowork", status: "operational"),
            StatusComponent(name: "Claude for Government", status: "operational"),
        ]
        func degraded(_ names: Set<String>, as state: String) -> [StatusComponent] {
            components.map {
                names.contains($0.name) ? StatusComponent(name: $0.name, status: state) : $0
            }
        }
        func incident(_ impact: String, _ phase: String, _ name: String, _ message: String)
            -> StatusIncident
        {
            StatusIncident(
                id: "fake-\(impact)", name: name, impact: impact, phase: phase,
                startedAt: now.addingTimeInterval(-4_320), lastUpdateAt: now.addingTimeInterval(-600),
                lastMessage: message, url: "https://stspg.io/tcsfmtc03xgm",
                componentNames: ["claude.ai", "Claude API (api.anthropic.com)", "Claude Code"])
        }
        func card(
            indicator: String, description: String, components: [StatusComponent],
            incidents: [StatusIncident] = [], resolved: [StatusIncident] = [],
            maintenances: [StatusMaintenance] = [], stale: Bool = false, okAt: Date? = nil
        ) -> ServiceStatusCard {
            ServiceStatusCard(
                providerID: "claude", pageName: "Claude",
                pageURL: "https://status.claude.com", indicator: indicator,
                descriptionText: description, checkedAt: now, okAt: okAt ?? now,
                stale: stale, components: components, incidents: incidents,
                recentlyResolved: resolved, maintenances: maintenances)
        }

        switch kind {
        case "none":
            return card(
                indicator: "none", description: "All Systems Operational",
                components: components)
        case "minor":
            return card(
                indicator: "minor", description: "Partially Degraded Service",
                components: degraded(["claude.ai"], as: "degraded_performance"),
                incidents: [
                    incident(
                        "minor", "monitoring", "Degraded performance for multiple models",
                        "A fix has been implemented and we are monitoring the results.")
                ])
        case "major":
            return card(
                indicator: "major", description: "Partial System Outage",
                components: degraded(
                    ["claude.ai", "Claude API (api.anthropic.com)"], as: "partial_outage"),
                incidents: [
                    incident(
                        "major", "identified", "Elevated errors on Claude API",
                        "We have identified the cause of the elevated error rates and are "
                            + "working on a fix.")
                ])
        case "critical":
            return card(
                indicator: "critical", description: "Major Service Outage",
                components: degraded(
                    ["claude.ai", "Claude API (api.anthropic.com)", "Claude Code"],
                    as: "major_outage"),
                incidents: [
                    incident(
                        "critical", "investigating", "Service disruption on Claude services",
                        "We are investigating elevated errors across Claude services. We will "
                            + "provide an update as soon as possible.")
                ])
        case "maintenance":
            return card(
                indicator: "maintenance", description: "All Systems Operational",
                components: components,
                maintenances: [
                    StatusMaintenance(
                        id: "fake-mnt", name: "Scheduled infrastructure maintenance",
                        phase: "in_progress", windowStart: now.addingTimeInterval(-1_800),
                        windowEnd: now.addingTimeInterval(5_400))
                ])
        case "unknown":
            return card(
                indicator: "unknown", description: "", components: [], stale: true,
                okAt: now.addingTimeInterval(-1_080))
        case "resolved":
            return card(
                indicator: "none", description: "All Systems Operational",
                components: components,
                resolved: [
                    StatusIncident(
                        id: "fake-resolved", name: "Degraded performance for multiple models",
                        impact: "minor", phase: "resolved",
                        startedAt: now.addingTimeInterval(-9_000),
                        lastUpdateAt: now.addingTimeInterval(-900),
                        lastMessage:
                            "The issue affecting Claude Opus 5 has been resolved.",
                        url: nil, componentNames: ["claude.ai"],
                        resolvedAt: now.addingTimeInterval(-900))
                ])
        default:
            return nil
        }
    }
}
