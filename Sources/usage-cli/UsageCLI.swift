import Foundation
import UsageCore

/// Milestone-1 debug tool: reads the token through the credential chain, hits
/// the usage endpoint once, prints the raw JSON body to stdout. Diagnostics go
/// to stderr and never contain the token.
///
/// `usage-cli sessions [--provider <id>]` instead prints the session index —
/// the sessions browser's data layer, verifiable headless. It READS the app's
/// warm scan cache but never writes it (`persistCache: false`): the app stays
/// the sole cache writer, so a CLI run can't race or clobber a live scan.
///
/// `usage-cli sync-digest [--provider <id>]` prints the CloudKit sync digest
/// this machine would publish (docs/SYNC.md) — same read-only cache rules,
/// zero network.
///
/// `usage-cli state` prints the engine's published live-state digest
/// (docs/DAEMON.md) exactly as it sits on disk — the file every consumer
/// interface renders from.
@main
struct UsageCLI {
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.contains("sessions") {
            runSessions(providerID: value(after: "--provider", in: arguments))
            return
        }
        if arguments.contains("sync-digest") {
            runSyncDigest(providerID: value(after: "--provider", in: arguments))
            return
        }
        if arguments.contains("state") {
            runState()
            return
        }
        if let index = arguments.firstIndex(of: "daemon"),
           arguments.indices.contains(index + 1) {
            runDaemon(
                verb: arguments[index + 1],
                appOverride: value(after: "--app", in: arguments))
            return
        }

        let credential: Credential
        do {
            credential = try CredentialChain.standard.readCredential()
        } catch let error as CredentialError {
            fail(credentialError: error)
        } catch {
            die("unexpected credential error: \(type(of: error))", code: 1)
        }

        note("credentials: \(credential.sourceName)")

        do {
            let body = try await UsageClient().fetchRawUsage(accessToken: credential.accessToken)
            note("HTTP 200, \(body.count) bytes")
            FileHandle.standardOutput.write(body)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch let error as UsageClientError {
            fail(clientError: error)
        } catch {
            die("unexpected client error: \(type(of: error))", code: 1)
        }
    }

    private static func fail(credentialError: CredentialError) -> Never {
        switch credentialError {
        case .notFound:
            die("no Claude Code credentials found (checked ~/.claude/.credentials.json and the login Keychain)", code: 2)
        case .accessDenied(let status):
            die("keychain access denied (OSStatus \(status)) — approve the Keychain prompt, or click \"Always Allow\" to stop future prompts", code: 3)
        case .unreadable(let reason):
            die("credentials unreadable: \(reason)", code: 7)
        }
    }

    private static func fail(clientError: UsageClientError) -> Never {
        switch clientError {
        case .signInExpired:
            die("sign-in expired (401/403) — open Claude Code to refresh the token", code: 4)
        case .rateLimited(let retryAfter):
            let wait = retryAfter.map { " (Retry-After \(Int($0))s)" } ?? ""
            die("rate limited (429)\(wait) — try again later", code: 9)
        case .http(let code):
            die("unexpected HTTP \(code) from usage endpoint", code: 5)
        case .network(let urlError):
            die("network failure: \(urlError.code)", code: 6)
        case .schema:
            die("unexpected API response — the undocumented schema may have changed", code: 8)
        case .noLocalData:
            die("no local session files found for this provider", code: 10)
        }
    }

    // MARK: - sessions mode

