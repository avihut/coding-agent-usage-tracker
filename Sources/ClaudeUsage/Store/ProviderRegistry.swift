import AppKit
import Foundation
import Observation
import UsageCore

/// The one place a vendor is chosen — and, since 0.96.0, the one place
/// this process decides whether it HOSTS metering or renders a daemon's
/// digest, and which profiles (accounts) it shows. Knows every harness
/// this build can meter, detects which one is actually in use, owns the
/// engine lease and the host arbitration (the daemon wins; a client takes
/// over only when the heartbeat is stale beyond doubt AND the lease is
/// free), keeps one `UsageStore` face per enrolled profile of the active
/// provider, and resolves the focused one. Exactly one provider is active
/// at a time — switching retires the host and every face.
@MainActor
@Observable
final class ProviderRegistry {
    static let selectionKey = HarnessResolution.selectionKey
    static let automatic = HarnessResolution.automatic

    /// A Metering picker row.
    struct HarnessChoice: Identifiable, Equatable {
        let id: String
        let name: String
    }

    /// Which side of the engine this process runs.
    enum Role {
        case hosting(MeteringHost)
        case client(DigestFeed)
    }

    /// Every provider this build ships, bundled default first — the
    /// tie-break order when detection sees an all-quiet machine.
    let providers: [any UsageProvider]
    let bundleID: String
    /// Presence + recency per harness, most-active first; refreshed by
    /// every detection pass. Settings renders these.
    private(set) var signals: [HarnessSignal]
    /// "auto" or a provider id — the user's persisted Metering choice.
    private(set) var selection: String
    private(set) var activeID: String
    private(set) var role: Role
    /// Every record for the active provider (enrolled and dismissed alike),
    /// the implicit default first.
    private(set) var profiles: [Profile] = []
    /// One face per enrolled profile.
    private(set) var stores: [String: UsageStore] = [:]
    /// Homes found beside the standard one that nobody decided about.
    private(set) var discoveredHomes: [DiscoveredHome] = []
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

