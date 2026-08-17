import Foundation
import Testing
@testable import UsageCore

/// M2 registered its flags (`--all`, `--background`, `--no-background`,
/// `--last`) in the ONE shared parser — these tests pin that registration
/// did not WIDEN any shipped noun's grammar: `rejectInapplicableFlags`
/// keeps the pre-M2 answer, `unknown flag '--x'` at exit 19, for every
/// noun a flag isn't real for, at every entry point that parses.
@Suite("flag applicability")
struct DeepQueryFlagsTests {
    private func rejection(_ noun: String, _ args: [String]) -> QueryOutput? {
        DigestQuery.rejectInapplicableFlags(noun: noun, parsed: DigestQuery.parseArgs(args))
    }

    @Test("M1 nouns reject every M2 flag exactly like an unknown flag")
    func m1NounsRejectM2Flags() {
        for (noun, args, flag) in [
            ("status", ["--all"], "all"),
            ("limits", ["--last", "5d"], "last"),
            ("status", ["--background"], "background"),
            ("model", ["--no-background"], "no-background"),
        ] {
            let out = rejection(noun, args)
            #expect(out?.exitCode == 19)
            #expect(out?.note == "unknown flag '--\(flag)'")
        }
    }

    @Test("owner nouns keep their own flags")
    func ownersPass() {
        #expect(rejection("sessions", ["--all", "--background", "--no-background"]) == nil)
        #expect(rejection("session", ["x", "--all"]) == nil)
        #expect(rejection("windows", ["w", "--last", "8"]) == nil)
        #expect(rejection("history", ["w", "--last", "24h"]) == nil)
    }

    @Test("deep verbs reject foreign M2 flags through DeepQuery.run itself")
    func deepVerbsRejectForeignFlags() {
        for (noun, args, flag) in [
            ("windows", ["w", "--background"], "background"),
            ("history", ["w", "--all"], "all"),
            ("prices", ["--last", "5"], "last"),
        ] {
            // Rejection fires before the provider guard, so this stays
            // hermetic no matter what `activeProviderID` the host persisted.
            let out = DeepQuery.run(
                noun: noun, arguments: args, digest: nil, environment: [:], now: Date())
            #expect(out.exitCode == 19)
            #expect(out.note == "unknown flag '--\(flag)'")
        }
    }

    @Test("the sessions CLI door rejects --last (windows/history's flag)")
    func sessionsCLIRejectsLast() {
        let out = DeepQuerySessionsCLI.run(
            noun: "sessions", arguments: ["--last", "5"], digest: nil, now: Date())
        #expect(out.exitCode == 19)
        #expect(out.note == "unknown flag '--last'")
    }

    @Test("session (singular) rejects the plural-only background filters")
    func singularSessionRejectsBackgroundFlags() {
        let out = DeepQuerySessionsCLI.run(
            noun: "session", arguments: ["abcd", "--background"], digest: nil, now: Date())
        #expect(out.exitCode == 19)
        #expect(out.note == "unknown flag '--background'")
    }
}
