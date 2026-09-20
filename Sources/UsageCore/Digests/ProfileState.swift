import Foundation

/// One profile's section of the digest (0.96.0). The top level of
/// `LiveState` mirrors the FOCUSED profile's section verbatim, so every
/// pre-profile reader keeps working; readers that know about profiles walk
/// `LiveState.profiles` instead. Identity facts are always present; the
/// metering sections are nil for a profile whose engine is not running
/// (dormant or disabled) — absent, never zero.
public struct ProfileState: Codable, Sendable, Equatable, Identifiable {
    /// The account's name across every harness (`ProfileKey`): the bare
    /// profile id under the bundled harness, `codex` / `codex.ab12cd34`
    /// under another. Every id the digest, the pin, the socket verbs and the
    /// CLI selector speak is one of these.
    public let id: String
    public let providerID: String
    /// The STORAGE id inside its harness (`default`, `ab12cd34`) — what its
    /// files and defaults keys hang off, published (0.101.0) so nobody has
    /// to take a key apart.
    public let accountID: String?
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
        sessions: [SessionCard]?, accountPresence: AccountPresenceCard?,
        accountID: String? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.accountID = accountID
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
    /// The account's `ProfileKey` — cells of different harnesses sit in one
    /// list and every harness's standard home is `default`.
    public let profile: String
    public let providerID: String
    public let glyph: String
    /// Its harness's brand accent, so a face tints the glyph ahead of this
    /// cell without knowing any vendor (0.101.0; nil = a one-harness writer,
    /// whose accent is the top level's).
    public let accent: RGBColor?
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
        segments: [SegmentStatus], stale: Bool, worstSeverity: Double?, indicator: Bool,
        accent: RGBColor? = nil
    ) {
        self.profile = profile
        self.providerID = providerID
        self.glyph = glyph
        self.accent = accent
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

/// The host's digest: every metered harness's accounts folded into ONE
/// live-state.json. Pure — the host supplies every input and the clock.
public enum MeteringDigest {
    /// The top level is the FOCUSED account's section verbatim, except that
    /// `engine.generatedAt` is the HOST's heartbeat (`now`) and
    /// `engine.nextPollAt` is the earliest poll any engine has scheduled —
    /// else the next reprobe — so an all-dormant host keeps a live heartbeat
    /// and never trips a client into taking over. The vendor-level cards at
    /// the top level (status, notices, outages) are the FOCUSED HARNESS's,
    /// phrased once; every harness's own ride in `harnesses`, and
    /// `viewing(profile:)` projects any account's with them. With no
    /// publishable focused section the top level is a readable loading
    /// state: stale, nothing fetched, no invented error.
    public static func compose(
        harnesses: [HarnessSection], sections: [ProfileSection], focused: String?,
        pinned: String? = nil, host: String, pid: Int, appVersion: String,
        systemAccent: RGBColor?, activeInterval: TimeInterval, appUpdate: AppUpdateCard?,
        nextReprobeAt: Date?, now: Date, calendar: Calendar = .current,
        locale: Locale = .current
    ) -> LiveState {
        let shownIDs = Set(harnesses.filter(\.shown).map(\.provider.id))
        // Focus fell to nobody (every account dormant, or a stale key): the
        // first SHOWN harness's standard account answers — the bundled one
        // when it is shown, since harnesses arrive in the build's order.
        let focusedSection = sections.first { $0.profile.key == focused }
            ?? sections.first { $0.profile.isDefault && shownIDs.contains($0.profile.providerID) }
            ?? sections.first { $0.profile.isDefault }
            ?? sections.first
        let focusedID = focusedSection?.profile.key
        let focusedHarness = harnesses.first {
            $0.provider.id == focusedSection?.profile.providerID
        } ?? harnesses.first
        let provider = focusedHarness?.provider ?? HarnessResolution.standardProviders()[0]
        let base = focusedSection?.state ?? LiveStateBuilder.build(
            provider: provider, host: host, pid: pid, appVersion: appVersion,
            state: .loading, predictions: [:], samples: [], timeline: [], activity: [],
            pricing: provider.bundledRates, colorLedger: ModelColorLedger(),
            graceSeconds: ActivityGrace.defaultSeconds, activeInterval: activeInterval,
            paceMultiplier: 1, nextPollAt: nil, backoffUntil: nil, apiBudget: nil,
            systemAccent: systemAccent, now: now, calendar: calendar, locale: locale)
        let earliestPoll = sections.compactMap { $0.state?.engine.nextPollAt }.min()
        let engine = base.engine.replacing(generatedAt: now, nextPollAt: earliestPoll ?? nextReprobeAt)

        let profiles = sections.map { section in
            ProfileState(
                id: section.profile.key, providerID: section.profile.providerID,
                label: section.label, nickname: section.profile.nickname,
                monogram: section.monogram, enabled: section.profile.enabled,
                isFocused: section.profile.key == focusedID, dormant: section.dormant,
                lastActivityAt: section.lastActivityAt, homeDisplayPath: section.homeDisplayPath,
                engine: section.state?.engine, meters: section.state?.meters,
                menuBar: section.state?.menuBar, models: section.state?.models,
                activity: section.state?.activity, sessions: section.state?.sessions,
                accountPresence: section.state?.accountPresence,
                accountID: section.profile.id)
        }
        // A cell per shown account of a shown harness, in roster order. Its
        // own harness's glyph and accent ride along: the bar draws several
        // vendors at once and must never tint one with another's mark.
        let cells = harnesses.filter(\.shown).flatMap { harness -> [MenuBarCell] in
            let resets = (harness.notices ?? []).filter { $0.isPending && $0.kindValue == .reset }
            return sections
                .filter { $0.showsCell && $0.profile.providerID == harness.provider.id }
                .map { section in
                    let segments = section.state?.menuBar ?? []
                    return MenuBarCell(
                        profile: section.profile.key, providerID: section.profile.providerID,
                        glyph: harness.provider.menuBarGlyph, monogram: section.monogram,
                        segments: segments, stale: section.state?.engine.stale ?? true,
                        worstSeverity: segments.compactMap(\.severity).max(),
                        indicator: resets.contains { $0.profileIDOrDefault == section.profile.id },
                        accent: RGBColor(harness.provider.accent))
                }
        }
        let states = harnesses.map { harness in
            let mine = sections.filter { $0.profile.providerID == harness.provider.id }
            return HarnessState(
                id: harness.provider.id, serviceName: harness.provider.serviceName,
                agentName: harness.provider.agentName, glyph: harness.provider.menuBarGlyph,
                shortName: harness.shortName, accent: RGBColor(harness.provider.accent),
                isLocalProvider: harness.provider.networkDestinations.isEmpty,
                present: harness.present, shown: harness.shown,
                recentFiles: harness.recentFiles, activeDays: harness.activeDays,
                newestActivityAt: mine.compactMap(\.lastActivityAt).max(),
                accountCount: mine.count,
                serviceStatus: harness.serviceStatus,
                notices: noticesCard(harness, now: now, calendar: calendar, locale: locale),
                outages: harness.outages)
        }

        return LiveState(
            engine: engine, meters: base.meters, menuBar: base.menuBar, models: base.models,
            activity: base.activity, sessions: base.sessions,
            serviceStatus: focusedHarness?.serviceStatus, appUpdate: appUpdate,
            accountPresence: base.accountPresence,
            notices: focusedHarness.flatMap {
                noticesCard($0, now: now, calendar: calendar, locale: locale)
            },
            outages: focusedHarness?.outages,
            focusedProfile: focusedID, profiles: profiles, menuBarCells: cells,
            harnesses: states, pinnedProfile: pinned)
    }

    /// The one-harness call this host made before several were metered at
    /// once — still how a single-provider host and the golden fixture
    /// compose, and the reason a Mac metering one harness publishes the same
    /// bytes it always did (plus the additive fields).
    public static func compose(
        sections: [ProfileSection], focused: String?, provider: any UsageProvider,
        host: String, pid: Int, appVersion: String, systemAccent: RGBColor?,
        activeInterval: TimeInterval,
        serviceStatus: ServiceStatusCard?, appUpdate: AppUpdateCard?,
        notices: [Notice]?, outages: [OutageSpan]?, nextReprobeAt: Date?,
        now: Date, calendar: Calendar = .current, locale: Locale = .current
    ) -> LiveState {
        compose(
            harnesses: [HarnessSection(
                provider: provider, serviceStatus: serviceStatus, notices: notices,
                outages: outages)],
            sections: sections, focused: focused, host: host, pid: pid, appVersion: appVersion,
            systemAccent: systemAccent, activeInterval: activeInterval, appUpdate: appUpdate,
            nextReprobeAt: nextReprobeAt, now: now, calendar: calendar, locale: locale)
    }

    /// One harness's notices, phrased in ITS service's name, with ids (and
    /// the account a reset belongs to) named the way every face and verb
    /// names them across harnesses. The bundled harness's card is untouched.
    static func noticesCard(
        _ harness: HarnessSection, now: Date, calendar: Calendar, locale: Locale
    ) -> NoticesCard? {
        guard let notices = harness.notices else { return nil }
        let providerID = harness.provider.id
        let card = NoticePhrasing.card(
            pending: notices, serviceName: harness.provider.serviceName, now: now,
            calendar: calendar, locale: locale)
        guard providerID != HarnessResolution.bundledProviderID else { return card }
        return NoticesCard(
            indicator: card.indicator, pendingCount: card.pendingCount,
            items: card.items.map { item in
                NoticeCard(
                    id: NoticeRouting.qualify(item.id, providerID: providerID), kind: item.kind,
                    severity: item.severity, title: item.title, detail: item.detail,
                    when: item.when, occurredAt: item.occurredAt, endedAt: item.endedAt,
                    ongoing: item.ongoing, dismissable: item.dismissable, seen: item.seen,
                    ownsMenuBarSurface: item.ownsMenuBarSurface, url: item.url,
                    components: item.components, meterLabel: item.meterLabel,
                    profile: item.kind == Notice.Kind.reset.rawValue
                        ? ProfileKey.make(
                            providerID: providerID,
                            profileID: item.profile ?? StorageScope.defaultProfileID)
                        : item.profile.map {
                            ProfileKey.make(providerID: providerID, profileID: $0)
                        })
            })
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
    /// own facts, nothing fetched, stale, no error. `engine.generatedAt` is
    /// the HOST's heartbeat in every projection — the file's freshness,
    /// which `--max-age` judges — while `fetchedAt`/`nextPollAt` stay the
    /// section's own.
    public func viewing(profile profileID: String) -> LiveState? {
        guard let profiles else {
            return profileID == Profile.defaultID ? self : nil
        }
        guard let section = profiles.first(where: { $0.id == profileID }) else { return nil }
        // The VIEWED account's harness owns the vendor cards in its
        // projection — a Codex account must never be read beside another
        // vendor's incident. A one-harness writer's list holds exactly the
        // top level's cards, so its projections are unchanged.
        let harness = harnesses?.first { $0.id == section.providerID }
        return LiveState(
            schemaVersion: schemaVersion, sessionsCap: sessionsCap,
            engine: section.engine.map { $0.replacing(generatedAt: engine.generatedAt, nextPollAt: $0.nextPollAt) }
                ?? EngineStatus.idle(from: engine, harness: harness),
            meters: section.meters ?? [], menuBar: section.menuBar ?? [],
            models: section.models ?? [],
            activity: section.activity ?? ActivityRollup.empty(timeZone: activity.timeZone),
            sessions: section.sessions ?? [],
            serviceStatus: harness.map(\.serviceStatus) ?? serviceStatus, appUpdate: appUpdate,
            accountPresence: section.accountPresence,
            notices: harness.map(\.notices) ?? notices,
            outages: harness.map(\.outages) ?? outages,
            focusedProfile: focusedProfile, profiles: profiles, menuBarCells: menuBarCells,
            harnesses: harnesses, pinnedProfile: pinnedProfile)
    }

    /// Every SHOWN harness's pending notices in one card (0.101.0). The
    /// top level carries the focused harness's alone, which was the whole
    /// story while one harness was metered; with several, a face that lists
    /// one harness's notices while a verb spans them all would dismiss
    /// something nobody was shown. Ids stay qualified per harness
    /// (`NoticeRouting`), so a dismissal still lands in exactly one ledger.
    ///
    /// A writer before harnesses publishes no roster, so its own card is the
    /// answer — absent means "this writer doesn't say", never "none".
    public func pendingNotices() -> NoticesCard? {
        guard let harnesses else { return notices }
        let cards = harnesses.filter(\.shown).compactMap(\.notices)
        guard !cards.isEmpty else { return nil }
        let items = cards.flatMap(\.items)
        guard !items.isEmpty else { return nil }
        return NoticesCard(
            indicator: cards.contains { $0.indicator },
            pendingCount: cards.reduce(0) { $0 + $1.pendingCount },
            items: items.sorted { a, b in
                a.ongoing != b.ongoing ? a.ongoing : a.occurredAt > b.occurredAt
            })
    }

    /// Whether ANY shown harness has an incident running — what a script
    /// branching on "is something down" means once several vendors are
    /// metered. A card is about one service, so the health FIELDS stay the
    /// focused harness's; only this verdict spans them.
    public func anyIncident() -> Bool {
        guard let harnesses else { return serviceStatus?.hasIncident ?? false }
        return harnesses.filter(\.shown).contains { $0.serviceStatus?.hasIncident ?? false }
    }

    /// Per-profile fetch stamps for a host taking over from a dead one —
    /// each engine's gate is seeded with ITS profile's last fetch, so a
    /// handover never double-polls inside the floor. A pre-profile digest
    /// seeds the default profile from its top level.
    public func gateSeeds() -> [String: Date] {
        guard let profiles else {
            return engine.fetchedAt.map {
                [ProfileKey.make(
                    providerID: engine.providerID, profileID: StorageScope.defaultProfileID): $0]
            } ?? [:]
        }
        var seeds: [String: Date] = [:]
        for section in profiles {
            // Keyed the way the host keys its engines. A section written
            // before keys existed carries its storage id as its id, so the
            // key is derived from the harness it names either way.
            let key = ProfileKey.make(
                providerID: section.providerID, profileID: section.accountID ?? section.id)
            if let fetchedAt = section.engine?.fetchedAt { seeds[key] = fetchedAt }
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
    /// is scheduled, and no error is invented. `harness` supplies the VENDOR
    /// facts when the idle account belongs to another one — without it a
    /// dormant Codex account would read as the writer's own vendor.
    static func idle(from writer: EngineStatus, harness: HarnessState? = nil) -> EngineStatus {
        EngineStatus(
            providerID: harness?.id ?? writer.providerID,
            serviceName: harness?.serviceName ?? writer.serviceName,
            agentName: harness?.agentName ?? writer.agentName,
            glyph: harness?.glyph ?? writer.glyph, accent: harness?.accent ?? writer.accent,
            systemAccent: writer.systemAccent, planLabel: nil, planSubscriptionType: nil,
            planRateLimitTier: nil, appVersion: writer.appVersion, pid: writer.pid,
            host: writer.host, generatedAt: writer.generatedAt, fetchedAt: nil,
            nextPollAt: nil, backoffUntil: nil, stale: true,
            isLocalProvider: harness?.isLocalProvider ?? writer.isLocalProvider,
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
            level: DisplayLevel(digestName: status.level), severity: status.severity,
            exhaustsAt: status.exhaustsAt, resetsAt: status.resetsAt)
    }
}
