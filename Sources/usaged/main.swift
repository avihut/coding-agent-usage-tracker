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
        guard let defaults = UserDefaults(suiteName: bundleID) else {
            fatalError("cannot open defaults suite \(bundleID)")
        }
        // Pre-scope artifacts move exactly as the app would move them; on a
        // machine where the app already ran this is a marker-checked no-op.
        StorageMigration.migrate(
            support: StorageScope.rootSupportDirectory(bundleID: bundleID),
            caches: StorageScope.cachesDirectory(bundleID: bundleID, providerID: "")
                .deletingLastPathComponent(),
            providerID: "claude",
            defaults: defaults)

        let host = DaemonHost(defaults: defaults)
        host.start()
        RunLoop.main.run()
    }
}

/// Owns the daemon's moving parts and the engine's lifecycle (a provider
/// switch rebuilds the engine in place, keeping socket and lease).
@MainActor
final class DaemonHost {
    private let defaults: UserDefaults
    private let lease: EngineLease
    private var engine: UsageEngine?
    private var socket: ControlSocket?
    private var wake: WakeMonitor?
    private var markerTimer: Timer?
    private var leaseTimer: Timer?
    private var redetectTimer: Timer?
    private var activeProviderID = "claude"

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
        guard engine == nil else { return }
        let retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                self.tryAcquire()
                if self.engine != nil { self.leaseTimer?.invalidate() }
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
        guard engine == nil, lease.acquire() else { return }
        log("lease acquired — hosting the engine")
        startEngine()
        startSocket()
        wake = WakeMonitor { [weak self] in
            self?.engine?.noteWake()
        }
        scheduleDailyRedetect()
    }

    private func startEngine() {
        let provider = resolveProvider()
        activeProviderID = provider.id
        // Model names in the digest come from the active catalog, exactly
        // as the app's registry installs it.
        ModelNames.catalog = provider.modelCatalog
        // Seed the refresh gate from the previous host's digest so the
        // handover cannot double-poll inside the floor.
        let previous = try? LiveState.decoder().decode(
            LiveState.self,
            from: Data(contentsOf: LiveState.fileURL(bundleID: Usaged.bundleID)))
        engine = UsageEngine(
            provider: provider, defaults: defaults, bundleID: Usaged.bundleID,
            host: .daemon, gateSeed: previous?.engine.fetchedAt)
    }

    private func resolveProvider() -> any UsageProvider {
        let providers = HarnessResolution.standardProviders()
        let selection =
            defaults.string(forKey: HarnessResolution.selectionKey)
            ?? HarnessResolution.automatic
        let signals = HarnessDetector.rank(
            candidates: HarnessResolution.candidates(
                providers: providers, bundleID: Usaged.bundleID))
        let id = HarnessResolution.resolve(
            selection: selection, providers: providers, signals: signals)
        return providers.first { $0.id == id } ?? providers[0]
    }

    private func rebuildEngine() {
        engine?.shutdown()
        startEngine()
    }

    private func startSocket() {
        let socket = ControlSocket(
            socketURL: EngineHostBroker.socketURL(bundleID: Usaged.bundleID)
        ) { [weak self] command in
            await self?.handle(command) ?? ControlReply(ok: false, message: "host gone")
        }
        do {
            try socket.start()
            self.socket = socket
        } catch {
            log("control socket failed to bind: \(error)")
        }
    }

    private func handle(_ command: ControlCommand) async -> ControlReply {
        guard let engine else { return ControlReply(ok: false, message: "engine not running") }
        switch command {
        case .status:
            return ControlReply(
                ok: true,
                message: "daemon pid \(ProcessInfo.processInfo.processIdentifier), "
                    + "provider \(activeProviderID), v\(AppIdentity.version)")
        case .refresh:
            engine.refresh(.manual)
            return ControlReply(ok: true, message: "refresh requested (gate may coalesce)")
        case .setInterval(let seconds):
            engine.setActiveInterval(seconds)
            return ControlReply(ok: true, message: "interval \(Int(engine.activeInterval))s")
        case .setProvider(let id):
            defaults.set(id, forKey: HarnessResolution.selectionKey)
            rebuildEngine()
            return ControlReply(ok: true, message: "provider \(activeProviderID)")
        case .settingsChanged:
            engine.thresholdsChanged()
            return ControlReply(ok: true)
        case .refreshPricing:
            engine.refreshPricingNow()
            return ControlReply(ok: true)
        case .scanNow:
            engine.scanActivity(force: true)
            return ControlReply(ok: true)
        case .shutdown:
            log("shutdown by socket command")
            engine.shutdown()
            socket?.stop()
            lease.release()
            // Reply races process exit by design; the socket write happens
            // before this task yields back.
            Task { @MainActor in exit(0) }
            return ControlReply(ok: true, message: "stopping")
        }
    }

    /// Auto mode follows the machine: a daily pass re-ranks the harness
    /// signals and rebuilds onto the winner when it changed.
    private func scheduleDailyRedetect() {
        let timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let selection =
                    self.defaults.string(forKey: HarnessResolution.selectionKey)
                    ?? HarnessResolution.automatic
                guard selection == HarnessResolution.automatic else { return }
                let winner = self.resolveProvider()
                if winner.id != self.activeProviderID {
                    self.log("redetect: \(self.activeProviderID) → \(winner.id)")
                    self.rebuildEngine()
                }
            }
        }
        timer.tolerance = 3600
        redetectTimer = timer
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
