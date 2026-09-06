import Foundation
import Testing
@testable import UsageCore

@Suite("ClaudeHome")
struct ClaudeHomeTests {
    @Test("the standard home keeps its identity record beside itself")
    func standardHome() {
        let user = URL(filePath: "/Users/someone")
        let home = ClaudeHome.standard(userHome: user)
        #expect(home.isStandard)
        #expect(home.profileID == "default")
        #expect(home.keychainService == "Claude Code-credentials")
        #expect(home.identityFileURL.path == "/Users/someone/.claude.json")
        #expect(home.credentialsFileURL.path == "/Users/someone/.claude/.credentials.json")
        #expect(home.projectsDirectory.path == "/Users/someone/.claude/projects")
        #expect(home.promptHistoryURL.path == "/Users/someone/.claude/history.jsonl")
        #expect(home.settingsFileURL.path == "/Users/someone/.claude/settings.json")
        #expect(home.displayPath == "~/.claude")
        #expect(home.displayPath(of: home.identityFileURL) == "~/.claude.json")
        #expect(home.displayPath(of: home.projectsDirectory) == "~/.claude/projects")
    }

    @Test("a custom home keeps everything inside itself and carries Claude Code's suffix")
    func customHome() {
        let user = URL(filePath: "/Users/avihu")
        let home = ClaudeHome(directory: URL(filePath: "/Users/avihu/.claude-personal/"), userHome: user)
        #expect(!home.isStandard)
        #expect(home.directory.path == "/Users/avihu/.claude-personal")
        #expect(home.profileID == "c982130e")
        #expect(home.keychainService == "Claude Code-credentials-c982130e")
        #expect(home.identityFileURL.path == "/Users/avihu/.claude-personal/.claude.json")
        #expect(home.credentialsFileURL.path == "/Users/avihu/.claude-personal/.credentials.json")
        #expect(home.projectsDirectory.path == "/Users/avihu/.claude-personal/projects")
        #expect(home.displayPath == "~/.claude-personal")
        #expect(home.displayPath(of: home.settingsFileURL) == "~/.claude-personal/settings.json")
    }

    @Test("a path with dot segments standardizes without touching symlinks")
    func standardizes() {
        let user = URL(filePath: "/Users/avihu")
        let home = ClaudeHome(directory: URL(filePath: "/Users/avihu/personal/../.claude-personal"), userHome: user)
        #expect(home.directory.path == "/Users/avihu/.claude-personal")
        #expect(home.profileID == "c982130e")
    }

    @Test("looksLikeHome wants a projects tree, a history, or an inner identity record")
    func looksLikeHome() throws {
        let root = try TempHomes()
        defer { root.tearDown() }
        try root.make(".claude", with: ["projects/"])
        try root.make(".claude-personal", with: ["history.jsonl"])
        try root.make(".claude-work", with: [".claude.json"])
        try root.make(".claude-squad", with: ["settings.json", "config.json"])
        try root.make(".claude-empty", with: [])
        // The standard home keeps its identity record OUTSIDE — one inside
        // is not evidence.
        try root.make(".claude-odd", with: [])

        #expect(root.home(".claude").looksLikeHome)
        #expect(root.home(".claude-personal").looksLikeHome)
        #expect(root.home(".claude-work").looksLikeHome)
        #expect(!root.home(".claude-squad").looksLikeHome)
        #expect(!root.home(".claude-empty").looksLikeHome)
        #expect(!root.home(".claude-missing").looksLikeHome)

        let standardWithInnerIdentity = try TempHomes()
        defer { standardWithInnerIdentity.tearDown() }
        try standardWithInnerIdentity.make(".claude", with: [".claude.json"])
        #expect(!standardWithInnerIdentity.home(".claude").looksLikeHome)
    }

    @Test("discoverSiblings lists .claude* directories that look like homes — never files, never the standard home")
    func discoverSiblings() throws {
        let root = try TempHomes()
        defer { root.tearDown() }
        try root.make(".claude", with: ["projects/"])
        try root.make(".claude-work", with: ["projects/"])
        try root.make(".claude-personal", with: ["history.jsonl"])
        try root.make(".claude-squad", with: ["settings.json"])
        try root.make("other", with: ["projects/"])
        try root.file(".claude.json")
        try root.file(".claude.json.backup")
        try root.file(".claude-notes.txt")

        let found = ClaudeHome.discoverSiblings(of: root.home(".claude"))
        #expect(found.map(\.displayPath) == ["~/.claude-personal", "~/.claude-work"])
        #expect(found.allSatisfy { !$0.isStandard })
        #expect(found.map(\.profileID).allSatisfy { $0.count == 8 })
    }

    @Test("discovery over a missing parent is empty, not an error")
    func discoverNothing() {
        let ghost = ClaudeHome.standard(userHome: URL(filePath: "/nonexistent/\(UUID().uuidString)"))
        #expect(ClaudeHome.discoverSiblings(of: ghost).isEmpty)
    }

    @Test("the home's credential chain reads its own file, then its own Keychain item")
    func credentialChain() throws {
        let user = URL(filePath: "/Users/avihu")
        let home = ClaudeHome(directory: URL(filePath: "/Users/avihu/.claude-personal"), userHome: user)
        let chain = CredentialChain.standard(for: home)
        #expect(chain.sources.count == 2)
        let file = try #require(chain.sources[0] as? FileCredentialSource)
        #expect(file.fileURL.path == "/Users/avihu/.claude-personal/.credentials.json")
        let keychain = try #require(chain.sources[1] as? KeychainCredentialSource)
        #expect(keychain.service == "Claude Code-credentials-c982130e")
    }
}

/// A temp "user home" holding synthetic `.claude*` entries.
struct TempHomes {
    let userHome: URL

    init() throws {
        userHome = FileManager.default.temporaryDirectory
            .appending(path: "claude-homes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
    }

    /// Entries ending in "/" become directories, the rest empty files.
    func make(_ name: String, with entries: [String]) throws {
        let directory = userHome.appending(path: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in entries {
            let url = directory.appending(path: entry)
            if entry.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data("{}".utf8).write(to: url)
            }
        }
    }

    func file(_ name: String) throws {
        try Data("{}".utf8).write(to: userHome.appending(path: name))
    }

    func home(_ name: String) -> ClaudeHome {
        ClaudeHome(directory: userHome.appending(path: name), userHome: userHome)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: userHome)
    }
}
