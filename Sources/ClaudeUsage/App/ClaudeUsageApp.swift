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
        // A real outage can't be scheduled, so the status surfaces get their
        // own hatch: `--fake-status <minor|major|critical|maintenance|
        // unknown|resolved|none>` installs a synthetic card carrying real
        // incident copy, and every surface renders it exactly as it would
        // render the live one.
        if let fake = Self.launchFakeStatus() {
            registry.activeStore.installFakeServiceStatus(fake)
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
    }

    private static func launchProviderOverride() -> String? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--provider"),
              arguments.indices.contains(flag + 1)
        else { return nil }
        return arguments[flag + 1]
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
