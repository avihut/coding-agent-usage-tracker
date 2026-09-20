import Foundation
import Testing

@testable import UsageCore

/// Which account a `usage-cli` run answers for once several harnesses are
/// metered: keys first, names only when they name ONE account, paths inside
/// their own harness, `--provider` as a narrowing, and the refusals that keep
/// a run from quietly answering for the wrong vendor.
@Suite("Multi-harness selector")
struct MultiHarnessSelectorTests {
    private let now = Date(timeIntervalSince1970: 1_758_000_000)
    private let userHome = URL(filePath: "/Users/t")

    private var homes: [ProfileSelector.Homes] {
        [
            ProfileSelector.Homes(
                environmentVariable: "CLAUDE_CONFIG_DIR", standard: URL(filePath: "/Users/t/.claude"),
                userHome: userHome, providerID: "claude"),
            ProfileSelector.Homes(
                environmentVariable: nil, standard: nil, userHome: userHome, providerID: "codex"),
        ]
    }

    private var profiles: [Profile] {
        [
            Profile(
                id: "default", providerID: "claude", home: URL(filePath: "/Users/t/.claude"),
                addedAt: now),
            Profile(
                id: "c982130e", providerID: "claude", home: URL(filePath: "/Users/t/.claude-work"),
                nickname: "Work", order: 1, addedAt: now),
            Profile(id: "default", providerID: "codex", home: nil, nickname: "Work", addedAt: now),
        ]
    }

    /// A digest naming all three accounts, Codex holding focus.
    private func digest() -> LiveState {
        let claude = ClaudeProvider()
        let codex = CodexProvider()
        func section(_ provider: any UsageProvider) -> LiveState {
            LiveStateBuilder.build(
                provider: provider, host: "daemon", pid: 1, appVersion: "0.101.0", state: .loading,
                predictions: [:], samples: [], timeline: [], activity: [],
                pricing: provider.bundledRates, colorLedger: ModelColorLedger(),
                graceSeconds: ActivityGrace.defaultSeconds, activeInterval: 300, paceMultiplier: 1,
                nextPollAt: nil, backoffUntil: nil, apiBudget: nil, now: now)
        }
        return MeteringDigest.compose(
            harnesses: [HarnessSection(provider: claude), HarnessSection(provider: codex)],
            sections: profiles.map { profile in
                ProfileSection(
                    profile: profile,
                    label: profile.nickname ?? (profile.providerID == "codex" ? "Codex" : "work@example.com"),
                    monogram: "X", dormant: false, lastActivityAt: now,
                    homeDisplayPath: profile.home.map { PathDisplay.abbreviated($0, home: userHome) },
                    state: section(profile.providerID == "codex" ? codex : claude))
            },
            focused: "codex", host: "daemon", pid: 1, appVersion: "0.101.0", systemAccent: nil,
            activeInterval: 300, appUpdate: nil, nextReprobeAt: nil, now: now)
    }

    private func resolve(
        account: String? = nil, provider: String? = nil, environment: [String: String] = [:]
    ) -> Result<ProfileSelector.Selection, ProfileSelector.Unknown> {
        ProfileSelector.resolve(
            flag: account, provider: provider, environment: environment, digest: digest(),
            profiles: profiles, homes: homes)
    }

    @Test("a key names one account across every harness")
    func keys() throws {
        #expect(try resolve(account: "codex").get() == .init(id: "codex", source: .flag))
        #expect(try resolve(account: "default").get() == .init(id: "default", source: .flag))
        #expect(try resolve(account: "c982130e").get() == .init(id: "c982130e", source: .flag))
        // Focus answers when nothing is named — the digest's own word.
        #expect(try resolve().get() == .init(id: "codex", source: .focus))
    }

    /// Two harnesses both have an account nicknamed "Work". A name that can
    /// mean either is refused as a bad query, never guessed.
    @Test("an ambiguous name is refused; an id always wins")
    func ambiguity() {
        switch resolve(account: "Work") {
        case .success(let selection): Issue.record("expected a refusal, got \(selection)")
        case .failure(let unknown):
            #expect(unknown.kind == .ambiguous)
            #expect(unknown.matches == ["c982130e", "codex"])
            #expect(unknown.message.contains("more than one harness"))
        }
        // Naming the harness disambiguates.
        #expect((try? resolve(account: "Work", provider: "codex").get())?.id == "codex")
        #expect((try? resolve(account: "Work", provider: "claude").get())?.id == "c982130e")
    }

