import Foundation
import Testing

@testable import UsageCore

/// Which harnesses a host meters, in what order, and which the person sees —
/// plus the two floors that keep a machine from metering or showing nothing.
@Suite("Harness roster")
struct HarnessRosterTests {
    private let now = Date(timeIntervalSince1970: 1_757_000_000)
    private var providers: [any UsageProvider] { HarnessResolution.standardProviders() }

    private func build(
        present: Set<String>, stored: [Profile] = [], hidden: Set<String> = []
    ) -> HarnessRoster {
        HarnessRoster.build(
            providers: providers, present: present, stored: stored, hidden: hidden, now: now)
    }

    @Test("only present harnesses are metered, in the build's order")
    func presentOnly() {
        let roster = build(present: ["gemini", "claude"])
        #expect(roster.rows.map(\.id) == ["claude", "gemini"])
        #expect(roster.rows.allSatisfy { $0.present })
        #expect(roster.rows.allSatisfy { $0.shown })
        // One account each, the implicit default, synthesized.
        #expect(roster.profiles.map(\.key) == ["default", "gemini"])
        #expect(roster.rows.allSatisfy { $0.synthesizedDefault })
    }

    /// A Mac with nothing on disk still meters the bundled harness — a
    /// bar with no cell at all is a bug, not an empty state.
    @Test("with nothing found the bundled harness is metered anyway")
    func fallback() {
        let roster = build(present: [])
        #expect(roster.rows.map(\.id) == [HarnessResolution.bundledProviderID])
        #expect(roster.rows.first?.present == false)
        #expect(roster.rows.first?.shown == true)
    }

    @Test("a hidden harness is still metered; the last shown one cannot be hidden")
    func hiding() {
        // Both shown: either may be hidden.
        let open = build(present: ["claude", "codex"])
        #expect(open.canHide("claude"))
        #expect(open.canHide("codex"))

        let one = build(present: ["claude", "codex"], hidden: ["codex"])
        #expect(one.rows.map(\.id) == ["claude", "codex"])
        #expect(one.row("codex")?.shown == false)
        // Still metered: its accounts are in the roster.
        #expect(one.profiles.map(\.key) == ["default", "codex"])
        // Claude is the last one shown — hiding it would leave nothing.
        #expect(!one.canHide("claude"))

        // Every harness hidden in the stored set — the first is shown regardless.
        let all = build(present: ["claude", "codex"], hidden: ["claude", "codex"])
        #expect(all.row("claude")?.shown == true)
        #expect(all.row("codex")?.shown == false)
        #expect(!all.canHide("claude"))
    }

    @Test("a stored default record is not synthesized, and extra homes enrol their harness")
    func storedRecords() {
        let stored = [
            Profile(
                id: "default", providerID: "codex", home: nil, nickname: "Work",
                addedAt: now.addingTimeInterval(-86400)),
            Profile(
                id: "c982130e", providerID: "claude", home: URL(filePath: "/x/.claude-personal"),
                order: 2, addedAt: now.addingTimeInterval(-86400)),
        ]
        let roster = build(present: ["claude", "codex"], stored: stored)
        #expect(roster.row("codex")?.synthesizedDefault == false)
        #expect(roster.row("claude")?.synthesizedDefault == true)
        #expect(roster.profiles.map(\.key) == ["default", "c982130e", "codex"])
        #expect(roster.profile(key: "c982130e")?.home?.lastPathComponent == ".claude-personal")
        #expect(roster.profile(key: "codex")?.nickname == "Work")

        // An enrolled extra home counts as presence on its own: the person
        // pointed the agent at it, whatever the standard directory holds.
        let stats = HarnessPresence.probe(
            providers: providers, stored: stored, bundleID: "com.test.roster",
            roots: StorageScope.Roots(
                support: FileManager.default.temporaryDirectory.appending(path: "roster-support"),
                caches: FileManager.default.temporaryDirectory.appending(path: "roster-caches")))
        #expect(stats.contains("claude"))
    }

    @Test("the hidden set persists as plain strings a daemon can read")
    func hiddenDefaults() {
        let suite = "harness-roster-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(HarnessRoster.hidden(from: defaults).isEmpty)
        HarnessRoster.setHidden(["gemini", "codex"], in: defaults)
        #expect(defaults.stringArray(forKey: HarnessRoster.hiddenKey) == ["codex", "gemini"])
        #expect(HarnessRoster.hidden(from: defaults) == ["codex", "gemini"])
        HarnessRoster.setHidden([], in: defaults)
        #expect(defaults.object(forKey: HarnessRoster.hiddenKey) == nil)
    }
}

