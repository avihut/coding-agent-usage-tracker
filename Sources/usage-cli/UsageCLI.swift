import Foundation
import UsageCore

/// Milestone-1 debug tool: reads the token through the credential chain, hits
/// the usage endpoint once, prints the raw JSON body to stdout. Diagnostics go
/// to stderr and never contain the token.
///
/// `usage-cli sync-digest [--provider <id>]` prints the CloudKit sync digest
/// this machine would publish (docs/SYNC.md) — same read-only cache rules,
/// zero network.
///
/// `usage-cli state` prints the engine's published live-state digest
/// (docs/DAEMON.md) exactly as it sits on disk — the file every consumer
/// interface renders from.
///
/// `usage-cli <noun> …` for any noun in `DigestQuery.nouns` (status, limits,
/// limit, budget, spend, activity, cost, models, model, sessions, session,
/// prompt, get) is the v0.81.0 query surface — the WHOLE grammar lives in
/// core `DigestQuery`, this target only does file IO + process exit.
/// M2 adds a SECOND noun vocabulary, `DeepQuery.nouns` (windows, history,
/// prices, price) — same grammar, but `DeepQuery.run` takes an OPTIONAL
/// digest (`prices` answers with no digest and no daemon running at all,
/// from the bundled pricing floor), so `runQuery` below checks noun
/// membership BEFORE deciding whether a missing digest file is fatal.
/// `sessions`/`session` stay `DigestQuery` nouns, but (v0.83.0) they too can
/// answer without a digest: `sessions --all` and a `session <id-prefix>`
/// shortlist-miss both fall through to a bare `TranscriptScanner` pass
/// (`DeepQuerySessionsCLI`, core `Digests/DeepQuerySessions.swift`) — the
/// noun grammar's own replacement for the old ad hoc `runSessions` dump this
/// file used to carry. Routing below is by ARGUMENT COUNT, not noun
/// recognition: anything past argv[0] is the grammar's noun position, typo
/// or not, so `runQuery` itself returns the bad-query exit for an
/// unrecognized one — a typo must never fall through to the credentialed
/// fetch beneath it.
@main
struct UsageCLI {
    static func main() async {
        let arguments = CommandLine.arguments
        // Modes are chosen by argv[1] ONLY — a mode name appearing later
        // is somebody's flag VALUE (`sessions --branch state` must run the
        // sessions query, not dump the digest), never a mode switch.
        let mode = arguments.count > 1 ? arguments[1] : ""
        if mode == "sync-digest" {
            runSyncDigest(providerID: value(after: "--provider", in: arguments))
            return
        }
        if mode == "state" {
            runState()
            return
        }
        if mode == "daemon" {
            guard arguments.indices.contains(2) else {
                die("daemon needs a verb — install|uninstall|start|stop|status", code: 18)
            }
            runDaemon(
                verb: arguments[2],
                appOverride: value(after: "--app", in: arguments))
            return
        }
        // Milestone-1's bare fetch is a single-argument debug invocation
        // ONLY (`usage-cli`, nothing else) — any other argv[1] is the
        // grammar's noun position, recognized or not, so a typo reaches
        // `runQuery`'s own bad-query exit (checked against BOTH noun
        // vocabularies below) instead of silently falling through to a
        // live credentialed fetch.
        if arguments.count > 1 {
            runQuery(
                arguments: Array(arguments.dropFirst()),
                digestPath: value(after: "--digest", in: arguments))
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
            die("keychain read refused (security exited \(status)) — unlock the login Keychain and retry", code: 3)
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

    // MARK: - sync-digest mode

    /// Prints the sync digest (docs/SYNC.md) this machine WOULD publish, as
    /// pretty JSON — the inspection hatch for a schema that must be right
    /// before it ever deploys. Local-only by design: warm scan cache (never
    /// written), history.jsonl, and the app's cached usage snapshot replayed
    /// through the provider. No network, no credentials, no Keychain prompt —
    /// so `planLabel` (credential metadata) prints null here even though the
    /// app will publish it.
    private static func runSyncDigest(providerID: String?) {
        let chosen = DeepQuery.resolveProviderID(flag: providerID)
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

    /// `usage-cli daemon install|uninstall|start|stop|status [--app <path>]`,
    /// a thin face over core `LaunchAgentInstaller` (the same mechanism the
    /// app and `usaged ensure` auto-install through — spec §10
    /// re-amendment). Explicit verbs also flip the sticky opt-out:
    /// `install` re-arms auto-install, `uninstall` disarms it so no entry
    /// point quietly brings the agent back.
    private static func runDaemon(verb: String, appOverride: String?) {
        let uid = getuid()
        let label = LaunchAgentInstaller.label
        switch verb {
        case "install":
            guard let binary = LaunchAgentInstaller.embeddedBinary(appOverride: appOverride)
            else {
                die(
                    "cannot find ClaudeUsage.app (searched LaunchServices) — pass --app <path-to-ClaudeUsage.app>",
                    code: 14)
            }
            LaunchAgentInstaller.setAutoInstall(true, defaults: .standard)
            do {
                try LaunchAgentInstaller.install(binary: binary)
            } catch {
                die("\(error)", code: 16)
            }
            note("installed \(label) → \(binary.path)")
        case "uninstall":
            LaunchAgentInstaller.setAutoInstall(false, defaults: .standard)
            LaunchAgentInstaller.uninstall()
            note("uninstalled \(label) (agent booted out, plist removed, auto-install off)")
        case "start":
            guard LaunchAgentInstaller.isInstalled() else {
                die("not installed — run `usage-cli daemon install` first", code: 17)
            }
            let result = LaunchAgentInstaller.launchctl(
                ["bootstrap", "gui/\(uid)", LaunchAgentInstaller.plistURL.path])
            if result.status != 0 {
                // Already loaded: kick it instead.
                _ = LaunchAgentInstaller.launchctl(["kickstart", "gui/\(uid)/\(label)"])
            }
            note("started")
        case "stop":
            let result = LaunchAgentInstaller.launchctl(["bootout", "gui/\(uid)/\(label)"])
            note(result.status == 0 ? "stopped" : "was not running")
        case "status":
            if let state = LaunchAgentInstaller.launchdState() {
                note("launchd: state = \(state)")
            } else {
                note("launchd: not loaded")
            }
            if !LaunchAgentInstaller.autoInstallAllowed(defaults: .standard) {
                note("auto-install: off (sticky — `daemon install` re-arms it)")
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

    // MARK: - query mode (v0.81.0)

    /// `arguments` starts with the noun (the program path already dropped by
    /// the caller) — the exact shape `DigestQuery.run` expects, and
    /// `DeepQuery.run` takes the noun separately with the same remainder.
    /// `--digest` is resolved here (file IO is this target's job) but ALSO
    /// left in `arguments` for the query layer to parse — it recognizes the
    /// flag as inert, one parser for the whole grammar rather than two.
    ///
    /// Noun recognition happens BEFORE the digest file is touched: an
    /// unrecognized noun exits 19 regardless of whether a digest exists
    /// (`DigestQuery.nouns` alone can't answer that — a digest-less machine
    /// used to report exit 13 for a plain typo, which the M2 doc rule
    /// ("an unknown noun exits 19") tightens here), and a `DeepQuery` noun
    /// is dispatched with the digest OPTIONAL (`prices` answers with no
    /// digest and no daemon at all) — only `DigestQuery`'s own nouns require
    /// one to exist first.
    private static func runQuery(arguments: [String], digestPath: String?) {
        let noun = arguments.first ?? ""
        guard DigestQuery.nouns.contains(noun) || DeepQuery.nouns.contains(noun) else {
            die(
                "unknown noun '\(noun)' — usage-cli <noun> [selector] [field] [flags]; "
                    + "nouns: \((DigestQuery.nouns.union(DeepQuery.nouns)).sorted().joined(separator: " "))",
                code: 19)
        }

        // `notices dismiss <id>` / `notices dismiss --all` is the one query
        // verb that WRITES — through the engine's socket, like the panel's ×
        // and the TUI's `x`, never by touching the ledger file. It needs no
        // digest: the engine answers for itself.
        if noun == "notices", arguments.dropFirst().first == "dismiss" {
            dismissNotices(Array(arguments.dropFirst(2)))
        }

        let fileURL = digestPath.map { URL(fileURLWithPath: $0) }
            ?? LiveState.fileURL(bundleID: "com.avihu.ClaudeUsage")
        let digestData = FileManager.default.contents(atPath: fileURL.path)

        if DeepQuery.nouns.contains(noun) {
            let digest = digestData.flatMap { try? LiveState.decoder().decode(LiveState.self, from: $0) }
            let output = DeepQuery.run(
                noun: noun, arguments: Array(arguments.dropFirst()), digest: digest,
                environment: ProcessInfo.processInfo.environment, now: Date())
            emit(output)
            return
        }

        // `sessions`/`session` route through `DeepQuerySessionsCLI`, not
        // `DigestQuery.run` — only there can a shortlist miss / `--all` fall
        // through to a real transcript scan (`DigestQuery.run` itself stays
        // pure, per its own doc contract). A digest that exists but fails to
        // decode degrades the same way as one that's simply absent: corrupt
        // state is no more answerable than no state.
        if noun == "sessions" || noun == "session" {
            let digest = digestData.flatMap { try? LiveState.decoder().decode(LiveState.self, from: $0) }
            let output = DeepQuerySessionsCLI.run(
                noun: noun, arguments: Array(arguments.dropFirst()), digest: digest, now: Date())
            emit(output)
            return
        }

        guard let data = digestData else {
            die(
                "no live-state digest at \(fileURL.path) — launch the app (or usaged) so the engine publishes one",
                code: 13)
        }
        let digest: LiveState
        do {
            digest = try LiveState.decoder().decode(LiveState.self, from: data)
        } catch {
            die(
                "live-state digest at \(fileURL.path) does not decode (\(type(of: error))) — regenerate it",
                code: 13)
        }
        let output = DigestQuery.run(
            arguments: arguments, digest: digest, rawDigest: data,
            environment: ProcessInfo.processInfo.environment, now: Date())
        emit(output)
    }

    /// Sends the dismissal and reports the engine's word. Exit 20 when the
    /// engine refuses (an ongoing notice, or an id it doesn't hold), 13 when
    /// no engine is listening — the same "no engine" code a missing digest
    /// gets, because that is what it means.
    private static func dismissNotices(_ rest: [String]) -> Never {
        let command: ControlCommand
        switch rest {
        case ["--all"]:
            command = .dismissAllNotices
        case let words where words.count == 1 && !words[0].hasPrefix("-"):
            command = .dismissNotice(id: words[0])
        default:
            die("usage: usage-cli notices dismiss <id> | --all", code: 19)
        }
        let socket = EngineHostBroker.socketURL(bundleID: "com.avihu.ClaudeUsage")
        guard let reply = ControlSocket.send(command, to: socket) else {
            die("no engine listening on \(socket.path) — launch the app (or usaged)", code: 13)
        }
        guard reply.ok else { die(reply.message ?? "refused", code: 20) }
        exit(0)
    }

    /// Shared by both query layers: several exits are pinned to EMPTY
    /// stdout (`--check`, a `--max-age` miss) — the line terminator rides
    /// ALONG with real content instead of unconditionally, so those stay
    /// genuinely silent rather than silent-plus-one-newline-byte.
    private static func emit(_ output: QueryOutput) {
        if !output.stdout.isEmpty {
            FileHandle.standardOutput.write(Data(output.stdout.utf8))
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        if let message = output.note { note(message) }
        exit(output.exitCode)
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
