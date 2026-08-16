import CoreServices
import Foundation

/// The one sanctioned launch-agent registration (spec §10): writes and
/// bootstraps `com.avihu.usaged`, pointing launchd at the usaged binary
/// embedded in ClaudeUsage.app.
///
/// Since the 2026-08-16 re-amendment, installation is automatic for
/// convenience: the app converges the agent at launch and the TUI asks
/// `usaged ensure` when it finds no engine. The user's control is the
/// sticky opt-out — `daemonAutoInstall` — which uninstall paths set to
/// false and every auto-install path honors. Mechanism lives here;
/// policy is only ever flipped by an explicit user action (the CLI verbs,
/// the Settings toggle).
public enum LaunchAgentInstaller {
    public static let label = "com.avihu.usaged"
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

    /// Writes the plist and (re)bootstraps the agent. Idempotent: an
    /// existing registration is booted out first, so this is also the
    /// repair and repoint path.
    public static func install(binary: URL, runner: CommandRunner = launchctl) throws {
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
        let uid = getuid()
        _ = runner(["bootout", "gui/\(uid)/\(label)"])
        let result = runner(["bootstrap", "gui/\(uid)", plistURL.path])
        guard result.status == 0 else {
            throw InstallError.bootstrap(result.output)
        }
    }

    /// Boots the agent out and removes the plist. Flag handling is the
    /// caller's: user-initiated paths also set the sticky opt-out.
    public static func uninstall(runner: CommandRunner = launchctl) {
        _ = runner(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
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
        let result = runner(["print", "gui/\(getuid())/\(label)"])
        guard result.status == 0 else { return nil }
        return result.output
            .split(separator: "\n")
            .first { $0.contains("state =") }
            .map {
                $0.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "state = ", with: "")
            } ?? "loaded"
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
        /// A live daemon publishes an older version — restarted it into
        /// the current binary.
        case upgraded
        /// Installed, loaded, current: nothing to do.
        case healthy
        case failed(String)

        public var description: String {
            switch self {
            case .disabled: "auto-install disabled (daemonAutoInstall=false)"
            case .binaryNotFound: "no usaged binary found — is ClaudeUsage.app installed?"
            case .installed(let path): "installed → \(path)"
            case .started: "started (was installed but not loaded)"
            case .upgraded: "restarted into the current version"
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

    /// The convergence rules: opt-out wins; a missing/misaimed plist is
    /// (re)installed; an unloaded agent is bootstrapped; a live daemon on
    /// an older version is kicked into the new binary; otherwise healthy.
    public static func ensureAction(
        allowed: Bool,
        resolvedBinary: URL?,
        installedTarget: URL?,
        targetExists: Bool,
        loaded: Bool,
        publishedHost: String?,
        publishedVersion: String?,
        currentVersion: String
    ) -> EnsureAction {
        guard allowed else { return .none(.disabled) }
        guard let resolvedBinary else { return .none(.binaryNotFound) }
        guard let installedTarget, targetExists,
              installedTarget.standardizedFileURL == resolvedBinary.standardizedFileURL
        else { return .install }
        guard loaded else { return .bootstrap }
        if publishedHost == "daemon", let publishedVersion,
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
        bundleID: String = "com.avihu.ClaudeUsage",
        runner: CommandRunner = launchctl
    ) -> EnsureOutcome {
        let resolved = binary ?? embeddedBinary()
        let target = installedTarget()
        let published = publishedIdentity(bundleID: bundleID)
        let action = ensureAction(
            allowed: autoInstallAllowed(defaults: defaults),
            resolvedBinary: resolved,
            installedTarget: target,
            targetExists: target.map { FileManager.default.fileExists(atPath: $0.path) }
                ?? false,
            loaded: launchdState(runner: runner) != nil,
            publishedHost: published?.host,
            publishedVersion: published?.version,
            currentVersion: AppIdentity.version)
        switch action {
        case .none(let outcome):
            return outcome
        case .install:
            do {
                try install(binary: resolved!, runner: runner)
                return .installed(resolved!.path)
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
            "com.avihu.ClaudeUsage" as CFString, nil)?.takeRetainedValue() as? [URL]
        else { return nil }
        for app in apps {
            let url = app.appending(path: "Contents/MacOS/usaged")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: - Plist shape

    public static func plistData(binary: URL) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "ProcessType": "Background",
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
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
