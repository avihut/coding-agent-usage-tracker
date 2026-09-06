import Foundation
import Testing

@testable import UsageCore

/// `ProfileSelector` — which account a CLI invocation answers for. The
/// digest is the golden (two profiles: `default` = work@example.com at
/// ~/.claude, `c982130e` = "Personal" at ~/.claude-personal); the store and
/// the home facts are synthetic under /Users/t.
@Suite("Profile selector")
struct ProfileSelectorTests {
    let golden: LiveState
    let homes = ProfileSelector.Homes(
        environmentVariable: "CLAUDE_CONFIG_DIR",
        standard: URL(fileURLWithPath: "/Users/t/.claude"),
        userHome: URL(fileURLWithPath: "/Users/t"))
    let personal = Profile(
        id: "c982130e", providerID: "claude", home: URL(fileURLWithPath: "/Users/t/.claude-personal"),
        nickname: "Personal", addedAt: Date(timeIntervalSince1970: 1_755_000_000))

    init() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/digest/live-state-v1.json")
        golden = try LiveState.decoder().decode(LiveState.self, from: Data(contentsOf: fixtureURL))
    }

    private func resolve(
        flag: String? = nil, env: [String: String] = [:], digest: LiveState?? = nil,
        profiles: [Profile]? = nil, homes: ProfileSelector.Homes? = nil
    ) -> Result<ProfileSelector.Selection, ProfileSelector.Unknown> {
        ProfileSelector.resolve(
            flag: flag, environment: env, digest: digest ?? golden,
            profiles: profiles ?? [personal], homes: homes ?? self.homes)
    }

    @Test("precedence: the flag, then the home variable, then the focus, then default")
    func precedence() throws {
        let env = ["CLAUDE_CONFIG_DIR": "/Users/t/.claude-personal"]
        #expect(try resolve(flag: "default", env: env).get() == .init(id: "default", source: .flag))
        #expect(try resolve(env: env).get() == .init(id: "c982130e", source: .environment))
        #expect(try resolve().get() == .init(id: "default", source: .focus))
        // No digest at all: the default profile, stated as such.
        #expect(try resolve(digest: .some(nil)).get() == .init(id: "default", source: .default))
    }

    @Test("the flag matches an id, a nickname, the digest's label, or a home path")
    func flagForms() throws {
        for selector in [
            "c982130e", "C982130E", "personal", "Personal", "~/.claude-personal",
            "/Users/t/.claude-personal", "/Users/t/.claude-personal/",
        ] {
            #expect(try resolve(flag: selector).get().id == "c982130e", "selector \(selector)")
        }
        #expect(try resolve(flag: "work@example.com").get().id == "default")
        #expect(try resolve(flag: "~/.claude").get().id == "default")
        // A home the digest names but the store has no record of still
        // resolves by the id its path derives to.
        #expect(try resolve(flag: "/Users/t/.claude-personal", profiles: []).get().id == "c982130e")
    }

    @Test("an unknown selection refuses and lists every known account")
    func unknownRefuses() throws {
        guard case .failure(let unknown) = resolve(flag: "nope") else {
            Issue.record("expected a refusal"); return
        }
        #expect(unknown.selector == "nope")
        #expect(unknown.known == ["default", "c982130e"])
        #expect(unknown.message == "no such account: nope — accounts: default, c982130e")

        // A record the store enrolled but the writer has not published yet
        // is known — listed after the digest's own.
        let fresh = Profile(
            id: "abcd1234", providerID: "claude", home: URL(fileURLWithPath: "/Users/t/.claude-x"),
            addedAt: Date())
        guard case .failure(let listed) = resolve(flag: "nope", profiles: [personal, fresh]) else {
            Issue.record("expected a refusal"); return
        }
        #expect(listed.known == ["default", "c982130e", "abcd1234"])
        #expect(try resolve(flag: "~/.claude-x", profiles: [personal, fresh]).get().id == "abcd1234")
        // A dismissed discovery is not an account.
        let dismissed = Profile(
            id: "dddd0000", providerID: "claude", home: URL(fileURLWithPath: "/Users/t/.claude-d"),
            addedAt: Date(), ignoredIdentityKey: "k")
        guard case .failure(let noDismissed) = resolve(flag: "~/.claude-d", profiles: [dismissed]) else {
            Issue.record("expected a refusal"); return
        }
        #expect(noDismissed.known == ["default", "c982130e"])
    }

    @Test("the home variable maps its path to an id — trailing slash, tilde, the standard home")
    func environment() throws {
        for value in ["/Users/t/.claude-personal", "/Users/t/.claude-personal/", "~/.claude-personal"] {
            #expect(try resolve(env: ["CLAUDE_CONFIG_DIR": value]).get() == .init(id: "c982130e", source: .environment))
        }
        for value in ["/Users/t/.claude", "/Users/t/.claude/", "~/.claude"] {
            #expect(try resolve(env: ["CLAUDE_CONFIG_DIR": value]).get() == .init(id: "default", source: .environment))
        }
        // Set but empty: as good as unset.
        #expect(try resolve(env: ["CLAUDE_CONFIG_DIR": " "]).get().source == .focus)
        // A home nobody meters is a refusal naming the variable — never
        // the other account's numbers.
        guard case .failure(let unknown) = resolve(env: ["CLAUDE_CONFIG_DIR": "/Users/t/.claude-squad"]) else {
            Issue.record("expected a refusal"); return
        }
        #expect(unknown.selector == "CLAUDE_CONFIG_DIR=/Users/t/.claude-squad")
        #expect(unknown.known == ["default", "c982130e"])
        // A provider without homes never reads the environment.
        #expect(try resolve(
            env: ["CLAUDE_CONFIG_DIR": "/Users/t/.claude-squad"], homes: ProfileSelector.Homes.none
        ).get().source == .focus)
    }

    @Test("a pre-profile digest exposes default alone; the store adds what it enrolled")
    func legacyDigest() throws {
        let legacy = LiveState(
            engine: golden.engine, meters: golden.meters, menuBar: golden.menuBar, models: golden.models,
            activity: golden.activity, sessions: golden.sessions)
        #expect(ProfileSelector.knownIDs(digest: legacy, profiles: []) == ["default"])
        #expect(ProfileSelector.knownIDs(digest: legacy, profiles: [personal]) == ["default", "c982130e"])
        #expect(try resolve(digest: .some(legacy)).get() == .init(id: "default", source: .default))
        #expect(try resolve(flag: "personal", digest: .some(legacy)).get().id == "c982130e")
        #expect(try resolve(env: ["CLAUDE_CONFIG_DIR": "~/.claude-personal"], digest: .some(legacy)).get().id == "c982130e")
        guard case .failure = resolve(flag: "personal", digest: .some(legacy), profiles: []) else {
            Issue.record("expected a refusal"); return
        }
    }

    @Test("the provider's facts fill the home context")
    func providerHomes() {
        let claude = ProfileSelector.Homes(provider: ClaudeProvider(), userHome: URL(fileURLWithPath: "/Users/t"))
        #expect(claude.environmentVariable == "CLAUDE_CONFIG_DIR")
        #expect(claude.standard == ClaudeHome.standard.directory)
        let codex = ProfileSelector.Homes(provider: CodexProvider())
        #expect(codex.environmentVariable == nil && codex.standard == nil)
    }

    @Test("deep verbs read the selected profile's own directory")
    func profileDirectory() {
        let roots = StorageScope.Roots(
            support: URL(fileURLWithPath: "/tmp/support"), caches: URL(fileURLWithPath: "/tmp/caches"))
        let personal = DeepQuery.profileDirectory(providerID: "claude", profileID: "c982130e", roots: roots)
        #expect(personal.path.hasSuffix("/claude/c982130e"))
        #expect(personal.path.hasPrefix("/tmp/support/"))
        let standard = DeepQuery.profileDirectory(providerID: "claude", profileID: "default", roots: roots)
        #expect(standard.path.hasSuffix("/claude/default"))
    }
}
