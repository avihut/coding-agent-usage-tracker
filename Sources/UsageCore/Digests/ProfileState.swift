import Foundation

/// One profile's section of the digest (0.96.0). The top level of
/// `LiveState` mirrors the FOCUSED profile's section verbatim, so every
/// pre-profile reader keeps working; readers that know about profiles walk
/// `LiveState.profiles` instead. Identity facts are always present; the
/// metering sections are nil for a profile whose engine is not running
/// (dormant or disabled) — absent, never zero.
public struct ProfileState: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let providerID: String
    /// What the faces call it (`ProfileFacts.label`): nickname, else the
    /// signed-in email, else the home's name.
    public let label: String
    public let nickname: String?
    /// One character for the menu bar cell.
    public let monogram: String
    public let enabled: Bool
    public let isFocused: Bool
    /// D9: no session write in 30 days — hidden from the bar and the strip,
    /// not polled, not scanned.
    public let dormant: Bool
    public let lastActivityAt: Date?
    /// "~/.claude-personal" — tilde form ONLY; the digest carries no
    /// absolute paths (spec §10). Nil for a provider without homes.
    public let homeDisplayPath: String?
    /// The engine's own status; nil when no engine runs for this profile.
    public let engine: EngineStatus?
    public let meters: [LiveMeter]?
    public let menuBar: [SegmentStatus]?
    public let models: [ModelRow]?
    public let activity: ActivityRollup?
    public let sessions: [SessionCard]?
    public let accountPresence: AccountPresenceCard?

    public init(
        id: String, providerID: String, label: String, nickname: String?, monogram: String,
        enabled: Bool, isFocused: Bool, dormant: Bool, lastActivityAt: Date?,
        homeDisplayPath: String?, engine: EngineStatus?, meters: [LiveMeter]?,
        menuBar: [SegmentStatus]?, models: [ModelRow]?, activity: ActivityRollup?,
        sessions: [SessionCard]?, accountPresence: AccountPresenceCard?
    ) {
        self.id = id
        self.providerID = providerID
        self.label = label
        self.nickname = nickname
        self.monogram = monogram
        self.enabled = enabled
        self.isFocused = isFocused
        self.dormant = dormant
        self.lastActivityAt = lastActivityAt
        self.homeDisplayPath = homeDisplayPath
        self.engine = engine
        self.meters = meters
        self.menuBar = menuBar
        self.models = models
        self.activity = activity
        self.sessions = sessions
        self.accountPresence = accountPresence
    }
}

/// One menu bar cell, decided by the WRITER so the app's bar and the TUI's
/// header can't disagree: which profiles show, in what order, with which
/// digits, and whether the profile's own pending resets light its cell.
/// Outages never light a cell — they are everyone's and own the glyph.
public struct MenuBarCell: Codable, Sendable, Equatable, Identifiable {
    public let profile: String
    public let providerID: String
    public let glyph: String
    public let monogram: String
    /// The S/W/scoped triple; empty when the profile's engine has not
    /// published yet.
    public let segments: [SegmentStatus]
    public let stale: Bool
    public let worstSeverity: Double?
    public let indicator: Bool

    public var id: String { profile }

    public init(
        profile: String, providerID: String, glyph: String, monogram: String,
        segments: [SegmentStatus], stale: Bool, worstSeverity: Double?, indicator: Bool
    ) {
        self.profile = profile
        self.providerID = providerID
        self.glyph = glyph
        self.monogram = monogram
        self.segments = segments
        self.stale = stale
        self.worstSeverity = worstSeverity
        self.indicator = indicator
    }
}

/// What the host hands the composer for one enrolled profile: the record,
/// the resolved facts (label, monogram, dormancy, last write, display
/// path), and the engine's latest publish — nil when no engine runs.
public struct ProfileSection: Sendable {
    public let profile: Profile
    public let label: String
    public let monogram: String
    public let dormant: Bool
    public let lastActivityAt: Date?
    public let homeDisplayPath: String?
    public let state: LiveState?

    public init(
        profile: Profile, label: String, monogram: String, dormant: Bool,
        lastActivityAt: Date?, homeDisplayPath: String?, state: LiveState?
    ) {
        self.profile = profile
        self.label = label
        self.monogram = monogram
        self.dormant = dormant
        self.lastActivityAt = lastActivityAt
        self.homeDisplayPath = homeDisplayPath
        self.state = state
    }

    /// Enabled, awake, and wanted in the bar.
    public var showsCell: Bool { profile.enabled && !dormant && profile.showInMenuBar }
}

