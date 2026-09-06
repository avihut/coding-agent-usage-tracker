import Foundation
import Testing
@testable import UsageCore

@Suite("Profile model and store")
struct ProfileStoreTests {
    private let suiteName = "profile-store-tests-\(UUID().uuidString)"

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    private func tearDown(_ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("profiles round-trip through the defaults blob, homes as paths")
    func roundTrip() {
        let defaults = defaults()
        defer { tearDown(defaults) }
        let added = Date(timeIntervalSince1970: 1_757_000_000)
        let personal = Profile(
            id: "c982130e", providerID: "claude", home: URL(filePath: "/Users/avihu/.claude-personal"),
            nickname: "Personal", monogram: "P", enabled: true, showInMenuBar: false, order: 2,
            addedAt: added)
        let dismissed = Profile(
            id: "1a2b3c4d", providerID: "claude", home: URL(filePath: "/Users/avihu/.claude-old"),
            enabled: false, order: 3, addedAt: added, ignoredIdentityKey: "u|o")
        let codex = Profile(id: "default", providerID: "codex", home: nil, addedAt: added)

        ProfileStore.save([personal, dismissed, codex], to: defaults)
        let loaded = ProfileStore.load(from: defaults)

        #expect(loaded == [personal, dismissed, codex])
        #expect(loaded[0].home?.path == "/Users/avihu/.claude-personal")
        #expect(loaded[1].isDismissed && !loaded[1].isEnrolled)
        #expect(loaded[2].home == nil)
        // The blob is plain JSON with the home under `homePath`.
        let json = String(decoding: defaults.data(forKey: "meteringProfiles")!, as: UTF8.self)
        #expect(json.contains("\"homePath\":\"/Users/avihu/.claude-personal\""))
        #expect(!json.contains("\"home\":"))
    }

    @Test("a record missing newer keys decodes with defaults")
    func lenientDecode() throws {
        let json = """
        [{"id":"default","providerID":"claude","addedAt":"2026-09-06T10:00:00Z"}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profiles = try decoder.decode([Profile].self, from: Data(json.utf8))
        #expect(profiles.count == 1)
        #expect(profiles[0].enabled && profiles[0].showInMenuBar)
        #expect(profiles[0].order == 0)
        #expect(profiles[0].home == nil)
        #expect(profiles[0].isDefault)
    }

    @Test("an empty or corrupt blob loads as no profiles")
    func emptyLoad() {
        let defaults = defaults()
        defer { tearDown(defaults) }
        #expect(ProfileStore.load(from: defaults).isEmpty)
        defaults.set(Data("not json".utf8), forKey: "meteringProfiles")
        #expect(ProfileStore.load(from: defaults).isEmpty)
    }

    @Test("the pin is stored and cleared")
    func pin() {
        let defaults = defaults()
        defer { tearDown(defaults) }
        #expect(ProfileStore.pin(from: defaults) == nil)
        ProfileStore.setPin("c982130e", in: defaults)
        #expect(ProfileStore.pin(from: defaults) == "c982130e")
        ProfileStore.setPin(nil, in: defaults)
        #expect(ProfileStore.pin(from: defaults) == nil)
    }

    @Test("resolved synthesizes the default profile first, from the provider's home")
    func resolvedSynthesizesDefault() {
        let now = Date()
        let provider = ClaudeProvider(home: .standard(userHome: URL(filePath: "/Users/someone")))
        let personal = Profile(
            id: "c982130e", providerID: "claude", home: URL(filePath: "/Users/someone/.claude-personal"),
            order: 0, addedAt: now)
        let resolved = ProfileStore.resolved([personal], provider: provider, now: now)
        #expect(resolved.map(\.id) == ["default", "c982130e"])
        #expect(resolved[0].home?.path == "/Users/someone/.claude")
        #expect(resolved[0].order == -1)
        #expect(resolved[0].addedAt == now)
        #expect(resolved[0].scopeKey == "claude")
        #expect(resolved[1].scopeKey == "claude.c982130e")
    }

    @Test("resolved keeps the stored default's edits but refreshes its home")
    func resolvedKeepsDefaultEdits() {
        let now = Date()
        let provider = ClaudeProvider(home: .standard(userHome: URL(filePath: "/Users/someone")))
        let stored = Profile(
            id: "default", providerID: "claude", home: URL(filePath: "/stale"), nickname: "Work",
            showInMenuBar: false, order: 5, addedAt: now.addingTimeInterval(-86400))
        let resolved = ProfileStore.resolved([stored], provider: provider, now: now)
        #expect(resolved.count == 1)
        #expect(resolved[0].nickname == "Work")
        #expect(!resolved[0].showInMenuBar)
        #expect(resolved[0].home?.path == "/Users/someone/.claude")
    }

    @Test("resolved orders by order then addedAt and ignores other providers")
    func resolvedOrders() {
        let now = Date()
        let provider = ClaudeProvider(home: .standard(userHome: URL(filePath: "/Users/someone")))
        let a = Profile(id: "aaaaaaaa", providerID: "claude", home: URL(filePath: "/a"), order: 2, addedAt: now)
        let b = Profile(id: "bbbbbbbb", providerID: "claude", home: URL(filePath: "/b"), order: 1, addedAt: now)
        let c = Profile(id: "cccccccc", providerID: "claude", home: URL(filePath: "/c"), order: 2,
                        addedAt: now.addingTimeInterval(-10))
        let codex = Profile(id: "default", providerID: "codex", home: nil, addedAt: now)
        let resolved = ProfileStore.resolved([a, b, c, codex], provider: provider, now: now)
        #expect(resolved.map(\.id) == ["default", "bbbbbbbb", "cccccccc", "aaaaaaaa"])
    }

    @Test("a single-home provider resolves to exactly its default")
    func singleHomeProvider() {
        let now = Date()
        let stray = Profile(id: "deadbeef", providerID: "codex", home: URL(filePath: "/x"), addedAt: now)
        let resolved = ProfileStore.resolved([stray], provider: CodexProvider(), now: now)
        #expect(resolved.map(\.id) == ["default"])
        #expect(resolved[0].home == nil)
    }

    @Test("labels: nickname, then email, then the home's name, then the id")
    func labels() {
        let now = Date()
        let identity = AccountIdentity(accountUuid: "u", organizationUuid: "o", email: "p@example.com")
        var profile = Profile(
            id: "c982130e", providerID: "claude", home: URL(filePath: "/Users/x/.claude-personal"),
            addedAt: now)
        #expect(ProfileFacts.label(profile: profile, identity: identity) == "p@example.com")
        #expect(ProfileFacts.label(profile: profile, identity: nil) == "claude-personal")
        profile.nickname = "  Personal "
        #expect(ProfileFacts.label(profile: profile, identity: identity) == "Personal")
        let homeless = Profile(id: "default", providerID: "codex", home: nil, addedAt: now)
        #expect(ProfileFacts.label(profile: homeless, identity: nil) == "default")

        #expect(ProfileFacts.monogram(profile: profile, label: "Personal") == "P")
        profile.monogram = "w"
        #expect(ProfileFacts.monogram(profile: profile, label: "Personal") == "W")
        #expect(ProfileFacts.monogram(profile: homeless, label: "") == "?")

        // No nickname, no monogram: a custom home's folder name beats the
        // email's initial (two accounts' emails routinely share one).
        let unnamed = Profile(
            id: "c982130e", providerID: "claude", home: URL(filePath: "/Users/x/.claude-personal"),
            addedAt: now)
        #expect(ProfileFacts.monogram(profile: unnamed, label: "avihu@example.com") == "P")
        let underscored = Profile(
            id: "1a2b3c4d", providerID: "claude", home: URL(filePath: "/Users/x/.claude_work"),
            addedAt: now)
        #expect(ProfileFacts.monogram(profile: underscored, label: "avihu@example.com") == "W")
        // The standard home has no such suffix: the label's initial.
        let standard = Profile(
            id: "default", providerID: "claude", home: URL(filePath: "/Users/x/.claude"), addedAt: now)
        #expect(ProfileFacts.monogram(profile: standard, label: "avihu@example.com") == "A")
    }
}
