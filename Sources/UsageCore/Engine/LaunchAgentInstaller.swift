import CoreServices
import Foundation

/// The one sanctioned launch-agent registration (spec §10): writes and
/// bootstraps `io.github.avihut.usaged`, pointing launchd at the usaged binary
/// embedded in AgentUsage.app.
///
/// Since the 2026-08-16 re-amendment, installation is automatic for
/// convenience: the app converges the agent at launch and the TUI asks
/// `usaged ensure` when it finds no engine. The user's control is the
/// sticky opt-out — `daemonAutoInstall` — which uninstall paths set to
/// false and every auto-install path honors. Mechanism lives here;
/// policy is only ever flipped by an explicit user action (the CLI verbs,
/// the Settings toggle).
public enum LaunchAgentInstaller {
    public static let label = AppIdentity.daemonLabel
    /// Sticky opt-out. Absent means allowed: auto-install is the default,
    /// and only a deliberate uninstall writes `false`.
    public static let autoInstallKey = "daemonAutoInstall"

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(label).plist")
    }

    /// launchctl seam — tests inject a recorder instead of the real binary.
    public typealias CommandRunner = ([String]) -> (status: Int32, output: String)

    // MARK: - Policy flag

    public static func autoInstallAllowed(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: autoInstallKey) == nil
            ? true : defaults.bool(forKey: autoInstallKey)
    }

    public static func setAutoInstall(_ allowed: Bool, defaults: UserDefaults) {
        defaults.set(allowed, forKey: autoInstallKey)
    }

    // MARK: - Mechanism

    public enum InstallError: Error, CustomStringConvertible {
        case plistWrite(String)
        case bootstrap(String)

        public var description: String {
            switch self {
            case .plistWrite(let detail): "cannot write launch agent plist: \(detail)"
            case .bootstrap(let detail): "launchctl bootstrap failed: \(detail)"
            }
        }
    }

    /// How long `install` waits for a booted-out agent to leave launchd's
    /// domain, and how it retries a bootstrap launchd refuses meanwhile.
    static let leaveDomainBudget: TimeInterval = 5
    static let bootstrapRetryDelays: [TimeInterval] = [0.2, 0.4, 0.8, 1.6]
    /// `launchctl bootstrap`'s answers while the old instance is still being
    /// torn down: 5 (Input/output error) and 37 (Operation already in
    /// progress) — issue #9, both seen in launchd's own log.
    static let transientBootstrapStatuses: Set<Int32> = [5, 37]

    /// Writes the plist and (re)bootstraps the agent. Idempotent: an
    /// existing registration is booted out first, so this is also the
    /// repair, repoint and plist-upgrade path.
    ///
    /// `bootout` returns as soon as launchd has been TOLD; the daemon is still
    /// flushing its ledgers, and a `bootstrap` inside that window fails — and
    /// left the agent installed but unloaded, with no daemon at all (issue #9;
    /// the shape of the fix follows PR #22). So: wait, bounded, for the
    /// service to leave the domain, then bootstrap, retrying the transient
    /// refusals with a short backoff. `sleep` is the tests' seam.
    public static func install(
        binary: URL, runner: CommandRunner = launchctl,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws {
        let data: Data
        do {
            data = try plistData(binary: binary)
        } catch {
            throw InstallError.plistWrite("\(error)")
        }
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: plistURL)
        } catch {
            throw InstallError.plistWrite("\(plistURL.path): \(error)")
        }
        let result = reload(plist: plistURL.path, runner: runner, sleep: sleep)
        guard result.status == 0 else {
            throw InstallError.bootstrap("status \(result.status): \(result.output)")
        }
    }

    /// Boots the registration out, waits for it to leave the domain, and
    /// bootstraps `plist` — retrying launchd's transient refusals. Writes
    /// nothing, so the tests drive it with a recorder and never the real
    /// LaunchAgents directory. The last bootstrap's answer comes back.
    static func reload(
        plist: String, runner: CommandRunner, sleep: (TimeInterval) -> Void
    ) -> (status: Int32, output: String) {
        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(label)"
        _ = runner(["bootout", service])
        // Wait while launchd still lists the service, whatever bootout said:
        // a teardown in progress can answer non-zero too. Bounded by the
        // sleeps AND the wall clock — each `print` is a spawn, slow under load.
        var waited: TimeInterval = 0
        let deadline = Date().addingTimeInterval(leaveDomainBudget)
        while runner(["print", service]).status == 0, waited < leaveDomainBudget, Date() < deadline {
            sleep(0.1)
            waited += 0.1
        }
        var result = runner(["bootstrap", domain, plist])
        for delay in bootstrapRetryDelays {
            guard result.status != 0, transientBootstrapStatuses.contains(result.status) else { break }
            sleep(delay)
            result = runner(["bootstrap", domain, plist])
        }
        return result
    }

    /// Boots the agent out and removes the plist. Flag handling is the
    /// caller's: user-initiated paths also set the sticky opt-out.
    public static func uninstall(runner: CommandRunner = launchctl) {
        _ = runner(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// The agent under the label it carried through 0.101.0. Booted out and
    /// its plist removed so no old engine keeps writing to the old
    /// directories — `IdentityMigration`'s first step. NOT an uninstall: the
    /// sticky opt-out is untouched, and `ensure` installs the agent under
    /// today's label by the same policy as ever. True when there was one.
    @discardableResult
    public static func retireLegacy(runner: CommandRunner = launchctl) -> Bool {
        let legacy = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(AppIdentity.legacyDaemonLabel).plist")
        let existed = FileManager.default.fileExists(atPath: legacy.path)
        _ = runner(["bootout", "gui/\(getuid())/\(AppIdentity.legacyDaemonLabel)"])
        if existed { try? FileManager.default.removeItem(at: legacy) }
        return existed
    }

    public static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// The binary the installed plist points launchd at, if any.
    public static func installedTarget() -> URL? {
        guard let data = FileManager.default.contents(atPath: plistURL.path) else { return nil }
        return target(inPlist: data)
    }

    /// One line of `launchctl print` state ("running", "not running"), or
    /// nil when the agent isn't loaded at all.
    public static func launchdState(runner: CommandRunner = launchctl) -> String? {
        launchdJob(runner: runner)?.state
    }

    /// The loaded job as launchd prints it. Nil when the agent isn't loaded.
    public struct LoadedJob: Equatable, Sendable {
        /// Its state line ("running", "not running").
        public let state: String
        /// The pid it runs now; nil while nothing runs.
        public let pid: Int32?
        /// The program launchd LOADED — which can differ from the plist on
        /// disk when a reload failed after the file was written.
        public let program: String?
        /// "interactive", "background", … — launchd's own word for the
        /// ProcessType it applied (`spawn type = interactive (4)`).
        public let spawnType: String?
    }

    public static func launchdJob(runner: CommandRunner = launchctl) -> LoadedJob? {
        let result = runner(["print", "gui/\(getuid())/\(label)"])
        guard result.status == 0 else { return nil }
        return parseJob(result.output)
    }

    /// `launchctl print`'s format is "NOT API" (its man page): every field is
    /// optional here, and a field that can't be read is unknown — which
    /// every rule below treats as "no reason to act".
    static func parseJob(_ output: String) -> LoadedJob {
        func value(_ key: String) -> String? {
            output.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("\(key) = ") }
                .map { String($0.dropFirst(key.count + 3)) }
        }
        return LoadedJob(
            state: value("state") ?? "loaded",
            pid: value("pid").flatMap { Int32($0) },
            program: value("program"),
            spawnType: value("spawn type").flatMap { $0.split(separator: " ").first.map(String.init) })
    }

    /// Whether the job launchd loaded is what the plist on disk describes:
    /// its program, and the ProcessType this build installs. Unknown
    /// fields count as matching.
    static func loadedMatches(_ job: LoadedJob, target: URL) -> Bool {
        let program = job.program.map {
            URL(fileURLWithPath: $0).standardizedFileURL == target.standardizedFileURL
        } ?? true
        let spawn = job.spawnType.map { $0 == processType.lowercased() } ?? true
        return program && spawn
    }

    // MARK: - Ensure (the auto-install entry point)

    public enum EnsureOutcome: Equatable, Sendable, CustomStringConvertible {
        /// The sticky opt-out is set — auto-install must do nothing.
        case disabled
        /// No usaged binary could be located to point launchd at.
        case binaryNotFound
        /// Fresh registration (or repair/repoint) written and bootstrapped.
        case installed(String)
        /// Plist was fine but the agent wasn't loaded — bootstrapped it.
        case started
        /// A live daemon runs an older build than its plist's binary (a
        /// rebuild, or an older version) — restarted it into that binary.
        case upgraded
        /// A self-heal found a live host holding the engine: nothing a heal
        /// may touch (2026-11-21 — a busy host is not a broken one).
        case hostAlive
        /// Installed, loaded, current: nothing to do.
        case healthy
        case failed(String)

        public var description: String {
            switch self {
            case .disabled: "auto-install disabled (daemonAutoInstall=false)"
            case .binaryNotFound: "no usaged binary found — is AgentUsage.app installed?"
            case .installed(let path): "installed → \(path)"
            case .started: "started (was installed but not loaded)"
            case .upgraded: "restarted into the current build"
            case .hostAlive: "a live host holds the engine — left alone"
            case .healthy: "already installed and running"
            case .failed(let reason): "failed: \(reason)"
            }
        }
    }

    /// What ensure must do, decided from observations — pure, so the
    /// convergence table is testable without launchd.
    public enum EnsureAction: Equatable, Sendable {
        case none(EnsureOutcome)
        case install
        case bootstrap
        case kickstart
    }

    /// Who is asking `ensure` to converge, which decides what it may do
    /// (2026-11-21).
    public enum EnsureIntent: Sendable, Equatable {
        /// The bundle's own launch, or the Settings toggle: the person
        /// started THIS copy, so it claims the agent — installs, repoints to
        /// itself (issue #9's expectation for `mise run app` from another
        /// checkout), upgrades the plist, restarts a stale daemon.
        case claim
        /// A face that found no engine publishing (`usaged ensure`, which the
        /// TUI runs): it may bring a dead agent back, but never acts while a
        /// live host holds the lease — a busy host is not a broken one — and
        /// repoints only a plist whose target is MISSING. An existing target
        /// is the person's choice; a Spotlight hit is not (2026-10-04, the
        /// TUI repointed the agent at a stale worktree's bundle).
        case heal
    }

    /// The convergence rules, in order:
    /// 1. the opt-out wins;
    /// 2. a heal leaves a live lease holder alone;
    /// 3. a missing plist, or one whose target is missing, is installed;
    /// 4. a plist aimed elsewhere is repointed by a claim — a heal adopts
    ///    the existing target instead;
    /// 5. the plist's OWNER (its target is the caller's binary) rewrites a
    ///    plist whose content isn't what this build installs, or reloads one
    ///    launchd loaded differently (a reload that failed after the file was
    ///    written) — and only the owner, so two builds can never flip-flop a
    ///    daemon between shapes;
    /// 6. an unloaded agent is bootstrapped;
    /// 7. a daemon whose build (`DaemonMarker`, from the process launchd runs
    ///    NOW) differs from its target's file is kicked into it — or, from a
    ///    daemon too old to say, one publishing an older version than ours;
    /// 8. otherwise healthy.
    public static func ensureAction(
        allowed: Bool,
        resolvedBinary: URL?,
        installedTarget: URL?,
        targetExists: Bool,
        loaded: Bool,
        publishedHost: String?,
        publishedVersion: String?,
        currentVersion: String,
        intent: EnsureIntent = .claim,
        leaseHeld: Bool = false,
        plistCurrent: Bool = true,
        launchdPID: Int32? = nil,
        marker: DaemonMarker? = nil,
        targetBuild: String? = nil,
        loadedMatchesPlist: Bool = true,
        loadedRunsTarget: Bool = true
    ) -> EnsureAction {
        guard allowed else { return .none(.disabled) }
        if intent == .heal, leaseHeld { return .none(.hostAlive) }
        guard let resolvedBinary else { return .none(.binaryNotFound) }
        guard let installedTarget, targetExists else { return .install }
        let owned = installedTarget.standardizedFileURL == resolvedBinary.standardizedFileURL
        if !owned, intent == .claim { return .install }
        if owned, !plistCurrent || (loaded && !loadedMatchesPlist) { return .install }
        guard loaded else { return .bootstrap }
        // A kickstart re-runs the program launchd LOADED; if that isn't the
        // plist's target, kicking it can never converge.
        guard loadedRunsTarget else { return .none(.healthy) }
        if let marker {
            // Only the process launchd runs now speaks for the agent: a
            // daemon just kicked and still starved hasn't rewritten its
            // marker yet, and kicking it again would never end.
            guard let launchdPID, marker.pid == launchdPID,
                  let running = marker.build, let onDisk = targetBuild
            else { return .none(.healthy) }
            return running == onDisk ? .none(.healthy) : .kickstart
        }
        if owned, publishedHost == "daemon", let publishedVersion,
           publishedVersion != currentVersion {
            return .kickstart
        }
        return .none(.healthy)
    }

    /// Converge toward "installed, loaded, current" — unless the user's
    /// sticky opt-out says otherwise. `binary` is the caller's own usaged
    /// when it knows it (the app's bundle, usaged itself); nil falls back
    /// to a LaunchServices search.
    @discardableResult
    public static func ensure(
        binary: URL?,
        defaults: UserDefaults,
        intent: EnsureIntent,
        bundleID: String = AppIdentity.bundleID,
        runner: CommandRunner = launchctl
    ) -> EnsureOutcome {
        let resolved = binary ?? embeddedBinary()
        let target = installedTarget()
        let targetExists = target.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let published = publishedIdentity(bundleID: bundleID)
        let job = launchdJob(runner: runner)
        var loadedMatchesPlist = true
        var loadedRunsTarget = true
        if let job, let target {
            loadedMatchesPlist = loadedMatches(job, target: target)
            loadedRunsTarget = job.program.map {
                URL(fileURLWithPath: $0).standardizedFileURL == target.standardizedFileURL
            } ?? true
        }
        let action = ensureAction(
            allowed: autoInstallAllowed(defaults: defaults),
            resolvedBinary: resolved,
            installedTarget: target,
            targetExists: targetExists,
            loaded: job != nil,
            publishedHost: published?.host,
            publishedVersion: published?.version,
            currentVersion: AppIdentity.version,
            intent: intent,
            leaseHeld: EngineLease.isHeld(at: EngineHostBroker.lockURL(bundleID: bundleID)),
            plistCurrent: target.map { plistIsCurrent(installed: installedPlist(), target: $0) } ?? true,
            launchdPID: job?.pid,
            marker: DaemonMarker.read(at: EngineHostBroker.daemonMarkerURL(bundleID: bundleID)),
            targetBuild: targetExists ? target.flatMap(BuildIdentity.of(binary:)) : nil,
            loadedMatchesPlist: loadedMatchesPlist,
            loadedRunsTarget: loadedRunsTarget)
        switch action {
        case .none(let outcome):
            return outcome
        case .install:
            // A missing target is repointed at the caller's binary; an
            // existing one the caller owns is rewritten in place.
            let destination = (targetExists && intent == .heal) ? target! : resolved!
            do {
                try install(binary: destination, runner: runner)
                return .installed(destination.path)
            } catch {
                return .failed("\(error)")
            }
        case .bootstrap:
            let result = runner(["bootstrap", "gui/\(getuid())", plistURL.path])
            return result.status == 0 ? .started : .failed("bootstrap: \(result.output)")
        case .kickstart:
            _ = runner(["kickstart", "-k", "gui/\(getuid())/\(label)"])
            return .upgraded
        }
    }

    // MARK: - Locating the binary

    /// The embedded engine binary inside the installed app. LaunchServices
    /// knows where the app lives; `appOverride` serves unregistered copies.
    public static func embeddedBinary(appOverride: String? = nil) -> URL? {
        if let appOverride {
            let url = URL(fileURLWithPath: appOverride)
                .appending(path: "Contents/MacOS/usaged")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard let apps = LSCopyApplicationURLsForBundleIdentifier(
            AppIdentity.bundleID as CFString, nil)?.takeRetainedValue() as? [URL]
        else { return nil }
        for app in apps {
            let url = app.appending(path: "Contents/MacOS/usaged")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: - Plist shape

    /// What launchd is told to run, and how. `ProcessType` is the priority
    /// class (launchd.plist(5)); see `processType`.
    public static func plistDictionary(binary: URL) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [binary.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "ProcessType": processType,
        ]
    }

    /// Interactive, since 2026-11-21 (measured; docs/DAEMON.md "Priority").
    /// Background (through 0.10x) clamps EVERY thread to priority 4: on a
    /// Mac running ~20 agents (load 200–380 on 10 cores) the heartbeat, the
    /// publisher and the socket got no CPU for minutes while the process
    /// held the lease, and every face called a live engine offline. Standard
    /// (= unset) still runs the job at 20, beneath the agents' 31; Adaptive
    /// follows XPC transactions, which usaged has none of, so it behaves as
    /// Background. Interactive runs it like an app — and the heavy work
    /// inside stays at utility QoS (`EngineWork`), so the engine answers at
    /// once without competing with the person's agents for the cores.
    public static let processType = "Interactive"

    public static func plistData(binary: URL) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: plistDictionary(binary: binary), format: .xml, options: 0)
    }

    /// The installed plist, parsed. Nil when absent or unreadable.
    public static func installedPlist() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: plistURL.path) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// True when the installed plist says exactly what this build would
    /// install for that same target. Compared as dictionaries, never as
    /// bytes: key order, whitespace or a binary encoding must not restart a
    /// daemon on every launch.
    public static func plistIsCurrent(installed: [String: Any]?, target: URL) -> Bool {
        guard let installed else { return false }
        return NSDictionary(dictionary: installed).isEqual(to: plistDictionary(binary: target))
    }

    public static func target(inPlist data: Data) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String],
              let path = arguments.first
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Digest peek (for the upgrade check)

    /// Who published the digest last, per itself. Only a daemon-published
    /// version can justify a kickstart: while the app hosts, a loaded
    /// daemon is idle-waiting on the lease and its version is unknowable.
    private static func publishedIdentity(bundleID: String) -> (host: String, version: String)? {
        guard let data = FileManager.default.contents(
                atPath: LiveState.fileURL(bundleID: bundleID).path),
              let state = try? LiveState.decoder().decode(LiveState.self, from: data)
        else { return nil }
        return (state.engine.host, state.engine.appVersion)
    }

    // MARK: - launchctl

    public static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (-1, "\(error)")
        }
    }
}