    private static func runSessions(providerID: String?) {
        // The registry's persisted pick; "auto" means no explicit choice.
        let stored = UserDefaults.standard.string(forKey: "activeProviderID")
        let chosen = providerID ?? (stored == "auto" ? nil : stored) ?? "claude"
        // A bare executable has no bundle identity — same fallback the app
        // uses, so both read the same scoped cache.
        let bundleID = "com.avihu.ClaudeUsage"
        let support = StorageScope.supportDirectory(bundleID: bundleID, providerID: chosen)

        guard chosen == "claude" else {
            die("sessions are not wired for '\(chosen)' in the CLI yet", code: 11)
        }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects")
        let scanner = TranscriptScanner(root: root, cacheDirectory: support)
        let scan = scanner.scan(persistCache: false)
        guard !scan.sessions.isEmpty else {
            note("no sessions found under ~/.claude/projects")
            return
        }

        let provider = ClaudeProvider()
        let pricing = PricingService(
            cacheDirectory: support, fallback: provider.bundledRates,
            selector: provider.pricingSelector
        ).current()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        note("\(scan.sessions.count) sessions (\(provider.agentName))")
        for session in scan.sessions {
            var dollars = 0.0
            var unpriced = 0
            for (model, tally) in session.models {
                if let rates = pricing.rates(for: model) {
                    dollars += rates.dollars(for: tally)
                } else {
                    unpriced += 1
                }
            }
            let cost = unpriced > 0 && dollars == 0
                ? "      —" : String(format: "%8.2f", dollars)
            let badge = session.kind == .background ? " [bg]" : "     "
            let line = "\(formatter.string(from: session.end))  $\(cost)  "
                + "\(String(format: "%5d", session.apiCalls)) calls  "
                + "\(TokenFormat.compact(session.totalTokens).padding(toLength: 7, withPad: " ", startingAt: 0))"
                + "\(badge)  \(session.title)\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }

    // MARK: - sync-digest mode

    /// Prints the sync digest (docs/SYNC.md) this machine WOULD publish, as
    /// pretty JSON — the inspection hatch for a schema that must be right
    /// before it ever deploys. Local-only by design: warm scan cache (never
    /// written), history.jsonl, and the app's cached usage snapshot replayed
    /// through the provider. No network, no credentials, no Keychain prompt —
    /// so `planLabel` (credential metadata) prints null here even though the
    /// app will publish it.
    private static func runSyncDigest(providerID: String?) {
        let stored = UserDefaults.standard.string(forKey: "activeProviderID")
        let chosen = providerID ?? (stored == "auto" ? nil : stored) ?? "claude"
        let bundleID = "com.avihu.ClaudeUsage"
        guard chosen == "claude" else {
            die("sync-digest is not wired for '\(chosen)' in the CLI yet", code: 11)
        }
        let support = StorageScope.supportDirectory(bundleID: bundleID, providerID: chosen)
        let caches = StorageScope.cachesDirectory(bundleID: bundleID, providerID: chosen)

        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects")
        let scan = TranscriptScanner(root: root, cacheDirectory: support)
            .scan(persistCache: false)
        let daily = ActivityMerge.merge(
            transcripts: scan.daily, prompts: PromptHistoryScanner.standard().scan())

        var meterSnapshot: MeterSnapshotDigest?
        if let cached = UsageCache(directory: caches).load(),
           let snapshot = try? ClaudeProvider().snapshot(
               fromRawUsage: cached.body, fetchedAt: cached.fetchedAt,
               plan: nil, thresholds: .standard) {
            meterSnapshot = MeterSnapshotDigest(
                capturedAt: cached.fetchedAt, planLabel: nil, meters: snapshot.meters)
        }

        // "preview": the real per-install device id is minted by the app when
        // transport ships; this digest is for reading, not publishing.
        let digest = SyncDigestBuilder.build(
            device: DeviceDigest(
                deviceID: "preview",
                name: Host.current().localizedName ?? "This Mac",
                providerID: chosen,
                accountLabel: nil,
                appVersion: AppIdentity.version,
                timeZone: TimeZone.current.identifier,
                capturedAt: Date()),
            daily: daily,
            sessions: scan.sessions,
            meters: meterSnapshot,
            calendar: .current)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(digest)
            note("digest: \(digest.days.count) days, \(digest.sessions.count) sessions, "
                + "meters \(meterSnapshot == nil ? "absent" : "present"), \(data.count) bytes")
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            die("digest failed to encode: \(type(of: error))", code: 12)
        }
    }

    // MARK: - daemon mode

    private static let launchAgentLabel = "com.avihu.usaged"
    private static var launchAgentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    /// `usage-cli daemon install|uninstall|start|stop|status [--app <path>]`.
    /// Install is the ONE sanctioned launch-agent registration (spec §10
    /// amendment) and only ever runs because the user typed it. The plist
    /// points at the usaged binary embedded in ClaudeUsage.app.
    private static func runDaemon(verb: String, appOverride: String?) {
        let uid = getuid()
        switch verb {
        case "install":
            guard let binary = usagedBinary(appOverride: appOverride) else {
                die(
                    "cannot find ClaudeUsage.app (searched LaunchServices) — pass --app <path-to-ClaudeUsage.app>",
                    code: 14)
            }
            let plist: [String: Any] = [
                "Label": launchAgentLabel,
                "ProgramArguments": [binary.path],
                "RunAtLoad": true,
                "KeepAlive": true,
                "ThrottleInterval": 10,
                "ProcessType": "Background",
            ]
            do {
                let data = try PropertyListSerialization.data(
                    fromPropertyList: plist, format: .xml, options: 0)
                try FileManager.default.createDirectory(
                    at: launchAgentPlist.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try data.write(to: launchAgentPlist)
            } catch {
                die("cannot write \(launchAgentPlist.path): \(error)", code: 15)
            }
            // A previous registration would make bootstrap a no-op error.
            _ = launchctl(["bootout", "gui/\(uid)/\(launchAgentLabel)"])
            let result = launchctl(["bootstrap", "gui/\(uid)", launchAgentPlist.path])
            guard result.status == 0 else {
                die("launchctl bootstrap failed: \(result.output)", code: 16)
            }
            note("installed \(launchAgentLabel) → \(binary.path)")
        case "uninstall":
            _ = launchctl(["bootout", "gui/\(uid)/\(launchAgentLabel)"])
            try? FileManager.default.removeItem(at: launchAgentPlist)
            note("uninstalled \(launchAgentLabel) (agent booted out, plist removed)")
        case "start":
            guard FileManager.default.fileExists(atPath: launchAgentPlist.path) else {
                die("not installed — run `usage-cli daemon install` first", code: 17)
            }
            let result = launchctl(["bootstrap", "gui/\(uid)", launchAgentPlist.path])
            if result.status != 0 {
                // Already loaded: kick it instead.
                _ = launchctl(["kickstart", "gui/\(uid)/\(launchAgentLabel)"])
            }
            note("started")
        case "stop":
            let result = launchctl(["bootout", "gui/\(uid)/\(launchAgentLabel)"])
            note(result.status == 0 ? "stopped" : "was not running")
        case "status":
            let print = launchctl(["print", "gui/\(uid)/\(launchAgentLabel)"])
            if print.status == 0 {
                let state = print.output
                    .split(separator: "\n")
                    .first { $0.contains("state =") }
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? "state unknown"
                note("launchd: \(state)")
            } else {
                note("launchd: not loaded")
            }
            let digest = LiveState.fileURL(bundleID: "com.avihu.ClaudeUsage")
            if let attributes = try? FileManager.default.attributesOfItem(atPath: digest.path),
               let modified = attributes[.modificationDate] as? Date {
                let age = Int(Date().timeIntervalSince(modified))
                note("digest: written \(age)s ago")
            } else {
                note("digest: absent")
            }
            let socket = EngineHostBroker.socketURL(bundleID: "com.avihu.ClaudeUsage")
            if let reply = ControlSocket.send(.status, to: socket) {
                note("socket: \(reply.message ?? "ok")")
            } else {
                note("socket: no listener")
            }
        default:
            die("unknown daemon verb '\(verb)' — install|uninstall|start|stop|status", code: 18)
        }
    }

    /// The embedded engine binary inside the installed app. LaunchServices
    /// knows where the app lives; `--app` overrides for unregistered copies.
    private static func usagedBinary(appOverride: String?) -> URL? {
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

    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
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

    // MARK: - state mode

    /// Prints live-state.json verbatim — no re-encoding, so what you pipe
    /// into jq is byte-for-byte what the engine's publisher wrote.
    private static func runState() {
        let fileURL = LiveState.fileURL(bundleID: "com.avihu.ClaudeUsage")
        guard let data = FileManager.default.contents(atPath: fileURL.path) else {
            die(
                "no live-state digest at \(fileURL.path) — launch the app (or usaged) so the engine publishes one",
                code: 13)
        }
        // A decode pass first: corrupt state should fail loudly here, not
        // in a consumer.
        do {
            let state = try LiveState.decoder().decode(LiveState.self, from: data)
            note("live-state: schema v\(state.schemaVersion), host \(state.engine.host) "
                + "pid \(state.engine.pid), \(state.meters.count) meters, "
                + "\(state.activity.days.count) days, \(data.count) bytes")
        } catch {
            note("WARNING: file does not decode as LiveState (\(type(of: error))) — printing raw bytes anyway")
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("[usage-cli] \(message)\n".utf8))
    }

    private static func die(_ message: String, code: Int32) -> Never {
        note(message)
        exit(code)
    }
}
