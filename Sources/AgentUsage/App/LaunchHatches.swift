import AppKit
import SwiftUI
import UsageCore

/// The launch hatches that install synthetic state: a second account, a
/// second harness, an incident, an update, an account switch, a notices card.
/// None of these can be produced on demand on this Mac — an outage can't be
/// scheduled and a release can't be invented — so each one builds the real
/// card through the real phrasing and hands it to the face.
@MainActor
extension AppDelegate {
    /// `--demo-digest <path>`: the digest every face renders instead of
    /// this Mac's. An unreadable file is no demo at all — the app must not
    /// fall through to real data under a flag that promised none.
    static func launchDemoDigest() -> LiveState? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--demo-digest") else { return nil }
        guard arguments.indices.contains(flag + 1),
              let data = try? Data(contentsOf: URL(fileURLWithPath: arguments[flag + 1])),
              let live = try? LiveState.decoder().decode(LiveState.self, from: data)
        else {
            FileHandle.standardError.write(Data("--demo-digest: no readable digest\n".utf8))
            exit(2)
        }
        return live
    }

    /// The synthetic second account. Its digest is the live one with two
    /// meters rewritten and the third dropped — the absent scoped bar is
    /// exactly the case a one-account Mac can't otherwise produce.
    static func installFakeProfile(into registry: ProviderRegistry) {
        let url = LiveState.fileURL(bundleID: Bundle.main.bundleIdentifier ?? AppIdentity.bundleID)
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
                bundleID: Bundle.main.bundleIdentifier ?? AppIdentity.bundleID, fixed: fake))
    }

    /// Builds the `--fake-update` card: `current` renders the up-to-date
    /// Settings card, any version string renders the offer.
    static func launchFakeUpdate() -> AppUpdateCard? {
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
        // Releases carry no asset, so the plain fake is the source-only
        // offer. `--fake-asset` dresses it as a release that has one, to see
        // the one-click presentation: its "URL" has no host, which the
        // updater's allowlist refuses — a click opens the release page.
        let asset: String? = arguments.contains("--fake-asset") ? "fake-asset" : nil
        return AppUpdateCard(
            latestVersion: version,
            url: "\(AppIdentity.releasesPage)/tag/v\(version)",
            publishedAt: now.addingTimeInterval(-3_600), assetName: asset,
            assetURL: asset, assetBytes: nil, checkedAt: now.addingTimeInterval(-120),
            updateAvailable: true)
    }

    /// Builds the `--fake-channel` channel. `source` roots its checkout at
    /// the bundle's parent — on a machine that isn't actually a checkout
    /// the probe just degrades to a bare channel line, which is fine for a
    /// presentation hatch.
    static func launchFakeChannel() -> (any DistributionChannel)? {
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
    static func launchFakeAccounts() -> AccountPresenceCard? {
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
    static func launchFakeNotices() -> (card: NoticesCard, outages: [OutageSpan])? {
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

    static func launchFakeNoticeFacts() -> [Notice]? {
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
    static func launchFakeStatus() -> ServiceStatusCard? {
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

    /// `--fake-harnesses`: a SECOND vendor metered beside the real one, so
    /// the bar's harness blocks, the panel strip's headings and the
    /// Harnesses card can be verified on a Mac with one agent installed.
    /// It borrows the live digest for everything below the meters, exactly
    /// as `--fake-profiles` does — the point is the harness seam, not the
    /// numbers. The vendor is a REAL provider this build ships (the first
    /// that isn't the bundled one), so its mark, accent and name are the
    /// ones the bar would actually wear.
    static func installFakeHarness(into registry: ProviderRegistry) {
        let providers = registry.providers
        guard let provider = providers.first(where: { $0.id != providers[0].id }) else { return }
        let style = HarnessStyle(provider)
        let bundleID = Bundle.main.bundleIdentifier ?? AppIdentity.bundleID
        let live = (try? Data(contentsOf: LiveState.fileURL(bundleID: bundleID)))
            .flatMap { try? LiveState.decoder().decode(LiveState.self, from: $0) }
        let segments = [
            SegmentStatus(tag: "S", percent: 35, level: "normal", severity: 0, risk: nil),
            SegmentStatus(tag: "W", percent: 12, level: "normal", severity: 0, risk: nil),
        ]
        let key = ProfileKey.make(providerID: provider.id, profileID: Profile.defaultID)
        let harness = HarnessState(
            id: provider.id, serviceName: provider.serviceName, agentName: provider.agentName,
            glyph: style.glyph,
            shortName: provider.agentName.split(separator: " ").first.map(String.init)
                ?? provider.serviceName,
            accent: style.accent, isLocalProvider: provider.networkDestinations.isEmpty,
            present: true, shown: true, recentFiles: 24, activeDays: 3,
            newestActivityAt: Date().addingTimeInterval(-3_600), accountCount: 1,
            serviceStatus: nil, notices: nil, outages: nil)
        let cell = MenuBarCell(
            profile: key, providerID: provider.id, glyph: style.glyph,
            monogram: harness.shortName.prefix(1).uppercased(), segments: segments,
            stale: false, worstSeverity: 0, indicator: false, accent: style.accent)
        let profile = Profile(
            id: Profile.defaultID, providerID: provider.id, home: provider.homeDirectory,
            addedAt: Date())
        // Without a live digest there is nothing to borrow, and a synthetic
        // harness with no numbers would teach nothing — the hatch is a no-op.
        guard let live else { return }
        let fixed = {
            LiveState(
                schemaVersion: live.schemaVersion, sessionsCap: live.sessionsCap,
                engine: live.engine, meters: live.meters, menuBar: segments,
                models: live.models, activity: live.activity, sessions: live.sessions,
                serviceStatus: nil, appUpdate: live.appUpdate, accountPresence: nil,
                notices: nil, outages: nil, focusedProfile: live.focusedProfile,
                profiles: live.profiles)
        }()
        registry.installFakeHarness(
            harness, cell: cell, profile: profile,
            store: UsageStore(
                profile: profile, provider: provider, bundleID: bundleID, fixed: fixed))
    }
}
