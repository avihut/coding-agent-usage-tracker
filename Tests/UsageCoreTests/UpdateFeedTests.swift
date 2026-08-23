import Foundation
import Testing

@testable import UsageCore

/// The release feed against the GitHub `releases/latest` shape, plus the
/// release→card mapping and the install-kind gate that decides whether any
/// of this runs.
@Suite("UpdateFeed")
struct UpdateFeedTests {
    static func fixtureData() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/update/releases-latest.json")
        return try Data(contentsOf: url)
    }

    @Test("a release decodes to tag, page, date, and assets — extras ignored")
    func decode() throws {
        let release = try GitHubRelease.decode(from: Self.fixtureData())

        #expect(release.tag == "v0.87.0")
        #expect(release.version == "0.87.0")
        #expect(release.pageURL.hasSuffix("/releases/tag/v0.87.0"))
        #expect(release.publishedAt != nil)
        #expect(release.assets.count == 2)
    }

    @Test("the update asset is the versioned zip, never the checksums file")
    func assetSelection() throws {
        let release = try GitHubRelease.decode(from: Self.fixtureData())
        let asset = try #require(release.updateAsset)

        #expect(asset.name == "ClaudeUsage-0.87.0.zip")
        #expect(asset.bytes == 6_234_881)
        #expect(asset.downloadURL.hasSuffix("/ClaudeUsage-0.87.0.zip"))
    }

    @Test("a release without the versioned name falls back to any zip")
    func assetFallback() throws {
        let json = """
            {"tag_name": "v1.0.0", "html_url": "https://example.com/r",
             "assets": [
               {"name": "notes.txt", "browser_download_url": "https://example.com/n", "size": 1},
               {"name": "app.zip", "browser_download_url": "https://example.com/z", "size": 2}]}
            """
        let release = try GitHubRelease.decode(from: Data(json.utf8))
        #expect(release.updateAsset?.name == "app.zip")

        let bare = try GitHubRelease.decode(
            from: Data(#"{"tag_name": "v1.0.0", "html_url": "https://example.com/r"}"#.utf8))
        #expect(bare.updateAsset == nil)
    }

    @Test("malformed payloads throw instead of producing a release")
    func malformed() {
        #expect(throws: (any Error).self) {
            try GitHubRelease.decode(from: Data("not json".utf8))
        }
        // A shape without the essentials is malformed even as valid JSON.
        #expect(throws: (any Error).self) {
            try GitHubRelease.decode(from: Data(#"{"draft": false}"#.utf8))
        }
    }

    @Test("the card flags an update only for a strictly newer release")
    func cardMapping() throws {
        let release = try GitHubRelease.decode(from: Self.fixtureData())
        let now = Date(timeIntervalSince1970: 1_787_000_000)

        let behind = UpdateChecker.card(from: release, currentVersion: "0.86.1", checkedAt: now)
        #expect(behind.updateAvailable)
        #expect(behind.latestVersion == "0.87.0")
        #expect(behind.assetName == "ClaudeUsage-0.87.0.zip")
        #expect(behind.assetURL?.hasSuffix(".zip") == true)
        #expect(behind.checkedAt == now)

        // Equal and ahead both stay quiet — a dev build past the release
        // must not be offered a downgrade.
        #expect(!UpdateChecker.card(from: release, currentVersion: "0.87.0", checkedAt: now)
            .updateAvailable)
        #expect(!UpdateChecker.card(from: release, currentVersion: "0.88.0", checkedAt: now)
            .updateAvailable)
    }

    @Test("the feed URL targets exactly one endpoint")
    func endpoint() {
        #expect(UpdateFeed.latestURL(repository: "avihut/coding-agent-usage-tracker")
            .absoluteString
            == "https://api.github.com/repos/avihut/coding-agent-usage-tracker/releases/latest")
    }
}