/// The host's digest: N profile sections folded into ONE live-state.json.
/// Pure — the host supplies every input and the clock.
public enum MeteringDigest {
    /// The top level is the focused section verbatim, except that
    /// `engine.generatedAt` is the HOST's heartbeat (`now`) and
    /// `engine.nextPollAt` is the earliest poll any engine has scheduled —
    /// else the next reprobe — so an all-dormant host keeps a live heartbeat
    /// and never trips a client into taking over. Provider-level cards
    /// (status, update, notices, outages) are the host's, phrased once.
    /// With no publishable focused section the top level is a readable
    /// loading state: stale, nothing fetched, no invented error.
    public static func compose(
        sections: [ProfileSection], focused: String?, provider: any UsageProvider,
        host: String, pid: Int, appVersion: String, systemAccent: RGBColor?,
        activeInterval: TimeInterval,
        serviceStatus: ServiceStatusCard?, appUpdate: AppUpdateCard?,
        notices: [Notice]?, outages: [OutageSpan]?, nextReprobeAt: Date?,
        now: Date, calendar: Calendar = .current, locale: Locale = .current
    ) -> LiveState {
        let focusedSection = sections.first { $0.profile.id == focused }
            ?? sections.first { $0.profile.isDefault }
            ?? sections.first
        let focusedID = focusedSection?.profile.id
        let base = focusedSection?.state ?? LiveStateBuilder.build(
            provider: provider, host: host, pid: pid, appVersion: appVersion,
            state: .loading, predictions: [:], samples: [], timeline: [], activity: [],
            pricing: provider.bundledRates, colorLedger: ModelColorLedger(),
            graceSeconds: ActivityGrace.defaultSeconds, activeInterval: activeInterval,
            paceMultiplier: 1, nextPollAt: nil, backoffUntil: nil, apiBudget: nil,
            systemAccent: systemAccent, now: now, calendar: calendar, locale: locale)
        let earliestPoll = sections.compactMap { $0.state?.engine.nextPollAt }.min()
        let engine = base.engine.replacing(generatedAt: now, nextPollAt: earliestPoll ?? nextReprobeAt)

        let pendingResets = (notices ?? []).filter { $0.isPending && $0.kindValue == .reset }
        let profiles = sections.map { section in
            ProfileState(
                id: section.profile.id, providerID: section.profile.providerID,
                label: section.label, nickname: section.profile.nickname,
                monogram: section.monogram, enabled: section.profile.enabled,
                isFocused: section.profile.id == focusedID, dormant: section.dormant,
                lastActivityAt: section.lastActivityAt, homeDisplayPath: section.homeDisplayPath,
                engine: section.state?.engine, meters: section.state?.meters,
                menuBar: section.state?.menuBar, models: section.state?.models,
                activity: section.state?.activity, sessions: section.state?.sessions,
                accountPresence: section.state?.accountPresence)
        }
        let cells = sections.filter(\.showsCell).map { section in
            let segments = section.state?.menuBar ?? []
            return MenuBarCell(
                profile: section.profile.id, providerID: section.profile.providerID,
                glyph: provider.menuBarGlyph, monogram: section.monogram,
                segments: segments, stale: section.state?.engine.stale ?? true,
                worstSeverity: segments.compactMap(\.severity).max(),
                indicator: pendingResets.contains { $0.profileIDOrDefault == section.profile.id })
        }

        return LiveState(
            engine: engine, meters: base.meters, menuBar: base.menuBar, models: base.models,
            activity: base.activity, sessions: base.sessions,
            serviceStatus: serviceStatus, appUpdate: appUpdate,
            accountPresence: base.accountPresence,
            notices: notices.map {
                NoticePhrasing.card(
                    pending: $0, serviceName: provider.serviceName, now: now,
                    calendar: calendar, locale: locale)
            },
            outages: outages,
            focusedProfile: focusedID, profiles: profiles, menuBarCells: cells)
    }
}

/// Which section of a digest a per-profile face reads (the client-mode
/// app's `DigestClient(profileID:)`): a pre-profile digest exposes the
/// default profile only, as its whole top level.
public enum ProfileSectionResolver {
    public static func section(of digest: LiveState, profileID: String) -> LiveState? {
        digest.viewing(profile: profileID)
    }
}

extension LiveState {
    /// A section projected onto the top level, provider cards intact, so
    /// every existing reader — each CLI noun, a per-profile client face —
    /// answers for the chosen profile with no per-reader code. Nil when the
    /// profile is unknown to the writer. A section without an engine (a
    /// dormant or disabled profile) projects an idle status: this writer's
    /// own facts, nothing fetched, stale, no error.
    public func viewing(profile profileID: String) -> LiveState? {
        guard let profiles else {
            return profileID == Profile.defaultID ? self : nil
        }
        guard let section = profiles.first(where: { $0.id == profileID }) else { return nil }
        return LiveState(
            schemaVersion: schemaVersion, sessionsCap: sessionsCap,
            engine: section.engine ?? EngineStatus.idle(from: engine),
            meters: section.meters ?? [], menuBar: section.menuBar ?? [],
            models: section.models ?? [],
            activity: section.activity ?? ActivityRollup.empty(timeZone: activity.timeZone),
            sessions: section.sessions ?? [],
            serviceStatus: serviceStatus, appUpdate: appUpdate,
            accountPresence: section.accountPresence, notices: notices, outages: outages,
            focusedProfile: focusedProfile, profiles: profiles, menuBarCells: menuBarCells)
    }

