import AppKit
import Foundation
import Observation
import UsageCore

/// Where this process decides whether it HOSTS metering or renders a
/// daemon's digest, and which accounts of which harnesses it shows. It owns
/// the engine lease and the host arbitration (the daemon wins; a client takes
/// over only when the heartbeat is stale beyond doubt AND the lease is free),
/// and keeps one `UsageStore` face per enrolled account of EVERY harness
/// found on this machine, keyed by that account's flat `ProfileKey`.
///
/// Nothing is "the active provider" since 0.101.0 (user-directed: several
/// harnesses the way several accounts already work). There is no selection,
/// no switch and no teardown — a harness that appears is metered on the
/// host's next reprobe, and a harness the person is not interested in is
/// HIDDEN, which is a display choice only: it keeps being metered, forecast
/// and priced.
@MainActor
@Observable
final class ProviderRegistry {
    /// Which side of the engine this process runs.
    enum Role {
        case hosting(MeteringHost)
        case client(DigestFeed)
    }

    /// Every provider this build ships, bundled default first — also the
    /// order harnesses appear in on the bar and in the strip.
    let providers: [any UsageProvider]
    let bundleID: String
    private(set) var role: Role
    /// Every record of every metered harness (enrolled and dismissed alike),
    /// each harness's implicit default first.
    var profiles: [Profile] = []
    /// One face per enrolled account, keyed by its flat `ProfileKey`.
    var stores: [String: UsageStore] = [:]
    /// Homes found beside a harness's standard one that nobody decided
    /// about, per harness.
    var discoveredByHarness: [String: [DiscoveredHome]] = [:]
    /// A click's choice, shown the instant it is made: the pin it also set
    /// arrives from the host (or the daemon's next digest) a beat later,
    /// and the overlay lifts once they agree.
    private var manualFocusID: String?
    /// Re-binds the status item to a new active store. The Bool says the
    /// switch may wait for the panel to close (daily auto re-detection
    /// must not yank the UI out from under the user; an explicit pick
    /// applies immediately).
    @ObservationIgnored var onActiveChange: ((UsageStore, _ deferrable: Bool) -> Void)?
    /// The profile list or a profile's facts changed.
    @ObservationIgnored var onProfilesChange: (() -> Void)?

    @ObservationIgnored private let lease: EngineLease
    @ObservationIgnored private var redetectTimer: Timer?
    @ObservationIgnored private var roleTimer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var observationGeneration = 0
    @ObservationIgnored private var lastFocusedID: String?