/// Whether this copy of the app is the updater's business at all.
@Suite("InstallKind")
struct InstallKindTests {
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "installkind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("a bundle inside a git checkout is source-managed — worktree .git FILES included")
    func sourceManaged() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        // Contained-layout worktree: .git is a FILE at the repo root. The
        // reported root is the NEAREST .git-bearing ancestor.
        let repo = root.appending(path: "repo")
        let app = repo.appending(path: "main/ClaudeUsage.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("gitdir: ../.git/worktrees/main".utf8)
            .write(to: repo.appending(path: ".git"))
        guard case .sourceManaged(let worktreeRoot) = InstallKind.detect(bundleURL: app) else {
            Issue.record("expected sourceManaged for a worktree bundle")
            return
        }
        #expect(worktreeRoot.path == repo.path)

        // Plain clone: .git is a directory.
        let clone = root.appending(path: "clone")
        let cloneApp = clone.appending(path: "ClaudeUsage.app")
        try FileManager.default.createDirectory(
            at: clone.appending(path: ".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloneApp, withIntermediateDirectories: true)
        guard case .sourceManaged(let cloneRoot) = InstallKind.detect(bundleURL: cloneApp) else {
            Issue.record("expected sourceManaged for a clone bundle")
            return
        }
        #expect(cloneRoot.path == clone.path)
    }

    @Test("a bundle outside any checkout is a standalone install")
    func standalone() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Applications/ClaudeUsage.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(InstallKind.detect(bundleURL: app) == .standaloneApp)
    }

    @Test("bare executables and test bundles get no updater")
    func notAnApp() {
        #expect(InstallKind.detect(
            bundleURL: URL(fileURLWithPath: "/tmp/x/UsageCoreTests.xctest")) == .notAnApp)
        #expect(InstallKind.detect(
            bundleURL: URL(fileURLWithPath: "/tmp/x/debug")) == .notAnApp)
    }
}

/// Install → distribution channel: the seam every update surface renders
/// through.
@Suite("DistributionChannel")
struct DistributionChannelTests {
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "distchannel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("a standalone install is the GitHub channel's release flavor — self-installing")
    func releaseFlavor() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Applications/ClaudeUsage.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        let channel = try #require(Distribution.channel(for: app) as? GitHubChannel)
        #expect(channel.flavor == .releaseInstall)
        #expect(channel.canSelfInstall)
        #expect(channel.manualUpdateHint == nil)
        #expect(channel.updateFeedURL
            == UpdateFeed.latestURL(repository: AppIdentity.repository))
    }

    @Test("a checkout build is the GitHub channel's source flavor — informing, never installing")
    func sourceFlavor() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appending(path: "repo")
        let app = repo.appending(path: "ClaudeUsage.app")
        try FileManager.default.createDirectory(
            at: repo.appending(path: ".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("[tasks.app]".utf8).write(to: repo.appending(path: "mise.toml"))

        let channel = try #require(Distribution.channel(for: app) as? GitHubChannel)
        guard case .sourceCheckout(let found) = channel.flavor else {
            Issue.record("expected the source flavor inside a checkout")
            return
        }
        #expect(found.path == repo.path)
        #expect(!channel.canSelfInstall)
        // The checkout carries mise.toml, so the hint names the real task.
        #expect(channel.manualUpdateHint?.contains("mise run app") == true)
        // Same feed in both flavors — knowing you're behind is half the point.
        #expect(channel.updateFeedURL
            == UpdateFeed.latestURL(repository: AppIdentity.repository))
    }

    @Test("bare executables belong to no channel at all")
    func noChannel() {
        #expect(Distribution.channel(for: URL(fileURLWithPath: "/tmp/x/debug")) == nil)
    }

    @Test("the drill's feed override forces self-install even inside a checkout")
    func overrideForcesInstall() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appending(path: "repo")
        let app = repo.appending(path: "ClaudeUsage.app")
        try FileManager.default.createDirectory(
            at: repo.appending(path: ".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        let suite = "distchannel-defaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!Distribution.allowsSelfInstall(bundleURL: app, defaults: defaults))
        defaults.set(
            "http://localhost:9999/feed.json", forKey: UpdateChecker.feedOverrideKey)
        #expect(Distribution.allowsSelfInstall(bundleURL: app, defaults: defaults))
    }
}