/// Focus across harnesses: days rank the harnesses, the account rule ranks
/// inside one, and a single harness behaves exactly as it always did.
@Suite("Harness focus")
struct HarnessFocusTests {
    private func account(
        _ id: String, files: Int = 0, last: Date? = nil, eligible: Bool = true,
        shown: Bool = true, order: Int = 0
    ) -> FocusCandidate {
        FocusCandidate(
            id: id, order: order, recentActivity: files, lastActivity: last, eligible: eligible,
            shown: shown)
    }

    private func harness(
        _ id: String, days: Int, last: Date? = nil, shown: Bool = true, accounts: [FocusCandidate]
    ) -> HarnessFocusCandidate {
        HarnessFocusCandidate(
            id: id, shown: shown, activeDays: days, lastActivity: last, accounts: accounts)
    }

    @Test("the harness used on more days wins, then its own busiest account")
    func daysDecide() {
        let claude = harness(
            "claude", days: 9,
            accounts: [account("default", files: 40), account("c982130e", files: 90)])
        let codex = harness("codex", days: 3, accounts: [account("codex", files: 400)])
        #expect(HarnessFocusRule.focused([claude, codex], pin: nil, current: nil) == "c982130e")

        // Codex overtakes on days even though it writes far fewer files —
        // volume doesn't compare across vendors, presence over days does.
        let busyCodex = harness("codex", days: 12, accounts: [account("codex", files: 400)])
        #expect(HarnessFocusRule.focused([claude, busyCodex], pin: nil, current: nil) == "codex")
    }

    @Test("a tie keeps the harness that already holds focus, then the newest write")
    func tiesAreSticky() {
        let older = Date(timeIntervalSince1970: 1_757_000_000)
        let newer = older.addingTimeInterval(3600)
        let claude = harness("claude", days: 7, last: older, accounts: [account("default", last: older)])
        let codex = harness("codex", days: 7, last: newer, accounts: [account("codex", last: newer)])
        // Nobody holds it yet: the newest write breaks the tie.
        #expect(HarnessFocusRule.focused([claude, codex], pin: nil, current: nil) == "codex")
        // The bar is already on Claude: a tie must not swap it out.
        #expect(HarnessFocusRule.focused([claude, codex], pin: nil, current: "default") == "default")
    }

    @Test("a hidden harness holds no focus; a pin wins while it is eligible")
    func hiddenAndPinned() {
        let claude = harness("claude", days: 2, accounts: [account("default", files: 1)])
        let codex = harness("codex", days: 14, shown: false, accounts: [account("codex", files: 99)])
        #expect(HarnessFocusRule.focused([claude, codex], pin: nil, current: nil) == "default")
        // Pinned to the hidden harness: not eligible, so focus stays put.
        #expect(HarnessFocusRule.focused([claude, codex], pin: "codex", current: nil) == "default")
        let shownCodex = harness("codex", days: 14, accounts: [account("codex", files: 99)])
        #expect(HarnessFocusRule.focused([claude, shownCodex], pin: "default", current: nil) == "default")
        // Dormant everywhere: nobody holds focus, and nothing is invented.
        let asleep = harness(
            "claude", days: 0, accounts: [account("default", eligible: false)])
        #expect(HarnessFocusRule.focused([asleep], pin: nil, current: nil) == nil)
    }

    /// One harness must reduce to the account rule exactly — that identity is
    /// what keeps a single-harness Mac's focus behaviour unchanged.
    @Test("one harness is the account rule, verbatim")
    func oneHarnessIsFocusRule() {
        let accounts = [
            account("default", files: 2, last: Date(timeIntervalSince1970: 100)),
            account("c982130e", files: 5, last: Date(timeIntervalSince1970: 200)),
            account("1a2b3c4d", files: 5, last: Date(timeIntervalSince1970: 300), eligible: false),
        ]
        let only = harness("claude", days: 4, accounts: accounts)
        for pin in [nil, "default", "1a2b3c4d", "nope"] {
            #expect(
                HarnessFocusRule.focused([only], pin: pin, current: nil)
                    == FocusRule.focused(accounts, pin: pin))
        }
    }
}