    @Test("--provider narrows to that harness, and contradicting --account is a bad query")
    func providerFlag() throws {
        #expect(try resolve(provider: "claude").get() == .init(id: "default", source: .provider))
        // Focus already sits on Codex, so naming it keeps the focused account.
        #expect(try resolve(provider: "codex").get() == .init(id: "codex", source: .provider))
        switch resolve(account: "default", provider: "codex") {
        case .success(let selection): Issue.record("expected a refusal, got \(selection)")
        case .failure(let unknown):
            #expect(unknown.kind == .contradiction)
            #expect(unknown.message.contains("different harnesses"))
        }
        // A harness nobody meters falls through — the verb's own gate, not
        // the selector, is what says "not wired for that provider".
        #expect(try resolve(provider: "nope").get() == .init(id: "codex", source: .focus))
    }

    /// The v0.95.0 safety rule, per harness: a home variable that names
    /// nothing metered refuses rather than answering for another account.
    @Test("a home variable selects inside its own harness, or refuses")
    func environmentVariable() throws {
        #expect(
            try resolve(environment: ["CLAUDE_CONFIG_DIR": "~/.claude-work"]).get()
                == .init(id: "c982130e", source: .environment))
        #expect(
            try resolve(environment: ["CLAUDE_CONFIG_DIR": "/Users/t/.claude"]).get()
                == .init(id: "default", source: .environment))
        switch resolve(environment: ["CLAUDE_CONFIG_DIR": "~/.claude-nobody-meters"]) {
        case .success(let selection): Issue.record("expected a refusal, got \(selection)")
        case .failure(let unknown):
            #expect(unknown.kind == .noMatch)
            #expect(unknown.message.contains("CLAUDE_CONFIG_DIR="))
        }
        // `--account` still wins over the environment.
        #expect(
            try resolve(account: "codex", environment: ["CLAUDE_CONFIG_DIR": "~/.claude-work"]).get()
                == .init(id: "codex", source: .flag))
    }

    /// A deep verb refuses on the SELECTED account's harness before it
    /// refuses on whether that account's section landed — otherwise a Codex
    /// account would be answered for out of Claude's ledger, or refused with
    /// the wrong reason.
    @Test("the deep verbs gate on the selected account's harness, ahead of projection")
    func deepVerbGate() {
        let out = DeepQuery.run(
            noun: "history", arguments: ["session", "--account", "codex"], digest: digest(),
            environment: [:], now: now, profiles: profiles, homes: homes)
        #expect(out.exitCode == DeepQuery.exitWrongProvider)
        #expect(out.note?.contains("'codex'") == true)

        // The bundled harness's own account still answers.
        let claude = DeepQuery.run(
            noun: "history", arguments: ["session", "--account", "default"], digest: digest(),
            environment: [:], now: now, profiles: profiles, homes: homes)
        #expect(claude.exitCode != DeepQuery.exitWrongProvider)
    }

    /// The digest nouns answer for whichever harness the account belongs to,
    /// projecting that section onto the top level.
    @Test("a digest noun answers for the named account's own harness")
    func digestNoun() throws {
        let state = digest()
        let raw = try LiveState.encoder().encode(state)
        let codex = DigestQuery.run(
            arguments: ["status", "provider"], digest: state, rawDigest: raw, environment: [:],
            now: now, profiles: profiles, homes: homes)
        #expect(codex.stdout == "codex")
        let claude = DigestQuery.run(
            arguments: ["status", "provider", "--account", "default"], digest: state,
            rawDigest: raw, environment: [:], now: now, profiles: profiles, homes: homes)
        #expect(claude.stdout == "claude")
        let byProvider = DigestQuery.run(
            arguments: ["status", "provider", "--provider", "claude"], digest: state,
            rawDigest: raw, environment: [:], now: now, profiles: profiles, homes: homes)
        #expect(byProvider.stdout == "claude")
        // `accounts selected` reports the key this run answered for.
        let selected = DigestQuery.run(
            arguments: ["accounts", "selected", "--account", "c982130e"], digest: state,
            rawDigest: raw, environment: [:], now: now, profiles: profiles, homes: homes)
        #expect(selected.stdout == "c982130e")
    }
}
