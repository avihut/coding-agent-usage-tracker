import Foundation

/// `windows <meter> [hit-rate] [--last n|dur] [--since dur|yyyy-MM-dd]` —
/// closed limit
/// windows for one meter, read straight from `window-ledger.json` (never
/// the live digest's own data, which only ever holds the CURRENT window).
/// `digest` stays optional per the shared `DeepQuery.run` contract: a
/// ledger with real rows but no running engine (nothing has published
/// live-state.json yet) must still answer.
extension DeepQuery {
    /// `directory` is a test seam ONLY — `nil` (every real call site) makes
    /// this resolve the provider's Application Support directory exactly as
    /// `UsageEngine` does at its own `WindowLedger` call site
    /// (`Bundle.main.bundleIdentifier ?? "com.avihu.ClaudeUsage"`, since a
    /// bare CLI process has no bundle identity of its own); a test passes a
    /// synthetic temp directory it created and owns, never the real support
    /// path. Default parameter keeps `DeepQuery.run`'s call site compiling
    /// unchanged.
    static func windowsVerb(
        parsed: DigestQuery.ParsedArgs, digest: LiveState?, providerID: String, now: Date,
        directory: URL? = nil
    ) -> QueryOutput {
        var positionals = parsed.positionals
        guard !positionals.isEmpty else {
            return DigestQuery.badQuery(
                "windows needs a meter selector — an id, tag, label, or 'worst'/'next' (with a digest)")
        }
        let selectorToken = positionals.removeFirst()
        guard positionals.count <= 1 else { return DigestQuery.badQuery("too many arguments") }
        let field = positionals.first
        if let field, field != "hit-rate" {
            return DigestQuery.badQuery("windows has no field '\(field)'")
        }

        let ledgerDirectory = directory ?? StorageScope.supportDirectory(
            bundleID: Bundle.main.bundleIdentifier ?? "com.avihu.ClaudeUsage", providerID: providerID)
        let outcomes = WindowLedger(directory: ledgerDirectory).load()

        let resolvedMeter: (meterID: String, label: String)
        switch resolveMeterForWindows(selectorToken, digest: digest, outcomes: outcomes) {
        case .failure(let output): return output
        case .success(let value): resolvedMeter = value
        }

        // Newest-first, like every M1 entity list (`digest.sessions`,
        // `selectSession`'s "latest" == `.first`) — `WindowLedger.record`
        // itself persists ascending by `end`, so this is a deliberate
        // reversal, not an accident of storage order. Newest-first is also
        // what makes `--last n` a plain `prefix(n)`.
        var windows = outcomes
            .filter { $0.meterID == resolvedMeter.meterID }
            .sorted { $0.end > $1.end }

        if let sinceText = parsed.flags["since"] {
            // Same grammar as history's `--since` and M1's own
            // (`resolveSince`): a duration OR a yyyy-MM-dd day key at
            // midnight in the digest's calendar — three sibling verbs,
            // one `--since`.
            guard let cutoff = resolveSinceCutoff(sinceText, now: now, digest: digest) else {
                return DigestQuery.badQuery(
                    "bad --since value '\(sinceText)' — a duration (5m/2h/7d) or yyyy-MM-dd")
            }
            windows = windows.filter { $0.end >= cutoff }
        }
        if let lastText = parsed.flags["last"] {
            guard let filter = parseLast(lastText) else {
                return DigestQuery.badQuery(
                    "bad --last value '\(lastText)' — an integer count (8) or a duration (7d)")
            }
            switch filter {
            case .count(let count):
                windows = Array(windows.prefix(count))
            case .duration(let duration):
                let cutoff = now.addingTimeInterval(-duration)
                windows = windows.filter { $0.end >= cutoff }
            }
        }

        let json = parsed.flags["json"] != nil

        if field != nil {
            return hitRateField(windows, json: json)
        }

        if json { return DigestQuery.ok(DigestQueryFormat.jsonValue(windows)) }
        guard !windows.isEmpty else { return DigestQuery.ok("") }
        // One timestamp shape for BOTH text registers, mirroring history's
        // list behavior: `--relative` wins over `--unix`, else ISO.
        // `--json` above already bypassed both (WindowOutcome encodes
        // through LiveState.encoder(), matching M1).
        let unix = parsed.flags["unix"] != nil
        let relative = parsed.flags["relative"] != nil
        func stamp(_ date: Date) -> String {
            if relative { return "\(UsageFormatting.duration(max(0, now.timeIntervalSince(date)))) ago" }
            return unix ? String(Int(date.timeIntervalSince1970)) : DigestQueryFormat.iso(date)
        }
        if parsed.flags["raw"] != nil {
            let rows = windows.map { windowRawRow($0, stamp: stamp) }
            let header = parsed.flags["header"] != nil ? windowColumns : nil
            return DigestQuery.ok(DigestQueryFormat.tsv(rows, header: header))
        }
        return DigestQuery.ok(DigestQueryFormat.table(windows.map { windowHumanRow($0, stamp: stamp) }))
    }

