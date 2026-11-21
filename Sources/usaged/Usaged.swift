import Foundation
import IOKit
import IOKit.pwr_mgt
import UsageCore

/// The launchd user agent: runs THE engine headless so consumer interfaces
/// (the TUI, the app in client mode) render with no menu bar app open.
/// Same core, same rules — §10 read-only trees, the 180s floor, the signed
/// identity for Keychain reads. The daemon wins host arbitration: it
/// announces itself via the daemon.alive marker, waits for the app to
/// release the engine lease, then holds it until told to stop.
///
/// Lifecycle: storage migration → provider resolution (the SAME
/// HarnessResolution rules the app's registry uses) → announce + wait for
/// the lease → engine with the app's suite defaults → control socket →
/// IOKit wake → daily re-detection → run loop forever. launchd restarts on
/// crash (KeepAlive); `usage-cli daemon stop` boots it out.
@main
@MainActor
struct Usaged {
    static let bundleID = AppIdentity.bundleID

    static func main() {
        ProcessSignals.ignoreBrokenPipes()
        StartupTrace.shared.sink = { note($0) }
        StartupTrace.shared.mark(
            "main",
            StartupTrace.processStartDate().map {
                "process started " + $0.formatted(.iso8601.time(includingFractionalSeconds: true))
            })
        // A measuring copy of the engine (Phase 0 of the 2026-11-21 load
        // work): its own bundle id, roots and defaults suite, offline usage
        // services — and NEITHER migration, which run against the standard
        // roots and the live domain.
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "run-isolated" {
            runIsolated(Array(CommandLine.arguments.dropFirst(2)))
        }
        // Embedded at Contents/MacOS, usaged inherits AgentUsage.app's
        // bundle identity — and suiteName == your own bundle id is
        // Foundation-nonsense (returns nil). There, `.standard` IS the
        // io.github.avihut.AgentUsage domain. Run bare (dev builds), the suite
        // reaches the same domain explicitly.
        let defaults: UserDefaults
        if Bundle.main.bundleIdentifier == bundleID {
            defaults = .standard
        } else if let suite = UserDefaults(suiteName: bundleID) {
            defaults = suite
        } else {
            fatalError("cannot open defaults suite \(bundleID)")
        }
        // An install that was ClaudeUsage carries its data and settings over
        // first — ahead of the installer verbs too, which read the sticky
        // `daemonAutoInstall` opt-out out of the very defaults being carried.
        IdentityMigration.standard(defaults: defaults)
        // With an argument, usaged is its own installer (spec §10
        // re-amendment: the UI entry points auto-install by asking the
        // embedded binary to register itself). No arguments — launchd's
        // spelling — runs the engine.
        if CommandLine.arguments.count > 1 {
            runInstallerVerb(CommandLine.arguments[1], defaults: defaults)
        }
        // Pre-scope artifacts move exactly as the app would move them; on a
        // machine where the app already ran this is a marker-checked no-op.
        StorageMigration.migrate(
            support: StorageScope.rootSupportDirectory(bundleID: bundleID),
            caches: StorageScope.cachesRootDirectory(bundleID: bundleID),
            providerID: "claude",
            providerIDs: HarnessResolution.standardProviders().map(\.id),
            defaults: defaults)
        StartupTrace.shared.mark("migrations")

        let host = DaemonHost(defaults: defaults)
        host.start()
        RunLoop.main.run()
    }

