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
    static let bundleID = "com.avihu.ClaudeUsage"

    static func main() {
        // Embedded at Contents/MacOS, usaged inherits ClaudeUsage.app's
        // bundle identity — and suiteName == your own bundle id is
        // Foundation-nonsense (returns nil). There, `.standard` IS the
        // com.avihu.ClaudeUsage domain. Run bare (dev builds), the suite
        // reaches the same domain explicitly.
        let defaults: UserDefaults
        if Bundle.main.bundleIdentifier == bundleID {
            defaults = .standard
        } else if let suite = UserDefaults(suiteName: bundleID) {
            defaults = suite
        } else {
            fatalError("cannot open defaults suite \(bundleID)")
        }
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

        let host = DaemonHost(defaults: defaults)
        host.start()
        RunLoop.main.run()
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
            let outcome = LaunchAgentInstaller.ensure(binary: ownBinary, defaults: defaults)
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
        FileHandle.standardError.write(Data("[usaged] \(message)\n".utf8))
    }
}

/// Owns the daemon's moving parts and the metering host's lifecycle (a
/// provider switch rebuilds the host in place, keeping the lease).
@MainActor
final class DaemonHost {
    private let defaults: UserDefaults
    private let lease: EngineLease
    private var host: MeteringHost?
    private var wake: WakeMonitor?
    private var markerTimer: Timer?
    private var leaseTimer: Timer?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.lease = EngineLease(lockURL: EngineHostBroker.lockURL(bundleID: Usaged.bundleID))
    }

    func start() {
        // The marker is how a lease-holding app learns a daemon wants the
        // engine: touched every 2s from first breath to last.
        let markerURL = EngineHostBroker.daemonMarkerURL(bundleID: Usaged.bundleID)
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

    private func touchMarker() {
        let markerURL = EngineHostBroker.daemonMarkerURL(bundleID: Usaged.bundleID)
        try? Data().write(to: markerURL)
    }

    private func tryAcquire() {
        guard host == nil, lease.acquire() else { return }
        log("lease acquired — hosting the engine")
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
            from: Data(contentsOf: LiveState.fileURL(bundleID: Usaged.bundleID)))
        // No AppKit here: the user's accent choice comes from the global
        // defaults domain (visible in any process's search list), mapped
        // through the pinned dark-appearance swatch table.
        let accentChoice = UserDefaults.standard.object(
            forKey: SystemAccentPalette.defaultsKey) as? Int
        let host = MeteringHost(
            providers: providers, defaults: defaults,
            configuration: MeteringHost.Configuration(
                bundleID: Usaged.bundleID, kind: .daemon,
                updateFeedURL: MeteringHost.Configuration.updateFeedURL(defaults: defaults)),
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

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[usaged] \(message)\n".utf8))
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
