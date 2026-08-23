import Foundation
import Testing

@testable import UsageCore

/// The source flavor's local git forensics against a real throwaway
/// repository — and proof they stay graceful where git has nothing to say.
@Suite("SourceCheckoutProbe")
struct SourceCheckoutProbeTests {
    private struct GitFailed: Error {}

    /// A tiny real repository: one commit on branch `main`, tag v1.2.3.
    /// Local-only, like the probe itself.
    private func makeRepo() async throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await run(root, ["init", "-q", "-b", "main"])
        try await run(root, ["config", "user.email", "test@example.com"])
        try await run(root, ["config", "user.name", "Test"])
        try Data("x".utf8).write(to: root.appending(path: "file"))
        try await run(root, ["add", "file"])
        // --no-verify / gpgsign overrides: the machine's global hooks and
        // signing config must not decide whether this suite passes (a
        // global tag.gpgsign turns a plain tag into one demanding a
        // message).
        try await run(root, ["commit", "-q", "--no-verify", "--no-gpg-sign", "-m", "one"])
        try await run(root, ["-c", "tag.gpgsign=false", "tag", "v1.2.3"])
        return root
    }

    private func run(_ root: URL, _ arguments: [String]) async throws {
        let status: Int32 = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
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
        if status != 0 { throw GitFailed() }
    }

    @Test("branch, commit, and tag presence come back from a real checkout")
    func probesRealRepo() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let present = await SourceCheckoutProbe.probe(root: repo, releaseTag: "v1.2.3")
        #expect(present.branch == "main")
        #expect(present.shortCommit?.isEmpty == false)
        #expect(present.hasReleaseTag == true)

        let absent = await SourceCheckoutProbe.probe(root: repo, releaseTag: "v9.9.9")
        #expect(absent.hasReleaseTag == false)

        // No tag asked about → no answer, never a fabricated "not pulled".
        let unasked = await SourceCheckoutProbe.probe(root: repo, releaseTag: nil)
        #expect(unasked.hasReleaseTag == nil)
        #expect(unasked.branch == "main")
    }

    @Test("a directory that is no repository degrades to all-nil, never throws")
    func gracefulOutsideRepo() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "probe-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let state = await SourceCheckoutProbe.probe(root: dir, releaseTag: "v1.0.0")
        #expect(state == SourceCheckoutState(
            branch: nil, shortCommit: nil, hasReleaseTag: nil))
    }
}
