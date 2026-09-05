import AppKit
import SwiftUI
import UsageCore

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // No windows — StatusItemController owns all UI.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.avihu.ClaudeUsage"
        // Pre-registry builds kept one unscoped set of artifacts; move them
        // into the claude scope before any store opens them.
        StorageMigration.standard(bundleID: bundleID, providerID: "claude")
        // The registry chooses the vendor (detection or the user's Metering
        // pick) and installs its model catalog before any UI renders.
        let registry = ProviderRegistry(
            bundleID: bundleID, launchOverride: Self.launchProviderOverride())
        controller = StatusItemController(registry: registry)
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
            registry.activeStore.installFakeNotices(fake)
        }
        // Verification hatches: `ClaudeUsage --settings [--pane-cost]` /
        // `--panel` open UI straight away (the ⋯ menu can't be scripted,
        // and AX row selection can't drive the sidebar); `--provider <id>`
        // forces a harness for this launch without persisting the choice.
        if CommandLine.arguments.contains("--settings") {
            controller?.showSettings(
                pane: CommandLine.arguments.contains("--pane-cost") ? .apiCost : .general)
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
                Self.writeSnapshots(store: registry.activeStore, to: directory)
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

    private static func writeSnapshots(store: UsageStore, to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
        // The weekly meter's card, lit at the first pending reset notice
        // exactly as a click on that notice would open it.
        if let meters = store.state.snapshot?.meters,
           let meter = meters.first(where: { $0.rank == 1 }) ?? meters.first {
            let reset = store.notices?.items.first { $0.kind == "reset" }?.occurredAt
            let card = MeterHistoryView(
                meter: meter, samples: store.samples, timeline: store.tokenTimeline,
                pricing: store.pricing, prediction: store.predictions[meter.label],
                outcomes: store.windowOutcomes, agentName: store.provider.agentName,
                providerID: store.provider.id, highlightReset: reset)
            write(ImageRenderer(content: card), "meter.png")
        }
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
    /// for these facts.
    private static func launchFakeNotices() -> NoticesCard? {
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
            return NoticePhrasing.card(pending: [outage, reset], serviceName: "Claude", now: now)
        case "live":
            let outage = Notice(
                id: Notice.outageID(incidentID: "fake-major"), kind: "outage",
                occurredAt: now.addingTimeInterval(-1_800), ongoing: true,
                seenAt: now.addingTimeInterval(-600), recordedAt: now,
                subject: "Elevated errors on Claude Code", impact: "major",
                phase: "identified",
                message: "We have identified the cause and are rolling out a fix.",
                components: components, url: "https://stspg.io/tcsfmtc03xgm")
            return NoticePhrasing.card(pending: [outage, reset], serviceName: "Claude", now: now)
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