    /// `usaged run-isolated --root <dir> [--bundle-id <id>] [--socket <path>]
    /// [--copy-profiles]`:
    /// the engine exactly as launchd runs it, against storage under `<dir>`
    /// and a defaults suite of its own, so it can be measured under load
    /// without touching the live install. Usage services for networked
    /// harnesses are OFFLINE — no credential read, no request, the cache
    /// served as a network failure would serve it — so it is never a second
    /// poller of the person's account. No status poller, no update checker.
    /// Agent homes are read the way the scanners always read them: read-only.
    /// `--copy-profiles` copies the account records (read-only) out of the
    /// app's domain, so it meters the same homes the live host does.
    private static func runIsolated(_ arguments: [String]) -> Never {
        var root: String?
        var isolatedID = AppIdentity.bundleID + ".isolated"
        var copyProfiles = false
        var socket: URL?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--root" where index + 1 < arguments.count:
                root = arguments[index + 1]
                index += 1
            case "--bundle-id" where index + 1 < arguments.count:
                isolatedID = arguments[index + 1]
                index += 1
            case "--socket" where index + 1 < arguments.count:
                // A unix socket path is capped at 104 bytes; a deep root needs
                // its socket somewhere shorter.
                socket = URL(fileURLWithPath: arguments[index + 1])
                index += 1
            case "--copy-profiles":
                copyProfiles = true
            default:
                note("run-isolated: unknown argument '\(arguments[index])'")
                exit(2)
            }
            index += 1
        }
        guard let root, isolatedID != AppIdentity.bundleID,
              let defaults = UserDefaults(suiteName: isolatedID)
        else {
            note("run-isolated: needs --root <dir> and a bundle id other than the app's")
            exit(2)
        }
        let base = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        let roots = StorageScope.Roots(
            support: base.appending(path: "support"), caches: base.appending(path: "caches"))
        if copyProfiles, let live = UserDefaults(suiteName: AppIdentity.bundleID) {
            for key in [ProfileStore.profilesKey, ProfileStore.pinKey, HarnessRoster.hiddenKey] {
                if let value = live.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }
        note("run-isolated: \(isolatedID) under \(base.path)")
        let host = DaemonHost(
            defaults: defaults, bundleID: isolatedID, roots: roots, isolated: true, socketURL: socket)
        host.start()
        RunLoop.main.run()
        exit(0)
    }

    /// `usaged install|ensure|uninstall`: the plist points at this very
    /// executable, so whichever bundle's usaged runs the verb is the one
    /// launchd keeps. `ensure` is the auto-install entry (the TUI spawns
    /// it) and honors the sticky opt-out; `install`/`uninstall` are
    /// explicit user intent and re-arm/disarm it.
    private static func runInstallerVerb(_ verb: String, defaults: UserDefaults) -> Never {
        let ownBinary = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL.resolvingSymlinksInPath()
        switch verb {
        case "install":
            LaunchAgentInstaller.setAutoInstall(true, defaults: defaults)
            do {
                try LaunchAgentInstaller.install(binary: ownBinary)
                note("installed \(LaunchAgentInstaller.label) → \(ownBinary.path)")
                exit(0)
            } catch {
                note("install failed: \(error)")
                exit(1)
            }
        case "ensure":
            // The self-heal a face runs when it finds no engine publishing:
            // never against a live host, never repointing an existing target.
            let outcome = LaunchAgentInstaller.ensure(
                binary: ownBinary, defaults: defaults, intent: .heal)
            note("ensure: \(outcome)")
            if case .failed = outcome { exit(1) }
            exit(0)
        case "uninstall":
            LaunchAgentInstaller.setAutoInstall(false, defaults: defaults)
            LaunchAgentInstaller.uninstall()
            note("uninstalled \(LaunchAgentInstaller.label) (sticky: auto-install off)")
            exit(0)
        default:
            note("unknown verb '\(verb)' — install|ensure|uninstall (no arguments runs the engine)")
            exit(2)
        }
    }

    private static func note(_ message: String) {
        // The throwing write: with SIGPIPE ignored, a closed stderr is an
        // error to drop, where the legacy `write(_:)` raises an exception.
        try? FileHandle.standardError.write(contentsOf: Data("[usaged] \(message)\n".utf8))
    }
}