    /// `launchOverride` is the `--provider <id>` verification hatch: it
    /// wins for this launch without touching the persisted choice.
    init(bundleID: String, launchOverride: String? = nil) {
        let providers = HarnessResolution.standardProviders()
        self.providers = providers
        self.bundleID = bundleID
        let stored = UserDefaults.standard.string(forKey: Self.selectionKey) ?? Self.automatic
        let selection = launchOverride ?? stored
        self.selection = selection
        let signals = HarnessDetector.rank(
            candidates: HarnessResolution.candidates(providers: providers, bundleID: bundleID))
        self.signals = signals
        let activeID = HarnessResolution.resolve(
            selection: selection, providers: providers, signals: signals)
        self.activeID = activeID
        // Catalog + style install before any UI renders or scan runs —
        // display names and accent colors read them from everywhere.
        let active = providers.first { $0.id == activeID } ?? providers[0]
        ModelNames.catalog = active.modelCatalog
        ProviderStyle.install(active)
        MenuBarPreferences.migrateLegacyStyle(provider: active)

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
                provider: active, bundleID: bundleID, gateSeeds: previous?.gateSeeds() ?? [:]))
        } else {
            let feed = DigestFeed(bundleID: bundleID)
            role = .client(feed)
            // An explicit Metering pick must reach the daemon; auto
            // converges on its own (same selection key, same signals).
            if selection != Self.automatic, selection == active.id {
                feed.send(.setProvider(id: active.id))
            }
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
        ) { _ in
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
        scheduleDailyRedetect()
    }

    // MARK: - Faces and focus

    /// The FOCUSED profile's face — every pre-profile call site keeps
    /// reading the one store that matters.
    var activeStore: UsageStore { focusedStore }
    var focusedStore: UsageStore {
        stores[focusedID] ?? stores[Profile.defaultID] ?? stores.values.first
            ?? makeStore(for: Profile.standard(for: activeProvider, addedAt: Date()))
    }
    var activeProvider: any UsageProvider { provider(for: activeID) }

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
    var focusedProfile: Profile? { profiles.first { $0.id == focusedID } }
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
        switch role {
        case .hosting(let host): host.digest?.menuBarCells ?? []
        case .client(let feed): feed.digest?.menuBarCells ?? []
        }
    }
    /// The strip: enrolled, enabled, awake.
    var shownProfiles: [Profile] {
        profiles.filter { $0.isEnrolled && $0.enabled && !dormantIDs.contains($0.id) }
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

    /// What a face calls a profile: the digest's word when it has one,
    /// else the record's own.
    func label(for profile: Profile) -> String {
        section(for: profile.id)?.label ?? ProfileFacts.label(profile: profile, identity: nil)
    }

    func monogram(for profile: Profile) -> String {
        section(for: profile.id)?.monogram
            ?? ProfileFacts.monogram(profile: profile, label: label(for: profile))
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

    // MARK: - Profile edits (Settings)

    func enroll(home: URL, nickname: String? = nil) {
        let provider = activeProvider
        guard provider.supportsMultipleHomes, let standard = provider.homeDirectory else { return }
        let id = ProfileID.forHome(home, standard: standard)
        var stored = ProfileStore.load(from: .standard)
        if let index = stored.firstIndex(where: { $0.id == id && $0.providerID == provider.id }) {
            // A dismissed discovery, adopted after all.
            let old = stored[index]
            stored[index] = Profile(
                id: id, providerID: provider.id, home: home, nickname: nickname ?? old.nickname,
                monogram: old.monogram, enabled: true, showInMenuBar: true, order: old.order,
                addedAt: Date(), ignoredIdentityKey: nil)
        } else {
            let order = (stored.filter { $0.providerID == provider.id }.map(\.order).max() ?? 0) + 1
            stored.append(Profile(
                id: id, providerID: provider.id, home: home, nickname: nickname, order: order,
                addedAt: Date()))
        }
        ProfileStore.save(stored, to: .standard)
        profilesChanged()
    }

    /// Removes the record; `deletingData` also removes THIS APP's scoped
    /// directories for the profile — never anything inside the home.
    func remove(id: String, deletingData: Bool) {
        guard id != Profile.defaultID else { return }
        var stored = ProfileStore.load(from: .standard)
        stored.removeAll { $0.id == id && $0.providerID == activeID }
        ProfileStore.save(stored, to: .standard)
        if deletingData {
            for directory in [
                StorageScope.supportDirectory(bundleID: bundleID, providerID: activeID, profileID: id),
                StorageScope.cachesDirectory(bundleID: bundleID, providerID: activeID, profileID: id),
            ] {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        profilesChanged()
    }

    /// "Not now" on a discovered home: remembered as a record carrying the
    /// sign-in it holds TODAY, so the offer stays silent until that
    /// changes — never a permanent silence (D2).
    func dismissDiscovered(_ home: DiscoveredHome) {
        var stored = ProfileStore.load(from: .standard)
        stored.removeAll { $0.id == home.profileID && $0.providerID == activeID }
        stored.append(Profile(
            id: home.profileID, providerID: activeID, home: home.home, enabled: false,
            addedAt: Date(), ignoredIdentityKey: home.identity?.key ?? ""))
        ProfileStore.save(stored, to: .standard)
        discoveredHomes.removeAll { $0.profileID == home.profileID }
        profilesChanged()
    }

    func setProfileEnabled(id: String, enabled: Bool) {
        edit(id) { $0.enabled = enabled }
    }

    func setShowInMenuBar(id: String, shown: Bool) {
        edit(id) { $0.showInMenuBar = shown }
    }

    func setMenuBarForm(id: String, form: MenuBarForm) {
        edit(id) { $0.menuBarForm = form }
    }

    /// The account's own element list (0.98.0) — what its cell holds when
    /// the bar draws each account its own way.
    func setMenuBarElements(id: String, elements: [MenuBarElement]) {
        edit(id) { $0.menuBarElements = MenuBarLayout.normalized(elements) }
    }

    func setOwnMenuBarItem(id: String, own: Bool) {
        edit(id) { $0.ownMenuBarItem = own }
    }

    /// The bar's (and the strip's) order: `ids` in the order wanted; any
    /// enrolled profile not named keeps its place after them.
    func reorder(_ ids: [String]) {
        let rest = profiles.filter { $0.isEnrolled && !ids.contains($0.id) }.map(\.id)
        let order = ids + rest
        editAll { profile in
            if let index = order.firstIndex(of: profile.id) { profile.order = index }
        }
    }

    func rename(id: String, nickname: String?) {
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        edit(id) { $0.nickname = (trimmed?.isEmpty ?? true) ? nil : trimmed }
    }

    private func edit(_ id: String, _ body: (inout Profile) -> Void) {
        var stored = ProfileStore.load(from: .standard)
        if let index = stored.firstIndex(where: { $0.id == id && $0.providerID == activeID }) {
            body(&stored[index])
        } else if let record = profiles.first(where: { $0.id == id }) {
            var copy = record
            body(&copy)
            stored.append(copy)
        } else {
            return
        }
        ProfileStore.save(stored, to: .standard)
        profilesChanged()
    }

    /// One edit over every enrolled record of the active provider — the
    /// implicit default gets a stored record the moment it differs.
    private func editAll(_ body: (inout Profile) -> Void) {
        var stored = ProfileStore.load(from: .standard)
        for record in profiles where record.isEnrolled {
            if let index = stored.firstIndex(where: { $0.id == record.id && $0.providerID == activeID }) {
                body(&stored[index])
            } else {
                var copy = record
                body(&copy)
                stored.append(copy)
            }
        }
        ProfileStore.save(stored, to: .standard)
        profilesChanged()
    }

    /// Re-reads the store, tells the host (or the daemon), and rebuilds
    /// the faces.
    private func profilesChanged() {
        loadProfiles()
        switch role {
        case .hosting(let host): host.reloadProfiles()
        case .client(let feed): feed.send(.profilesChanged)
        }
        syncStores()
        onProfilesChange?()
    }

    /// Looks for homes beside the standard one (read-only) — the Settings
    /// card's "Found" rows. A hosting process already has the host's list.
    func discover() {
        if case .hosting(let host) = role {
            discoveredHomes = host.discovered
            return
        }
        let provider = activeProvider
        let known = profiles
        let bundleID = bundleID
        Task.detached(priority: .utility) { [weak self] in
            let found = ProfileDiscovery.discover(
                provider: provider, known: known, bundleID: bundleID, now: Date())
            await MainActor.run { [weak self] in self?.discoveredHomes = found }
        }
    }

    /// The `--fake-profiles` hatch: a synthetic profile with a fixed face,
    /// so the strip, the cells, and the Settings rows can be verified on a
    /// one-account machine.
    func installFakeProfile(_ profile: Profile, store: UsageStore) {
        profiles.removeAll { $0.id == profile.id }
        profiles.append(profile)
        stores[profile.id] = store
        syncFacts()
        onProfilesChange?()
    }

    private func loadProfiles() {
        profiles = ProfileStore.resolved(
            ProfileStore.load(from: .standard), provider: activeProvider, now: Date())
    }

    /// One face per enrolled profile, every face in the process's current
    /// mode; retired faces shut down.
    private func syncStores() {
        let enrolled = profiles.filter(\.isEnrolled)
        let wanted = Set(enrolled.map(\.id))
        for (id, store) in stores where !wanted.contains(id) {
            store.shutdown()
            stores[id] = nil
        }
        for profile in enrolled {
            if let store = stores[profile.id] {
                store.adopt(mode(for: profile))
            } else {
                _ = makeStore(for: profile)
            }
        }
        syncFacts()
    }

    @discardableResult
    private func makeStore(for profile: Profile) -> UsageStore {
        let store = UsageStore(
            profile: profile, provider: provider(for: profile), bundleID: bundleID,
            mode: mode(for: profile))
        stores[profile.id] = store
        return store
    }

    private func mode(for profile: Profile) -> UsageStore.Mode {
        switch role {
        case .hosting(let host):
            return .hosting(host)
        case .client(let feed):
            return .client(DigestClient(
                profileID: profile.id, provider: provider(for: profile), feed: feed,
                bundleID: bundleID))
        }
    }

    /// The active provider retargeted at one profile's home — what the
    /// Settings rows read a home's credential chain and identity path from.
    func provider(for profile: Profile) -> any UsageProvider {
        let base = activeProvider
        if profile.isDefault { return base }
        return profile.home.map { base.withHome($0) } ?? base
    }

    /// Pushes focus/dormancy/last-write facts into every face, and tells
    /// the status item when the focused face changed.
    private func syncFacts() {
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
    private func observeRole() {
        observationGeneration += 1
        let generation = observationGeneration
        withObservationTracking {
            switch role {
            case .hosting(let host):
                _ = host.focusedProfileID
                _ = host.dormant
                _ = host.lastActivity
                _ = host.profiles
                _ = host.discovered
            case .client(let feed):
                _ = feed.digest
            }
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, generation == self.observationGeneration else { return }
                switch self.role {
                case .hosting(let host):
                    self.discoveredHomes = host.discovered
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

    // MARK: - Harness selection

    /// Rows for the Metering pickers: only harnesses that exist on this
    /// machine are offered.
    var presentChoices: [HarnessChoice] {
        signals.filter(\.present).compactMap { signal in
            providers.first { $0.id == signal.id }
                .map { HarnessChoice(id: $0.id, name: $0.agentName) }
        }
    }

    /// "Automatic (Claude Code)" — names what auto currently resolves to.
    var automaticLabel: String {
        let autoID = HarnessResolution.resolve(
            selection: Self.automatic, providers: providers, signals: signals)
        return "Automatic (\(provider(for: autoID).agentName))"
    }

    /// The user picked from a Metering menu. Persists and applies now.
    func select(_ choice: String) {
        selection = choice
        UserDefaults.standard.set(choice, forKey: Self.selectionKey)
        apply(deferrable: false)
    }

    /// Re-runs detection off-main (the stat walk is capped but a cold disk
    /// shouldn't stall the main thread) and applies the outcome. Auto mode
    /// may switch the active harness; an explicit choice only refreshes
    /// the signals shown in Settings.
    func redetect(deferrable: Bool) {
        let candidates = HarnessResolution.candidates(providers: providers, bundleID: bundleID)
        Task.detached(priority: .utility) {
            let signals = HarnessDetector.rank(candidates: candidates)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.signals = signals
                self.apply(deferrable: deferrable)
            }
        }
    }

    /// A vendor switch retires the host (or tells the daemon) and every
    /// face, then rebuilds both for the winner.
    private func apply(deferrable: Bool) {
        let winner = HarnessResolution.resolve(
            selection: selection, providers: providers, signals: signals)
        guard winner != activeID else { return }
        activeID = winner
        let active = provider(for: winner)
        ModelNames.catalog = active.modelCatalog
        ProviderStyle.install(active)
        for store in stores.values { store.shutdown() }
        stores = [:]
        manualFocusID = nil
        lastFocusedID = nil
        switch role {
        case .hosting(let host):
            host.shutdown()
            role = .hosting(Self.makeHost(provider: active, bundleID: bundleID, gateSeeds: [:]))
        case .client(let feed):
            feed.send(.setProvider(id: winner))
        }
        loadProfiles()
        syncStores()
        observeRole()
        onActiveChange?(activeStore, deferrable)
    }

    private func provider(for id: String) -> any UsageProvider {
        providers.first { $0.id == id } ?? providers[0]
    }

    private func scheduleDailyRedetect() {
        let timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.selection == Self.automatic else { return }
                self.redetect(deferrable: true)
            }
        }
        timer.tolerance = 3600
        redetectTimer = timer
    }

    // MARK: - Host arbitration

    /// The app-hosted host answers the same socket verbs usaged does, minus
    /// the process-lifecycle ones (its default refusal) — a provider switch
    /// belongs to the registry here, and nobody shuts an app down over a
    /// socket.
    private static func makeHost(
        provider: any UsageProvider, bundleID: String, gateSeeds: [String: Date]
    ) -> MeteringHost {
        let host = MeteringHost(
            provider: provider, defaults: .standard,
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
                provider: activeProvider, bundleID: bundleID, gateSeeds: seeds))
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
