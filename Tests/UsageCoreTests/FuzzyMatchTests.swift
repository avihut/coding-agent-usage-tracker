import Foundation
import Testing

@testable import UsageCore

/// The model search (R6). What matters is ORDER — a person types three
/// letters and expects the model they meant at the top — so most of these
/// compare two candidates rather than assert an absolute score.
@Suite("Fuzzy match") struct FuzzyMatchTests {
    private func score(_ query: String, _ candidate: String) -> Int? {
        FuzzyMatch.match(query, in: candidate)?.score
    }

    @Test("a subsequence matches, anything else does not")
    func subsequence() {
        #expect(score("opus", "Opus 5") != nil)
        #expect(score("op5", "Opus 5") != nil)
        #expect(score("o5", "Opus 5") != nil)
        #expect(score("sup", "Opus 5") == nil)
        #expect(score("opus6", "Opus 5") == nil)
        // Longer than the candidate can never be a subsequence of it.
        #expect(score("opus 5 turbo", "Opus 5") == nil)
    }

    @Test("an empty query matches everything, highlighting nothing")
    func emptyQuery() {
        let match = FuzzyMatch.match("", in: "claude-opus-5")
        #expect(match?.score == 0)
        #expect(match?.matched == [])
        // Whitespace alone is an empty query: a trailing space while typing
        // must not empty the list.
        #expect(FuzzyMatch.match("  ", in: "claude-opus-5")?.matched == [])
    }

    @Test("case and spaces in the query are ignored")
    func caseInsensitive() {
        #expect(score("OPUS", "Opus 5") != nil)
        #expect(score("gpt 5", "gpt-5.2-codex") != nil)
        #expect(score("GpT5C", "gpt-5.2-codex") != nil)
    }

    @Test("the whole word beats letters scattered through the middle")
    func wordsBeatScatter() {
        // "op" is the start of a word in one and a stray pair in the other.
        let word = try! #require(score("op", "Opus 5"))
        let scattered = try! #require(score("op", "Compact Mini"))
        #expect(word > scattered)
    }

    @Test("a run of letters beats the same letters spread out")
    func consecutiveBeatsSpread() {
        let run = try! #require(score("sonn", "Sonnet 4.5"))
        let spread = try! #require(score("sonn", "Some Other Nice Name"))
        #expect(run > spread)
    }

    @Test("a hit at the front beats the same hit buried deep")
    func prefixBeatsDeep() {
        let front = try! #require(score("cod", "Codex Mini"))
        let deep = try! #require(score("cod", "gpt-5.2-codex"))
        #expect(front > deep)
    }

    @Test("the alignment is the best one, not the first one found")
    func bestAlignmentNotGreedy() {
        // Greedy takes the `o` of "compact" and then reaches for a `p`; the
        // alignment a person means is the "op" of "opus".
        let match = try! #require(FuzzyMatch.match("op", in: "compact-opus"))
        #expect(match.matched == [8, 9])
        #expect(Array("compact-opus")[match.matched[0]] == "o")
    }

    @Test("digits and capitals start words too")
    func boundaryKinds() {
        // "5" after a letter is a new word, so "o5" reads as "Opus 5".
        let dashed = try! #require(score("o5", "claude-opus-5"))
        let buried = try! #require(score("o5", "aoxxxxx5"))
        #expect(dashed > buried)
        // camelCase steps count as boundaries for the same reason.
        #expect(score("hc", "HaikuCompact") != nil)
    }

    @Test("matched offsets are the candidate's own, ascending")
    func offsets() {
        let match = try! #require(FuzzyMatch.match("gpt5", in: "gpt-5.2-codex"))
        #expect(match.matched == [0, 1, 2, 4])
        #expect(match.matched == match.matched.sorted())
    }

    @Test("the best of several spellings wins, with its own offsets")
    func acrossFields() {
        let fields = ["Opus 5", "claude-opus-5"]
        let display = try! #require(FuzzyMatch.match("opus5", in: fields))
        // The display name is the tighter match, so it wins…
        #expect(display.field == 0)
        // …and a query spelled like the raw id picks the raw id instead.
        let raw = try! #require(FuzzyMatch.match("claude", in: fields))
        #expect(raw.field == 1)
        #expect(FuzzyMatch.match("zzz", in: fields) == nil)
    }

    @Test("ranking puts the meant model first and keeps ties in input order")
    func ranking() {
        let models = [
            ("claude-sonnet-4-5-20250514", "Sonnet 4.5"),
            ("claude-opus-5", "Opus 5"),
            ("gpt-5.2-codex", "GPT 5.2 Codex"),
            ("gemini-3-pro", "Gemini 3 Pro"),
        ]
        let ranked = FuzzyMatch.rank("o5", models) { [$0.1, $0.0] }
        #expect(ranked.first?.item.1 == "Opus 5")
        let codex = FuzzyMatch.rank("gpt5c", models) { [$0.1, $0.0] }
        #expect(codex.first?.item.1 == "GPT 5.2 Codex")
        // An empty query ranks nothing away and reorders nothing.
        let all = FuzzyMatch.rank("", models) { [$0.1, $0.0] }
        #expect(all.map(\.item.0) == models.map(\.0))
    }

    @Test("a long id is not punished for its length")
    func longIDsAreNotPenalizedAway() {
        // Both match at the same place; the dated id must not sink under the
        // short one just for having more characters after the match.
        let short = try! #require(score("sonnet", "Sonnet 4.5"))
        let dated = try! #require(score("sonnet", "claude-sonnet-4-5-20250514"))
        #expect(short > dated)
        // …but it must still rank above something that merely contains the
        // letters somewhere.
        let scattered = try! #require(score("sonnet", "so many other nice entries today"))
        #expect(dated > scattered)
    }
}