    /// Resolves the meter the same way `limit`'s selector does when a live
    /// digest is on hand (id/tag/label/scoped-model substring, worst/next),
    /// so one vocabulary covers both live and historical queries; a nil
    /// digest, or a miss there, degrades to EXACT meterID/label equality
    /// against the ledger's own rows — the only vocabulary a closed window
    /// still carries once the live meter that produced it is gone (and
    /// ambiguous only if the fallback needle still names more than one
    /// meter id).
    private static func resolveMeterForWindows(
        _ token: String, digest: LiveState?, outcomes: [WindowOutcome]
    ) -> DigestQuery.Outcome<(meterID: String, label: String)> {
        if let digest {
            switch DigestQuery.selectMeter(token, in: digest.meters) {
            case .found(let meter):
                return .success((meter.id, meter.label))
            case .ambiguous(let ids):
                return .failure(DigestQuery.badQuery(
                    "ambiguous selector '\(token)' matches: \(ids.joined(separator: ", "))"))
            case .none:
                break
            }
        }
        let needle = token.lowercased()
        if let exact = outcomes.first(where: { $0.meterID.lowercased() == needle }) {
            return .success((exact.meterID, exact.label))
        }
        let matchingIDs = Set(outcomes.filter { $0.label.lowercased() == needle }.map(\.meterID))
        switch matchingIDs.count {
        case 0:
            return .failure(DigestQuery.noMatch("no meter matches '\(token)'"))
        case 1:
            let id = matchingIDs.first!
            let label = outcomes.first { $0.meterID == id }!.label
            return .success((id, label))
        default:
            return .failure(DigestQuery.badQuery(
                "ambiguous selector '\(token)' matches: \(matchingIDs.sorted().joined(separator: ", "))"))
        }
    }

    /// The observed-100 share — `reachedLimit`, not a bare `peakPercent >=
    /// 100`: `WindowLedger.closedWindows` floors `peakPercent` at
    /// `lastPercent` for every row it writes, but a row missing `peakPercent`
    /// entirely (no retained sample) still counts as a hit when `lastPercent`
    /// itself reached 100 — `reachedLimit` is the ledger's own definition of
    /// "known to have hit its limit" and this field must not invent a
    /// second one. Absent (never 0) over zero selected windows, per the
    /// house "absent is not zero" rule.
    private static func hitRateField(_ windows: [WindowOutcome], json: Bool) -> QueryOutput {
        guard !windows.isEmpty else { return DigestQueryFormat.numberField(nil, json: json) }
        let hits = windows.filter(\.reachedLimit).count
        return DigestQueryFormat.numberField(Double(hits) / Double(windows.count), json: json)
    }

    private static let windowColumns = ["end", "start", "last", "peak", "hit"]

    private static func windowRawRow(_ outcome: WindowOutcome, stamp: (Date) -> String) -> [String] {
        [
            stamp(outcome.end),
            outcome.start.map(stamp) ?? "",
            DigestQueryFormat.rawInt(outcome.lastPercent),
            DigestQueryFormat.rawInt(outcome.peakPercent),
            DigestQueryFormat.rawBool(outcome.reachedLimit),
        ]
    }

    /// Same five columns as raw/json, same order — a reader lining the
    /// registers up must never have to guess which cell maps to which.
    private static func windowHumanRow(_ outcome: WindowOutcome, stamp: (Date) -> String) -> [String] {
        [
            stamp(outcome.end),
            // `start` is genuinely optional on a ledger row — the em-dash
            // is ABSENT, and only absent.
            outcome.start.map(stamp) ?? "—",
            DigestQueryFormat.humanPercent(outcome.lastPercent),
            DigestQueryFormat.humanPercent(outcome.peakPercent),
            // `reachedLimit` is a real Bool, never absent — a window that
            // stayed short of its limit reads "miss" (hit-rate's own
            // antonym), never the absent glyph.
            outcome.reachedLimit ? "hit" : "miss",
        ]
    }
}
