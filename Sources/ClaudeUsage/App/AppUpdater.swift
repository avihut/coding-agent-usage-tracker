import AppKit
import Observation
import UsageCore

/// Downloads a published release and swaps this app's bundle for it — the
/// one-click flow behind the footer chip, the ⋯ menu item, and Settings.
///
/// The whole flow is explicitly user-clicked: the engine's `UpdateChecker`
/// only ever reads the release FEED; the asset download, the verify, and
/// the swap all start here and nowhere else (spec §10 amendment
/// 2026-08-23). Every step either completes or rolls back — a failed
/// update must leave the installed app exactly as it was.
@MainActor @Observable
final class AppUpdater {
    static let shared = AppUpdater()

    enum Phase: Equatable {
        case idle
        case downloading
        case installing
        case relaunching
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    var isBusy: Bool {
        switch phase {
        case .downloading, .installing, .relaunching: true
        case .idle, .failed: false
        }
    }

    /// Hosts an asset may legally come from: the release page's own host and
    /// GitHub's asset CDN (the download redirects there). With the debug
    /// feed override active the drill serves from localhost, so the
    /// allowlist widens to that override's host.
    private static func isAllowedHost(_ url: URL) -> Bool {
        guard let host = url.host() else { return false }
        if host == "github.com" || host.hasSuffix(".githubusercontent.com") { return true }
        if let override = UserDefaults.standard.string(
            forKey: UpdateChecker.feedOverrideKey).flatMap(URL.init(string:)),
           host == override.host() {
            return true
        }
        return false
    }

    private init() {
        // Sweep swap leftovers from an earlier update of this install —
        // the aside bundle is only needed until its relaunch succeeds.
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: parent.path) {
            for entry in entries where entry.hasPrefix(".ClaudeUsage-previous-") {
                try? FileManager.default.removeItem(at: parent.appending(path: entry))
            }
        }
    }

    /// The one entry point. Runs the download → verify → swap → relaunch
    /// pipeline; any thrown step lands in `.failed` with the app untouched.
    func install(_ card: AppUpdateCard) {
        guard !isBusy else { return }
        guard let assetURL = card.assetURL.flatMap(URL.init(string:)),
              Self.isAllowedHost(assetURL)
        else {
            // No asset (or one from a host we refuse): the release page is
            // the honest fallback, still one click away.
            if let page = URL(string: card.url) { NSWorkspace.shared.open(page) }
            return
        }
        phase = .downloading
        let bundleURL = Bundle.main.bundleURL
        Task {
            do {
                let staged = try await Self.downloadAndStage(
                    assetURL: assetURL, expectedVersion: card.latestVersion,
                    bundleURL: bundleURL
                ) { @MainActor in self.phase = .installing }
                try Self.swapBundle(with: staged, bundleURL: bundleURL)
                phase = .relaunching
                await Self.kickstartDaemon()
                Self.relaunch(bundleURL: bundleURL)
            } catch let error as UpdateError {
                phase = .failed(error.message)
            } catch {
                phase = .failed("The update failed unexpectedly.")
            }
        }
    }

    /// A failed attempt is retryable — the chip's next click starts over.
    func resetFailure() {
        if case .failed = phase { phase = .idle }
    }

    enum UpdateError: Error {
        case download
        case unpack
        case verification
        case versionMismatch(found: String?)
        case notWritable(String)
        case swap

        var message: String {
            switch self {
            case .download: "The download failed. Check the connection and try again."
            case .unpack: "The downloaded archive could not be unpacked."
            case .verification: "The download failed its signature check and was discarded."
            case .versionMismatch(let found):
                "The archive contains \(found ?? "an unknown version"), not the announced release."
            case .notWritable(let path): "This app's location isn't writable (\(path))."
            case .swap: "Swapping the app bundle failed; the installed version is unchanged."
            }
        }
    }

    // MARK: - Pipeline (nonisolated: everything below is file and process
    // work that must not block the MainActor)