/// Owns the daemon's moving parts and the metering host's lifecycle (a
/// provider switch rebuilds the host in place, keeping the lease).
@MainActor
final class DaemonHost {
    private let defaults: UserDefaults
    private let bundleID: String
    private let roots: StorageScope.Roots
    /// `usaged run-isolated`: offline services, no status poller, no update
    /// checker.
    private let isolated: Bool
    private let socketURL: URL?
    private let lease: EngineLease
    private var host: MeteringHost?
    private var wake: WakeMonitor?
    private var markerTimer: Timer?
    private var leaseTimer: Timer?

    init(
        defaults: UserDefaults, bundleID: String = Usaged.bundleID,
        roots: StorageScope.Roots = .standard, isolated: Bool = false, socketURL: URL? = nil
    ) {
        self.socketURL = socketURL
        self.defaults = defaults
        self.bundleID = bundleID
        self.roots = roots
        self.isolated = isolated
        self.lease = EngineLease(lockURL: EngineHostBroker.lockURL(bundleID: bundleID, roots: roots))
    }

    func start() {
        // The marker is how a lease-holding app learns a daemon wants the
        // engine: touched every 2s from first breath to last.
        let markerURL = EngineHostBroker.daemonMarkerURL(bundleID: bundleID, roots: roots)
        try? FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        touchMarker()
        let marker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in self.touchMarker() }
        }
        marker.tolerance = 0.5
        markerTimer = marker

        tryAcquire()
        guard host == nil else { return }
        let retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                self.tryAcquire()
                if self.host != nil { self.leaseTimer?.invalidate() }
            }
        }
        retry.tolerance = 0.5
        leaseTimer = retry
    }

    /// Who this daemon is and which build it runs — `ensure` compares it with
    /// the binary on disk. Encoded once; the 2 s rewrite is the heartbeat.
    private lazy var markerContent = DaemonMarker.current().encoded()

    private func touchMarker() {
        let markerURL = EngineHostBroker.daemonMarkerURL(bundleID: bundleID, roots: roots)
        // Atomic: `ensure` may read it at any moment and must never see a
        // torn half (it would read as unknown, which is safe, but useless).
        try? markerContent.write(to: markerURL, options: .atomic)
    }

    private func tryAcquire() {
        guard host == nil, lease.acquire() else { return }
        log("lease acquired — hosting the engine")
        StartupTrace.shared.mark("lease")
        startHost()
        wake = WakeMonitor { [weak self] in
            self?.host?.noteWake()
        }
    }

    /// The host binds the control socket, meters EVERY harness found on this
    /// machine — one `ProviderServices` per vendor, one engine per enrolled
    /// account — and folds the digest. Nothing is "the active provider" any
    /// more (0.101.0): the host probes presence itself and grows its roster on
    /// its own reprobe clock, so there is no winner to resolve and nothing to
    /// rebuild when the machine changes.
    private func startHost() {
        let providers = HarnessResolution.standardProviders()
        // Model names in the digest span every harness, exactly as the app's
        // registry installs them.
        ModelNames.catalog = ModelCatalog.union(of: HarnessResolution.standardProviders())
        // Seed each profile's refresh gate from the previous host's digest
        // so the handover cannot double-poll inside the floor.
        let previous = try? LiveState.decoder().decode(
            LiveState.self,
            from: Data(contentsOf: LiveState.fileURL(bundleID: bundleID, roots: roots)))
        StartupTrace.shared.mark("previous digest", previous == nil ? "none" : "decoded")
        // No AppKit here: the user's accent choice comes from the global
        // defaults domain (visible in any process's search list), mapped
        // through the pinned dark-appearance swatch table.
        let accentChoice = UserDefaults.standard.object(
            forKey: SystemAccentPalette.defaultsKey) as? Int
        let bundleID = bundleID
        let roots = roots
        let host = MeteringHost(
            providers: providers, defaults: defaults,
            configuration: MeteringHost.Configuration(
                bundleID: bundleID, kind: .daemon, roots: roots, pollsStatus: !isolated,
                updateFeedURL: isolated
                    ? nil : MeteringHost.Configuration.updateFeedURL(defaults: defaults),
                socketURL: socketURL,
                // The engine host may run an agent's own tool for its plan
                // limits (the quota probe, spec §10 amendment 2026-11-21,
                // second). Never an isolated measuring copy: it is offline,
                // and must not spawn the vendor's CLI against the person's sign-in.
                agentCommandRunner: isolated ? nil : SpawnedCommandRunner()),
            serviceFactory: isolated
                ? { profile in Self.offlineService(profile, providers: providers, bundleID: bundleID, roots: roots) }
                : nil,
            gateSeeds: previous?.gateSeeds() ?? [:],
            systemAccent: SystemAccentPalette.color(appleAccentColor: accentChoice))
        host.onLog = { [weak self] message in self?.log(message) }
        // Kept decodable, and a no-op since 0.101.0: every harness is
        // metered, so there is nothing to switch to. An old face's verb must
        // not look like it worked.
        host.onSetProvider = { [weak self] id in
            self?.log("setProvider \(id): ignored — every harness is metered")
            return ControlReply(
                ok: false, message: "every detected harness is metered; nothing to switch")
        }
        host.onShutdown = { [weak self] in
            guard let self else { return ControlReply(ok: false, message: "host gone") }
            self.log("shutdown by socket command")
            self.host?.shutdown()
            self.lease.release()
            // Reply races process exit by design; the socket write happens
            // before this task yields back.
            Task { @MainActor in exit(0) }
            return ControlReply(ok: true, message: "stopping")
        }
        self.host = host
        host.start()
    }

    /// The isolated host's usage service for one account: offline for a
    /// networked harness (the cache, never a request); nil — the real local
    /// pipeline — for a harness that reads its own files.
    private static func offlineService(
        _ profile: Profile, providers: [any UsageProvider], bundleID: String,
        roots: StorageScope.Roots
    ) -> UsageService? {
        guard let base = providers.first(where: { $0.id == profile.providerID }),
              !base.networkDestinations.isEmpty
        else { return nil }
        let provider = profile.isDefault ? base : (profile.home.map { base.withHome($0) } ?? base)
        return UsageService(
            provider: provider,
            cache: UsageCache(directory: StorageScope.cachesDirectory(
                bundleID: bundleID, providerID: profile.providerID, profileID: profile.id,
                roots: roots)),
            offline: true)
    }

    private func log(_ message: String) {
        // The throwing write: with SIGPIPE ignored, a closed stderr is an
        // error to drop, where the legacy `write(_:)` raises an exception.
        try? FileHandle.standardError.write(contentsOf: Data("[usaged] \(message)\n".utf8))
    }
}

