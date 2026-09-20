import Foundation

/// Subsequence matching with a score, for picking a model by typing part of
/// its name (v0.101.0, user-directed: "an option to fuzzy search a model by
/// name in the model selector"). Pure and tested; the app draws the result.
///
/// It scores rather than merely filters, because the interesting queries are
/// ambiguous: with every harness's models in one list, "o5" should put "Opus
/// 5" above "claude-sonnet-4-5-20250514", and "gpt5c" should find "GPT 5.2
/// Codex". So a match earns its position — letters that start a word, letters
/// that run together, and a match right at the front all count for more than
/// letters scattered through the middle.
///
/// The best alignment is found exactly, not greedily: a greedy walk matching
/// "op" against "claude-opus" takes the `o` of "claude" and then has to reach
/// far for the `p`, scoring worse than the "op" of "opus" that a person means.
/// Candidates are model ids and display names — tens of characters — so the
/// full search is a few hundred steps.
public enum FuzzyMatch {
    public struct Match: Equatable, Sendable {
        /// Higher is a better match. Only comparable WITHIN one query.
        public let score: Int
        /// Which characters of the candidate the query matched, ascending —
        /// what a face underlines or bolds.
        public let matched: [Int]

        public init(score: Int, matched: [Int]) {
            self.score = score
            self.matched = matched
        }
    }

    // The weights. Relative size is what matters: a word-boundary hit must
    // beat a middle-of-word hit, and an unbroken run must beat a scattered
    // one, by enough that no amount of scatter can overtake.
    private static let baseScore = 1
    private static let consecutiveBonus = 10
    private static let boundaryBonus = 9
    private static let prefixBonus = 14
    /// Per character skipped before the FIRST match — a hit deep inside the
    /// candidate is worth less than one at its front.
    private static let leadingPenalty = 1
    /// Per character skipped between two matches.
    private static let gapPenalty = 1
    /// Beyond this, skipping before the first match costs nothing more. It is
    /// CAPPED BELOW one word-boundary bonus on purpose: "o5" in
    /// "claude-opus-5" is two word starts behind a seven-character prefix,
    /// and an uncapped run-up would make it score no better than the same two
    /// letters landing mid-word in a short id.
    private static let maxLeadingPenalty = 6

    /// Nil when `query` is not a subsequence of `candidate`. An EMPTY query
    /// matches everything at score 0 with nothing highlighted, which is what
    /// lets a picker show its full grouped list before anyone types.
    public static func match(_ query: String, in candidate: String) -> Match? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return Match(score: 0, matched: []) }
        let hay = Array(candidate)
        let lowered = hay.map { Character($0.lowercased()) }
        guard needle.count <= hay.count else { return nil }

        let boundary = boundaries(of: hay)
        // best[i][j] = the best score for matching needle[i...] starting the
        // search at candidate[j], with `previousMatched` telling whether j-1
        // was itself a match (which is what a run is worth).
        var memo: [Int: Int] = [:]
        var choice: [Int: Int] = [:]

        func key(_ i: Int, _ j: Int, _ run: Bool) -> Int {
            ((i * (hay.count + 1)) + j) * 2 + (run ? 1 : 0)
        }

        func best(_ i: Int, _ j: Int, run: Bool) -> Int? {
            if i == needle.count { return 0 }
            if j == hay.count { return nil }
            let cacheKey = key(i, j, run)
            if let cached = memo[cacheKey] { return cached == Int.min ? nil : cached }
            var top: Int?
            var topAt = -1
            var skipped = 0
            var index = j
            while index < hay.count {
                defer {
                    index += 1
                    skipped += 1
                }
                guard lowered[index] == needle[i] else { continue }
                var here = baseScore
                if index == 0 { here += prefixBonus }
                if boundary.contains(index) { here += boundaryBonus }
                if run, skipped == 0 { here += consecutiveBonus }
                let penalty = i == 0
                    ? min(maxLeadingPenalty, skipped * leadingPenalty)
                    : skipped * gapPenalty
                guard let rest = best(i + 1, index + 1, run: true) else { continue }
                let total = here - penalty + rest
                if top == nil || total > top! {
                    top = total
                    topAt = index
                }
            }
            memo[cacheKey] = top ?? Int.min
            if top != nil { choice[cacheKey] = topAt }
            return top
        }

        guard let score = best(0, 0, run: false) else { return nil }
        // Walk the same decisions again to collect the offsets.
        var matched: [Int] = []
        var i = 0
        var j = 0
        var run = false
        while i < needle.count, let at = choice[key(i, j, run)] {
            matched.append(at)
            i += 1
            j = at + 1
            run = true
        }
        return Match(score: score, matched: matched)
    }

    /// The best of several spellings of one thing — a model's display name
    /// and its raw id. The winning field's own offsets come back, so a face
    /// highlights the field it is showing only when that field is the one
    /// that matched.
    public static func match(_ query: String, in fields: [String]) -> (field: Int, match: Match)? {
        var best: (field: Int, match: Match)?
        for (index, field) in fields.enumerated() {
            guard let candidate = match(query, in: field) else { continue }
            if best == nil || candidate.score > best!.match.score {
                best = (index, candidate)
            }
        }
        return best
    }

    /// Ranks candidates by their best field, best first. Ties keep the input
    /// order, so a caller's own ordering (a harness's tier ladder) survives a
    /// query that does not discriminate — and an EMPTY query changes nothing
    /// at all.
    public static func rank<T>(
        _ query: String, _ items: [T], fields: (T) -> [String]
    ) -> [(item: T, field: Int, match: Match)] {
        let scored = items.enumerated().compactMap { offset, item in
            match(query, in: fields(item)).map { (offset, item, $0.field, $0.match) }
        }
        return scored
            .sorted { a, b in
                a.3.score != b.3.score ? a.3.score > b.3.score : a.0 < b.0
            }
            .map { ($0.1, $0.2, $0.3) }
    }

    /// Where a new word starts: after a separator, and at a lower→upper step
    /// ("GPT 5.2 Codex" and "gpt-5.2-codex" both give the person the same
    /// letters to type).
    private static func boundaries(of characters: [Character]) -> Set<Int> {
        var result: Set<Int> = []
        for index in characters.indices {
            let character = characters[index]
            guard character.isLetter || character.isNumber else { continue }
            guard index > 0 else {
                result.insert(index)
                continue
            }
            let previous = characters[index - 1]
            if !previous.isLetter, !previous.isNumber {
                result.insert(index)
            } else if character.isUppercase, previous.isLowercase {
                result.insert(index)
            } else if character.isNumber, !previous.isNumber {
                result.insert(index)
            }
        }
        return result
    }
}