    /// Downloads the asset, unpacks it, verifies signature and version, and
    /// returns a staged bundle SITTING BESIDE the installed one — same
    /// volume, so the final swap is two renames.
    nonisolated private static func downloadAndStage(
        assetURL: URL, expectedVersion: String, bundleURL: URL,
        onInstalling: @escaping @MainActor @Sendable () -> Void
    ) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: assetURL)
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        let downloaded: URL
        do {
            let (file, response) = try await session.download(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else { throw UpdateError.download }
            downloaded = file
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.download
        }
        await onInstalling()

        let work = FileManager.default.temporaryDirectory
            .appending(path: "ClaudeUsage-update-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // ditto, not an unzip library: it round-trips bundle metadata and
        // the signature intact — the same reason dist.sh packs with it.
        guard await run("/usr/bin/ditto", ["-x", "-k", downloaded.path, work.path]) == 0
        else { throw UpdateError.unpack }
        let unpacked = work.appending(path: "ClaudeUsage.app")
        guard FileManager.default.fileExists(atPath: unpacked.path) else {
            throw UpdateError.unpack
        }

        // Integrity, then identity: a bundle that fails codesign is
        // discarded outright, and one carrying a different version than the
        // clicked release never installs.
        guard await run(
            "/usr/bin/codesign", ["--verify", "--deep", "--strict", unpacked.path]) == 0
        else { throw UpdateError.verification }
        let plist = unpacked.appending(path: "Contents/Info.plist")
        let found = (try? PropertyListSerialization.propertyList(
            from: Data(contentsOf: plist), format: nil) as? [String: Any])
            .flatMap { $0["CFBundleShortVersionString"] as? String }
        guard found == expectedVersion else {
            throw UpdateError.versionMismatch(found: found)
        }

        let parent = bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notWritable(parent.path)
        }
        let staging = parent.appending(
            path: ".ClaudeUsage-staged-\(ProcessInfo.processInfo.processIdentifier).app")
        try? FileManager.default.removeItem(at: staging)
        do {
            try FileManager.default.copyItem(at: unpacked, to: staging)
        } catch {
            throw UpdateError.swap
        }
        return staging
    }

    /// Two renames with a rollback: the installed bundle steps aside, the
    /// staged one takes its place, and any failure puts the original back.
    nonisolated private static func swapBundle(with staging: URL, bundleURL: URL) throws {
        let fm = FileManager.default
        let aside = staging.deletingLastPathComponent().appending(
            path: ".ClaudeUsage-previous-\(ProcessInfo.processInfo.processIdentifier).app")
        try? fm.removeItem(at: aside)
        do {
            try fm.moveItem(at: bundleURL, to: aside)
        } catch {
            try? fm.removeItem(at: staging)
            throw UpdateError.swap
        }
        do {
            try fm.moveItem(at: staging, to: bundleURL)
        } catch {
            try? fm.moveItem(at: aside, to: bundleURL)
            try? fm.removeItem(at: staging)
            throw UpdateError.swap
        }
        // The running process keeps its inodes; the aside copy only matters
        // if the relaunch never happens, and init's sweep collects it then.
    }

    /// The daemon execs from inside the bundle just swapped — kick it so the
    /// new binary takes over. Best-effort: no agent, no harm.
    nonisolated private static func kickstartDaemon() async {
        _ = await run(
            "/bin/launchctl",
            ["kickstart", "-k", "gui/\(getuid())/com.avihu.usaged"])
    }

    /// The classic self-relaunch: a detached shell outlives this process,
    /// waits out the termination, and opens the (now new) bundle. The path
    /// travels as an environment value so no quoting can break it.
    nonisolated private static func relaunch(bundleURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$CLAUDE_USAGE_RELAUNCH\""]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["CLAUDE_USAGE_RELAUNCH": bundleURL.path], uniquingKeysWith: { _, new in new })
        try? process.run()
        Task { @MainActor in NSApp.terminate(nil) }
    }

    /// Runs a tool to completion without parking a cooperative thread —
    /// the termination handler resumes the continuation.
    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
    }
}