/// IOKit system-power notifications → `noteWake()`. Registering for power
/// events obliges us to acknowledge sleep transitions promptly, or macOS
/// waits out a 30s timeout on every lid close.
@MainActor
final class WakeMonitor {
    private let onWake: () -> Void
    private var rootPort: io_connect_t = 0
    /// nonisolated(unsafe): set once in init, read in deinit — the same
    /// monitor-token concession HorizontalSwipeCatcher documents.
    nonisolated(unsafe) private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init?(onWake: @escaping () -> Void) {
        self.onWake = onWake
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(
            refcon, &notifyPort,
            { refcon, _, messageType, argument in
                guard let refcon else { return }
                let monitor = Unmanaged<WakeMonitor>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated {
                    monitor.handle(messageType: messageType, argument: argument)
                }
            }, &notifier)
        guard rootPort != 0, let notifyPort else { return nil }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(),
            .defaultMode)
    }

    // IOMessage.h's iokit_common_msg() macros don't survive the Swift
    // importer; these are their expanded values, stable ABI since 10.0.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case Self.systemWillSleep, Self.canSystemSleep:
            // Never veto or delay sleep — acknowledge immediately.
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemHasPoweredOn:
            onWake()
        default:
            break
        }
    }

    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        if rootPort != 0 { IOServiceClose(rootPort) }
    }
}
