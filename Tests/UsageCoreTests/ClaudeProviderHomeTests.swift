import Foundation
import Testing
@testable import UsageCore

@Suite("ClaudeProvider per home")
struct ClaudeProviderHomeTests {
    @Test("the default provider reads exactly the paths it always did")
    func defaultProviderUnchanged() throws {
        let provider = ClaudeProvider()
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        #expect(provider.home.isStandard)
        #expect(provider.homeDirectory?.path == userHome.appending(path: ".claude").path)
        #expect(provider.supportsMultipleHomes)

        #expect(provider.credentials.sources.map(\.name) == CredentialChain.standard.sources.map(\.name))
        #expect(provider.credentials.sources.map(\.name) == [
            "file (~/.claude/.credentials.json)",
            "keychain (login, service \"Claude Code-credentials\")",
        ])
        #expect(provider.accountIdentity?.displayPath == "~/.claude.json")
        #expect(provider.agentSettings?.displayPath == "~/.claude/settings.json")

        let temp = FileManager.default.temporaryDirectory
            .appending(path: "provider-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let activity = try #require(provider.makeLocalActivity(cacheDirectory: temp))
        #expect(activity.displayPath == "~/.claude/projects")
        #expect(activity.watchDirectories.map(\.path)
            == [userHome.appending(path: ".claude/projects").path])
    }

    @Test("withHome retargets every path and the Keychain item, and keeps the vendor id")
    func withHomeRetargets() throws {
        let user = URL(filePath: "/Users/avihu")
        let base = ClaudeProvider(home: .standard(userHome: user))
        let retargeted = try #require(
            base.withHome(URL(filePath: "/Users/avihu/.claude-personal")) as? ClaudeProvider)

        #expect(retargeted.id == "claude")
        #expect(retargeted.home.profileID == "c982130e")
        #expect(retargeted.homeDirectory?.path == "/Users/avihu/.claude-personal")
        let keychain = try #require(retargeted.credentials.sources[1] as? KeychainCredentialSource)
        #expect(keychain.service == "Claude Code-credentials-c982130e")
        let file = try #require(retargeted.credentials.sources[0] as? FileCredentialSource)
        #expect(file.fileURL.path == "/Users/avihu/.claude-personal/.credentials.json")
        #expect(retargeted.accountIdentity?.displayPath == "~/.claude-personal/.claude.json")
        #expect(retargeted.agentSettings?.displayPath == "~/.claude-personal/settings.json")

        let temp = FileManager.default.temporaryDirectory
            .appending(path: "provider-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let activity = try #require(retargeted.makeLocalActivity(cacheDirectory: temp))
        #expect(activity.displayPath == "~/.claude-personal/projects")
        #expect(activity.watchDirectories.map(\.path) == ["/Users/avihu/.claude-personal/projects"])
    }

    @Test("an injected credential chain is kept for the home it was built for")
    func injectedChainKept() {
        let chain = CredentialChain(sources: [StaticCredentialSource(name: "stub")])
        let provider = ClaudeProvider(credentials: chain)
        #expect(provider.credentials.sources.map(\.name) == ["stub"])
    }

    @Test("discoverHomes lists the standard home's siblings, never itself")
    func discoverHomes() throws {
        let root = try TempHomes()
        defer { root.tearDown() }
        try root.make(".claude", with: ["projects/"])
        try root.make(".claude-personal", with: ["projects/"])
        try root.make(".claude-squad", with: ["settings.json"])

        let provider = ClaudeProvider(home: root.home(".claude"))
        #expect(provider.discoverHomes().map(\.lastPathComponent) == [".claude-personal"])
        // A custom-home instance discovers against the SAME standard home.
        let personal = provider.withHome(root.userHome.appending(path: ".claude-personal"))
        #expect(personal.discoverHomes().map(\.lastPathComponent) == [".claude-personal"])
    }

    @Test("providers without homes decline the capability")
    func singleHomeProviders() {
        for provider in [CodexProvider(), GeminiProvider()] as [any UsageProvider] {
            #expect(!provider.supportsMultipleHomes)
            #expect(provider.homeDirectory == nil)
            #expect(provider.discoverHomes().isEmpty)
            #expect(provider.withHome(URL(filePath: "/tmp/x")).id == provider.id)
        }
    }
}
