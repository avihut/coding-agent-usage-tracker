import Foundation

/// What the local checkout says about itself: the identity line on the
/// Settings card, and whether the offered release's tag has already been
/// pulled (which turns "pull and rebuild" into just "rebuild").
public struct SourceCheckoutState: Sendable, Equatable {
    /// Current branch, nil on a detached HEAD or when git can't answer.
    public let branch: String?
    public let shortCommit: String?
    /// Whether the release tag asked about exists locally; nil when no tag
    /// was asked or git was unavailable — absent is never "not pulled".
    public let hasReleaseTag: Bool?

    public init(branch: String?, shortCommit: String?, hasReleaseTag: Bool?) {
        self.branch = branch
        self.shortCommit = shortCommit
        self.hasReleaseTag = hasReleaseTag
    }
}

/// The GitHub channel's source-checkout forensics: a few `git rev-parse`
/// reads against the checkout the bundle lives in. STRICTLY LOCAL — this
/// never runs a networked git command (fetch, pull, ls-remote), because
/// those would spend the user's own credentials against hosts outside
/// spec §10's destinations. Every failure degrades to nil fields; a probe
/// can never invent checkout state.
public enum SourceCheckoutProbe {
    public static func probe(root: URL, releaseTag: String?) async -> SourceCheckoutState {
        guard let commit = await git(root, ["rev-parse", "--short", "HEAD"]) else {
            // No git, or not actually a repo — the channel line stays bare.
            return SourceCheckoutState(branch: nil, shortCommit: nil, hasReleaseTag: nil)
        }
        // `--abbrev-ref HEAD` prints the literal "HEAD" when detached —
        // that is an absence of a branch, not a branch named HEAD.
        let branchName = await git(root, ["rev-parse", "--abbrev-ref", "HEAD"])
        var hasTag: Bool?
        if let releaseTag, !releaseTag.isEmpty {
            // Exit status is the whole answer; the refs/tags/ prefix keeps
            // it about a tag, never a same-named branch.
            hasTag = await git(
                root, ["rev-parse", "--verify", "--quiet", "refs/tags/\(releaseTag)"]) != nil
        }
        return SourceCheckoutState(
            branch: branchName == "HEAD" ? nil : branchName,
            shortCommit: commit,
            hasReleaseTag: hasTag)
    }

    /// The variables through which git is told WHERE its repository is. Git
    /// exports them to every hook it runs (always, in a bare-repo-plus-
    /// worktrees layout like this project's), and they outrank `-C`: a child
    /// `git -C <root>` that inherits `GIT_DIR` reads — or WRITES — the
    /// inherited repository instead of the one at `<root>`. On 2026-09-19
    /// this suite's throwaway-repo fixture, run by the pre-push hook,
    /// committed "one", tagged v1.2.3 and set `user.name = Test` in the real
    /// repository that way.
    static let gitDiscoveryVariables: Set<String> = [
        "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
        "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_NAMESPACE", "GIT_PREFIX",
    ]

    /// An environment under which `git -C <root>` means `<root>` and nothing
    /// else. Everything that spawns git for this probe — the tests' fixture
    /// included — runs under it.
    static func gitEnvironment(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        environment.filter { !gitDiscoveryVariables.contains($0.key) }
    }

    /// One local git read: trimmed stdout on exit 0, nil on anything else.
    /// Output rides a temp file so nothing non-Sendable crosses the
    /// termination handler.
    private static func git(_ root: URL, _ arguments: [String]) async -> String? {
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "usage-git-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        else { return nil }
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let status: Int32 = await withCheckedContinuation { continuation in
            guard let handle = FileHandle(forWritingAtPath: outputURL.path) else {
                continuation.resume(returning: -1)
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            process.environment = gitEnvironment()
            process.standardOutput = handle
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
        guard status == 0,
              let text = try? String(contentsOf: outputURL, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