    /// Per-profile fetch stamps for a host taking over from a dead one —
    /// each engine's gate is seeded with ITS profile's last fetch, so a
    /// handover never double-polls inside the floor. A pre-profile digest
    /// seeds the default profile from its top level.
    public func gateSeeds() -> [String: Date] {
        guard let profiles else {
            return engine.fetchedAt.map { [Profile.defaultID: $0] } ?? [:]
        }
        var seeds: [String: Date] = [:]
        for section in profiles {
            if let fetchedAt = section.engine?.fetchedAt { seeds[section.id] = fetchedAt }
        }
        return seeds
    }

    /// The ids the writer knows, focused first — for selector error text.
    public var profileIDs: [String] {
        guard let profiles else { return [Profile.defaultID] }
        return profiles.map(\.id)
    }
}

extension EngineStatus {
    /// The same status with the host's heartbeat and scheduling stamped in.
    func replacing(generatedAt: Date, nextPollAt: Date?) -> EngineStatus {
        EngineStatus(
            providerID: providerID, serviceName: serviceName, agentName: agentName,
            glyph: glyph, accent: accent, systemAccent: systemAccent, planLabel: planLabel,
            planSubscriptionType: planSubscriptionType, planRateLimitTier: planRateLimitTier,
            appVersion: appVersion, pid: pid, host: host, generatedAt: generatedAt,
            fetchedAt: fetchedAt, nextPollAt: nextPollAt, backoffUntil: backoffUntil,
            stale: stale, isLocalProvider: isLocalProvider,
            activeIntervalSeconds: activeIntervalSeconds, paceMultiplier: paceMultiplier,
            apiBudgetUsed: apiBudgetUsed, apiBudgetCeiling: apiBudgetCeiling,
            apiBudgetFraction: apiBudgetFraction, gateFloorSeconds: gateFloorSeconds,
            error: error, spend: spend, forecastProfile: forecastProfile)
    }

    /// An engine that is not running, described with the writer's own
    /// facts: identity and versions are true, nothing was fetched, nothing
    /// is scheduled, and no error is invented.
    static func idle(from writer: EngineStatus) -> EngineStatus {
        EngineStatus(
            providerID: writer.providerID, serviceName: writer.serviceName,
            agentName: writer.agentName, glyph: writer.glyph, accent: writer.accent,
            systemAccent: writer.systemAccent, planLabel: nil, planSubscriptionType: nil,
            planRateLimitTier: nil, appVersion: writer.appVersion, pid: writer.pid,
            host: writer.host, generatedAt: writer.generatedAt, fetchedAt: nil,
            nextPollAt: nil, backoffUntil: nil, stale: true,
            isLocalProvider: writer.isLocalProvider,
            activeIntervalSeconds: writer.activeIntervalSeconds, paceMultiplier: 1,
            apiBudgetUsed: nil, apiBudgetCeiling: nil, apiBudgetFraction: nil,
            gateFloorSeconds: writer.gateFloorSeconds, error: nil, spend: nil,
            forecastProfile: nil)
    }
}

extension ActivityRollup {
    /// No activity known — every count zero because there is nothing, not
    /// because nothing was measured; costs stay nil.
    static func empty(timeZone: String) -> ActivityRollup {
        ActivityRollup(
            timeZone: timeZone, todayHours: [], todayTokens: 0, todayPrompts: 0,
            todayCost: nil, days: [], modelDays: [], hourDays: [])
    }
}

// MARK: - Digest vocabulary → core types

extension DisplayLevel {
    /// "warning" | "critical" → the level; anything else is normal.
    public init(digestName: String) {
        switch digestName {
        case "warning": self = .warning
        case "critical": self = .critical
        default: self = .normal
        }
    }
}

extension UsagePrediction.Verdict {
    public init(digestName: String) {
        switch digestName {
        case "yellow": self = .yellow
        case "red": self = .red
        default: self = .green
        }
    }
}

extension UsagePrediction.Basis {
    public init(digestName: String) {
        switch digestName {
        case "windowAverage": self = .windowAverage
        case "weeklyProfile": self = .weeklyProfile
        default: self = .recentOnly
        }
    }
}

extension MenuBarSegment {
    /// A digest segment back into the renderer's input.
    public init(_ status: SegmentStatus) {
        self.init(
            tag: status.tag, percent: status.percent,
            level: DisplayLevel(digestName: status.level), severity: status.severity)
    }
}