    init(bundleID: String) {
        let providers = HarnessResolution.standardProviders()
        self.providers = providers
        self.bundleID = bundleID
        // The catalog spans every harness this build can meter and never
        // changes again (0.101.0): with two vendors' models in one grid, a
        // name must come from the vendor whose grammar the id belongs to.
        // Installed before any UI renders or scan runs — display names are
        // read from everywhere. The accent is no longer a global at all; it
        // travels as `HarnessStyle`.
        ModelNames.catalog = ModelCatalog.union(of: providers)
        MenuBarPreferences.migrateLegacyStyle(provider: providers[0])

        self.lease = EngineLease(lockURL: EngineHostBroker.lockURL(bundleID: bundleID))
        let daemonAlive = Self.daemonMarkerAge(bundleID: bundleID)
            .map { $0 < EngineHostBroker.daemonAliveWindow } ?? false
        let decided = EngineHostBroker.role(
            leaseHeldByOther: EngineLease.isHeld(at: lease.lockURL),
            daemonAlive: daemonAlive)
        if decided == .host, lease.acquire() {
            let previous = try? LiveState.decoder().decode(
                LiveState.self, from: Data(contentsOf: LiveState.fileURL(bundleID: bundleID)))
            role = .hosting(Self.makeHost(
                providers: providers, bundleID: bundleID,
                gateSeeds: previous?.gateSeeds() ?? [:]))
        } else {
            role = .client(DigestFeed(bundleID: bundleID))
        }
        loadProfiles()
        syncStores()
        observeRole()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .hosting(let host) = self.role { host.noteWake() }
                // A client checks the host survived the sleep right away.
                self.evaluateRole()
            }
        }
        let timer = Timer.scheduledTimer(
            withTimeInterval: EngineHostBroker.checkInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluateRole() }
        }
        timer.tolerance = 5
        roleTimer = timer

        // Auto-install (spec §10 re-amendment 2026-08-16): every launch
        // converges the usaged launch agent — install when absent, repoint
        // when the app moved, restart a stale-version daemon — honoring
        // the sticky opt-out. Detached: launchctl round-trips are process
        // spawns. When the daemon comes up, the ordinary arbitration
        // yields to it within ~30s; nothing here touches the role.
        let embedded = Self.embeddedUsagedBinary()
        Task.detached(priority: .utility) {
            LaunchAgentInstaller.ensure(
                binary: embedded, defaults: .standard, bundleID: bundleID)
        }
    }

    // MARK: - Faces and focus

    /// The FOCUSED profile's face — every pre-profile call site keeps
    /// reading the one store that matters.
    var activeStore: UsageStore { focusedStore }
    var focusedStore: UsageStore {
        stores[focusedID] ?? stores[Profile.defaultID] ?? stores.values.first
            ?? makeStore(for: Profile.standard(for: providers[0], addedAt: Date()))
    }
    /// The focused ACCOUNT's harness — what a surface that still speaks of
    /// one provider (the ⋯ menu's links, the About card) answers for.
    var activeProvider: any UsageProvider { focusedStore.provider }

    /// Every harness this Mac has, as the WRITER resolved it: present,
    /// shown, its recent activity and its own vendor cards. Empty until the
    /// first digest lands, where a face falls back to what it holds.
    var harnesses: [HarnessState] {
        let published: [HarnessState]
        switch role {
        case .hosting(let host): published = host.digest?.harnesses ?? []
        case .client(let feed): published = feed.digest?.harnesses ?? []
        }
        guard !fakeHarnesses.isEmpty else { return published }
        return published.filter { row in !fakeHarnesses.contains { $0.id == row.id } }
            + fakeHarnesses
    }

    /// The `--fake-harnesses` hatch: a second vendor's row, cell and face.
    func installFakeHarness(
        _ harness: HarnessState, cell: MenuBarCell, profile: Profile, store: UsageStore
    ) {
        fakeHarnesses.removeAll { $0.id == harness.id }
        fakeHarnesses.append(harness)
        fakeCells.removeAll { $0.profile == cell.profile }
        fakeCells.append(cell)
        installFakeProfile(profile, store: store)
    }

    /// Every SHOWN harness's pending notices in one card (0.101.0). The
    /// panel used to list the focused harness's alone while "Dismiss all"
    /// reached into every ledger — so a click would silently dismiss a
    /// vendor's reset the person had never been shown. Both ends now span
    /// the same set: what is listed is what "Dismiss all" dismisses.
    ///
    /// Ids arrive already qualified per harness (`NoticeRouting`), so a
    /// dismissal still lands in exactly one ledger. A harness the person hid
    /// is not listed — hiding is what "I'm not interested" means here.
    var pendingNotices: NoticesCard? {
        let cards = harnesses.filter(\.shown).compactMap(\.notices)
        guard !cards.isEmpty else { return focusedStore.notices }
        let items = cards.flatMap(\.items)
        guard !items.isEmpty else { return nil }
        return NoticesCard(
            indicator: cards.contains { $0.indicator },
            pendingCount: cards.reduce(0) { $0 + $1.pendingCount },
            // Ongoing first, then newest first — the writer's own order,
            // re-applied across harnesses.
            items: items.sorted { a, b in
                a.ongoing != b.ongoing ? a.ongoing : a.occurredAt > b.occurredAt
            })
    }

    /// Which harness a listed notice belongs to — its rail takes that
    /// vendor's accent.
    func harnessOfNotice(_ id: String) -> String {
        harnesses.first { ($0.notices?.items ?? []).contains { $0.id == id } }?.id
            ?? focusedHarnessID
    }

    /// The harness the focused account belongs to.
    var focusedHarnessID: String {
        focusedProfile?.providerID ?? providers[0].id
    }

    /// One harness's face — its focused account's, else its first. What a
    /// per-harness card (rates, preferences, retention) reads from.
    func store(ofHarness providerID: String) -> UsageStore? {
        let mine = profiles.filter { $0.providerID == providerID && $0.isEnrolled }
        if let focused = mine.first(where: { $0.key == focusedID }), let store = stores[focused.key] {
            return store
        }
        return mine.compactMap { stores[$0.key] }.first
    }

    /// The harnesses that can hold several homes — the ones with folders to
    /// add and discover. It is "ANY metered harness", never the focused
    /// one's: focus moves on its own, and a quiet week for Claude must not
    /// take the person's Claude accounts off the screen (0.101.0).
    var multiHomeHarnesses: [any UsageProvider] {
        accountHarnesses.filter(\.supportsMultipleHomes)
    }

    /// What the Accounts pane lists, one card each: EVERY metered harness,
    /// hidden ones included (hiding is display, not metering). A one-home
    /// harness has exactly one account and it belongs there like any other
    /// (user-reported the day 0.101.0 landed: the pane showed Claude's
    /// accounts only, as if Codex's were a different kind of thing). Before
    /// the first digest it is the multi-home providers, as it always was.
    var accountHarnesses: [any UsageProvider] {
        let listed = registry(of: harnesses.map(\.id))
        return listed.isEmpty ? providers.filter(\.supportsMultipleHomes) : listed
    }

    private func registry(of ids: [String]) -> [any UsageProvider] {
        ids.compactMap { id in providers.first { $0.id == id } }
    }

    /// The accounts of one harness, in bar order.
    func profiles(ofHarness providerID: String) -> [Profile] {
        profiles.filter { $0.providerID == providerID }
    }

    /// Hiding is a DISPLAY choice: the harness keeps being metered, and the
    /// last shown one can't be hidden. False when the host refused.
    @discardableResult
    func setHarnessShown(id: String, shown: Bool) -> Bool {
        switch role {
        case .hosting(let host):
            let ok = host.setHarnessShown(id: id, shown: shown)
            if ok { onProfilesChange?() }
            return ok
        case .client(let feed):
            // The host owns the floor rule; a client that can't ask must not
            // strand the person with an empty bar, so it checks the same one.
            var hidden = HarnessRoster.hidden(from: .standard)
            if shown {
                hidden.remove(id)
            } else {
                let shownNow = harnesses.filter(\.shown).map(\.id)
                guard shownNow.count > 1 || !shownNow.contains(id) else { return false }
                hidden.insert(id)
            }
            HarnessRoster.setHidden(hidden, in: .standard)
            feed.send(.settingsChanged)
            onProfilesChange?()
            return true
        }
    }

    /// Which profile the panel and the expanded cell show: a click's
    /// choice until the host confirms it, else the host's (or the
    /// digest's) focus — pinned, or following activity.
    var focusedID: String {
        if let manualFocusID, stores[manualFocusID] != nil { return manualFocusID }
        switch role {
        case .hosting(let host): return host.focusedProfileID ?? Profile.defaultID
        case .client(let feed): return feed.digest?.focusedProfile ?? Profile.defaultID
        }
    }
    /// By KEY: focus names an account across harnesses, and every harness's
    /// standard account has the same storage id.
    var focusedProfile: Profile? { profiles.first { $0.key == focusedID } }
    /// The host's (or the digest's) own word on focus, overlay aside.
    private var roleFocusedID: String {
        switch role {
        case .hosting(let host): host.focusedProfileID ?? Profile.defaultID
        case .client(let feed): feed.digest?.focusedProfile ?? Profile.defaultID
        }
    }
    var isClient: Bool {
        if case .client = role { return true }
        return false
    }
    /// The digest's own cells — the writer's decision, whichever process
    /// wrote it.
    var menuBarCells: [MenuBarCell] {
        let published: [MenuBarCell]
        switch role {
        case .hosting(let host): published = host.digest?.menuBarCells ?? []
        case .client(let feed): published = feed.digest?.menuBarCells ?? []
        }
        return published + fakeCells
    }
    /// `--fake-harnesses` only: a synthetic harness's row and cell, so the
    /// bar, the strip and the Harnesses card can be verified on a Mac that
    /// has just one agent installed. Empty in every ordinary run.
    private(set) var fakeHarnesses: [HarnessState] = []
    private(set) var fakeCells: [MenuBarCell] = []
    /// The strip: enrolled, enabled, awake.
    var shownProfiles: [Profile] {
        profiles.filter { $0.isEnrolled && $0.enabled && !dormantIDs.contains($0.key) }
    }
    /// The bar: shown ∧ wanted in the bar.
    var barProfiles: [Profile] { shownProfiles.filter(\.showInMenuBar) }
    /// The persistent focus choice as the faces should show it (nil =
    /// follows activity) — stored so the strip's "Auto" control tracks it
    /// in client mode too, where the source is a defaults key nobody
    /// observes.
    private(set) var pinnedID: String?
    private var storedPin: String? {
        switch role {
        case .hosting(let host): host.pin
        case .client: ProfileStore.pin(from: .standard)
        }
    }
    private var dormantIDs: Set<String> {
        switch role {
        case .hosting(let host): return host.dormant
        case .client(let feed):
            return Set((feed.digest?.profiles ?? []).filter(\.dormant).map(\.id))
        }
    }

    func store(for id: String) -> UsageStore? { stores[id] }

    /// The WRITER's resolved facts for one profile — label, monogram,
    /// dormancy, last write — decided once in the digest so every face
    /// agrees. Nil before the host has published (or from a pre-0.96
    /// daemon), where a face falls back to the record it holds.
    func section(for id: String) -> ProfileState? {
        let profiles: [ProfileState]?
        switch role {
        case .hosting(let host): profiles = host.digest?.profiles
        case .client(let feed): profiles = feed.digest?.profiles
        }
        return profiles?.first { $0.id == id }
    }

    /// A cell or strip click chooses the account — for good, bar and
    /// panel, until "Auto" hands focus back to activity (0.97.0,
    /// user-reported: the earlier open-panel-only focus reverted the moment
    /// the panel closed). The pick shows immediately; the pin it sets is
    /// what persists.
    func focus(_ id: String) {
        guard stores[id] != nil else { return }
        manualFocusID = id
        pin(id)
    }

    /// While the panel is open ACTIVITY can't move focus (an account
    /// starting to write must not swap the panel out from under the
    /// pointer); the person's own picks land regardless.
    func holdFocus(_ held: Bool) {
        if case .hosting(let host) = role { host.holdFocus(held) }
    }

    /// The persistent focus choice (nil = follows activity).
    func pin(_ id: String?) {
        if id == nil { manualFocusID = nil }
        switch role {
        case .hosting(let host): host.setPin(id)
        case .client(let feed):
            ProfileStore.setPin(id, in: .standard)
            feed.send(.focusProfile(id: id))
        }
        syncFacts()
    }

    // MARK: - Faces

    func loadProfiles() {
        let stored = ProfileStore.load(from: .standard)
        if case .hosting(let host) = role, !host.profiles.isEmpty {
            profiles = host.profiles
            return
        }
        let present = HarnessPresence.probe(
            providers: providers, stored: stored, bundleID: bundleID)
        profiles = HarnessRoster.build(
            providers: providers, present: present, stored: stored,
            hidden: HarnessRoster.hidden(from: .standard), now: Date()).profiles
    }

    /// One face per enrolled profile, every face in the process's current
    /// mode; retired faces shut down.
    func syncStores() {
        let enrolled = profiles.filter(\.isEnrolled)
        let wanted = Set(enrolled.map(\.key))
        for (key, store) in stores where !wanted.contains(key) {
            store.shutdown()
            stores[key] = nil
        }
        for profile in enrolled {
            if let store = stores[profile.key] {
                store.adopt(mode(for: profile))
            } else {
                _ = makeStore(for: profile)
            }
        }
        syncFacts()
    }

    @discardableResult
    func makeStore(for profile: Profile) -> UsageStore {
        let store = UsageStore(
            profile: profile, provider: provider(for: profile), bundleID: bundleID,
            mode: mode(for: profile))
        stores[profile.key] = store
        return store
    }

    private func mode(for profile: Profile) -> UsageStore.Mode {
        switch role {
        case .hosting(let host):
            return .hosting(host)
        case .client(let feed):
            // The digest's sections are keyed by the flat key, and several
            // harnesses' standard accounts are all called `default` on disk —
            // asking by the storage id would hand every harness's face the
            // BUNDLED harness's section.
            return .client(DigestClient(
                profileID: profile.key, storageID: profile.id, provider: provider(for: profile), feed: feed,
                bundleID: bundleID))
        }
    }

    /// THIS profile's own harness, retargeted at its home — what the Settings
    /// rows read a home's credential chain and identity path from. It reads
    /// the record's own `providerID`, never the focused harness: a foreign
    /// account retargeted at the wrong vendor would read another vendor's
    /// credentials (0.101.0).
    func provider(for profile: Profile) -> any UsageProvider {
        let base = providers.first { $0.id == profile.providerID } ?? providers[0]
        if profile.isDefault { return base }
        return profile.home.map { base.withHome($0) } ?? base
    }

    /// Pushes focus/dormancy/last-write facts into every face, and tells
    /// the status item when the focused face changed.
    func syncFacts() {
        // The click's overlay lifts once the host (or the digest) says the
        // same — from here on the persistent pin carries it.
        if let manualFocusID, manualFocusID == roleFocusedID { self.manualFocusID = nil }
        if pinnedID != storedPin { pinnedID = storedPin }
        let focused = focusedID
        let dormant = dormantIDs
        let lastWrites: [String: Date]
        switch role {
        case .hosting(let host):
            lastWrites = host.lastActivity
        case .client(let feed):
            lastWrites = Dictionary(
                (feed.digest?.profiles ?? []).compactMap { section in
                    section.lastActivityAt.map { (section.id, $0) }
                }, uniquingKeysWith: { first, _ in first })
        }
        for (id, store) in stores {
            store.isFocused = id == focused
            store.isDormant = dormant.contains(id)
            store.lastActivityAt = lastWrites[id]
        }
        if focused != lastFocusedID {
            lastFocusedID = focused
            if let store = stores[focused] { onActiveChange?(store, true) }
        }
    }

    /// Tracks the host's (or the digest's) profile facts; re-arms itself.
    /// The generation guard keeps a stale registration from re-arming
    /// against a replaced role.
    func observeRole() {
        observationGeneration += 1
        let generation = observationGeneration
        withObservationTracking {
            switch role {
            case .hosting(let host):
                _ = host.focusedProfileID
                _ = host.dormant
                _ = host.lastActivity
                _ = host.profiles
                _ = host.discoveredByHarness
                _ = host.digest
            case .client(let feed):
                _ = feed.digest
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.observationGeneration else { return }
                switch self.role {
                case .hosting(let host):
                    self.discoveredByHarness = host.discoveredByHarness
                    if host.profiles != self.profiles {
                        self.profiles = host.profiles
                        self.syncStores()
                    }
                case .client(let feed):
                    // The daemon's list is the truth in client mode: a
                    // profile it publishes that has no face here (enrolled
                    // elsewhere) gets one.
                    let published = Set((feed.digest?.profiles ?? []).map(\.id))
                    if !published.isEmpty, !published.isSubset(of: Set(self.stores.keys)) {
                        self.loadProfiles()
                        self.syncStores()
                    }
                }
                self.syncFacts()
                self.observeRole()
            }
        }
    }

    // MARK: - Harness presence

    /// A harness installed while the app ran joins the roster. The HOST does
    /// this on its own reprobe clock; a client re-reads the roster the same
    /// way the daemon built it. Nothing is torn down either way — there is no
    /// switch to make (0.101.0, replacing `redetect` + `apply`).
    func reconcilePresent() {
        switch role {
        case .hosting(let host):
            host.reprobe()
        case .client:
            let before = profiles.map(\.key)
            loadProfiles()
            guard profiles.map(\.key) != before else { return }
            syncStores()
            onProfilesChange?()
        }
    }

    // MARK: - Host arbitration

    /// The app-hosted host answers the same socket verbs usaged does, minus
    /// the process-lifecycle ones (its default refusal) — a provider switch
    /// belongs to the registry here, and nobody shuts an app down over a
    /// socket.
    private static func makeHost(
        providers: [any UsageProvider], bundleID: String, gateSeeds: [String: Date]
    ) -> MeteringHost {
        let host = MeteringHost(
            providers: providers, defaults: .standard,
            configuration: MeteringHost.Configuration(
                bundleID: bundleID, kind: .app,
                updateFeedURL: MeteringHost.Configuration.updateFeedURL(defaults: .standard)),
            gateSeeds: gateSeeds, systemAccent: systemAccent())
        host.start()
        return host
    }

    private static func daemonMarkerAge(bundleID: String) -> TimeInterval? {
        let marker = EngineHostBroker.daemonMarkerURL(bundleID: bundleID)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return Date().timeIntervalSince(modified)
    }

    /// The daemon wins: a hosting app yields the moment a daemon is alive;
    /// a client takes over only when the heartbeat is stale beyond doubt
    /// AND the lease is free. Either way EVERY face flips in one turn.
    private func evaluateRole() {
        switch role {
        case .hosting(let host):
            let markerAge = Self.daemonMarkerAge(bundleID: bundleID)
            guard EngineHostBroker.shouldYield(daemonMarkerAge: markerAge) else { return }
            // The daemon wins: stop the embedded host, free the lease and
            // the socket path, render the daemon's digest from here on.
            host.shutdown()
            lease.release()
            role = .client(DigestFeed(bundleID: bundleID))
        case .client(let feed):
            guard let staleness = feed.digestStaleness else { return }
            guard EngineHostBroker.heartbeatStale(
                generatedAt: staleness.generatedAt,
                nextPollAt: staleness.nextPollAt,
                now: Date())
            else { return }
            // The host looks dead — but a held lease is a live process, so
            // the lease decides, not the heuristic.
            guard lease.acquire() else { return }
            let seeds = feed.digest?.gateSeeds() ?? [:]
            feed.shutdown()
            role = .hosting(Self.makeHost(
                providers: providers, bundleID: bundleID, gateSeeds: seeds))
        }
        loadProfiles()
        syncStores()
        observeRole()
    }

    /// This bundle's own usaged; nil for unbundled dev runs, where ensure
    /// falls back to whatever app copy LaunchServices knows about.
    private static func embeddedUsagedBinary() -> URL? {
        let embedded = Bundle.main.bundleURL.appending(path: "Contents/MacOS/usaged")
        return FileManager.default.fileExists(atPath: embedded.path) ? embedded : nil
    }

    /// The Mac's control accent for the digest, resolved in the dark
    /// appearance so the app publishes the same sRGB the daemon's pinned
    /// `SystemAccentPalette` table would — terminal grounds are dark, and
    /// RiskRamp pins its endpoints in the same appearance.
    private static func systemAccent() -> UsageCore.RGBColor? {
        var accent: UsageCore.RGBColor?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            guard let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return }
            accent = UsageCore.RGBColor(
                red: color.redComponent, green: color.greenComponent,
                blue: color.blueComponent)
        }
        return accent
    }
}
