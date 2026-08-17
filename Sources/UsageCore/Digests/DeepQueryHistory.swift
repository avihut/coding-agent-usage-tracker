import Foundation

/// `history` noun — one meter's raw sampled percent series from
/// `history.json` (the popover chart's own persistence, made queryable),
/// keyed by meter LABEL because that's how `UsageHistory`/`UsageSample`
/// key it (Prediction/UsageHistory.swift) — never a fixed slot index, so a
/// meter that changed rank or dropped out of the live digest still has a
/// stable key into its own past samples.
extension DeepQuery {
    /// `historyDirectory` is a trailing default so the shared dispatcher
    /// call site in DeepQuery.swift (also used by the windows/prices
    /// verbs, built by other agents in this same wave) needs no edit; a
    /// caller with no override gets the real provider support dir, wired
    /// exactly like `UsageEngine`'s own `UsageHistory(directory:)` call
    /// site. A test passes a synthetic temp directory here instead of
    /// relying on `Bundle.main.bundleIdentifier` (nil under `swift test`,
    /// so the fallback literal would otherwise point every hermetic test
    /// at the REAL user's `~/Library/Application Support` history file).
    static func historyVerb(
        parsed: DigestQuery.ParsedArgs, digest: LiveState?, providerID: String, now: Date,
        historyDirectory: URL? = nil
    ) -> QueryOutput {
        var positionals = parsed.positionals
        guard !positionals.isEmpty else {
            return DigestQuery.badQuery("history needs a meter selector — an id, tag, or label")
        }
        let selectorToken = positionals.removeFirst()
        guard positionals.isEmpty else { return DigestQuery.badQuery("too many arguments") }

        // A malformed --last/--since is a BAD QUERY (19) and must be
        // caught before the selector resolves — `history bogus --last 5x`
        // exits 19, not 20, matching `runSession`'s own order (its
        // `filterSessions` validates --since before `selectSession` runs).
        var cutoffs: [Date] = []
        var lastCount: Int?
        if let text = parsed.flags["last"] {
            guard let filter = parseLast(text) else {
                return DigestQuery.badQuery(
                    "bad --last value '\(text)' — an integer count (8) or a duration (7d)")
            }
            switch filter {
            case .count(let count): lastCount = count
            case .duration(let duration): cutoffs.append(now.addingTimeInterval(-duration))
            }
        }
        if let text = parsed.flags["since"] {
            // Same grammar as M1's own --since (`filterSessions`/
            // `resolveSince` in DigestQueryNouns.swift): a duration OR a
            // literal yyyy-MM-dd day key parsed at midnight in the
            // digest's own calendar — never UTC, since a digest published
            // west of Greenwich would otherwise cut the day off early.
            // `resolveSince`/`digestCalendar` are private to their files,
            // so this mirrors their logic rather than reaching across.
            guard let cutoff = resolveSinceCutoff(text, now: now, digest: digest) else {
                return DigestQuery.badQuery("bad --since value '\(text)' — a duration (5m/2h/7d) or yyyy-MM-dd")
            }
            cutoffs.append(cutoff)
        }

        let directory = historyDirectory ?? StorageScope.supportDirectory(
            bundleID: Bundle.main.bundleIdentifier ?? "com.avihu.ClaudeUsage", providerID: providerID)
        // `.sorted` makes synthetic test input well-defined; a no-op on a
        // real file, whose own `UsageHistory.thinned` already emits
        // chronological order.
        let samples = UsageHistory(directory: directory).load().sorted { $0.t < $1.t }

        let label: String
        switch resolveLabel(selectorToken, digest: digest, samples: samples) {
        case .none:
            return DigestQuery.noMatch("no meter matches '\(selectorToken)'")
        case .ambiguous(let labels):
            return DigestQuery.badQuery(
                "ambiguous selector '\(selectorToken)' matches: \(labels.joined(separator: ", "))")
        case .found(let resolved):
            label = resolved
        }

        var filtered = samples
        for cutoff in cutoffs { filtered = filtered.filter { $0.t >= cutoff } }

        // Absent is not zero: a sample that simply doesn't carry this
        // meter's label (a poll where it wasn't reported, or a sample from
        // before this meter existed) is SKIPPED entirely — never coerced
        // to a fabricated 0% row.
        var rows: [(t: Date, percent: Int)] = filtered.compactMap { sample in
            sample.percents[label].map { (sample.t, $0) }
        }
        if let lastCount {
            // Chronological series — "the last n samples" is the suffix.
            rows = Array(rows.suffix(lastCount))
        }

        let json = parsed.flags["json"] != nil
        if json {
            // `[]` for a resolved-but-empty series, matching `runLimits`/
            // `seriesOutput` — absent-is-not-zero governs a missing VALUE,
            // not an empty LIST.
            struct Point: Encodable { let t: Date; let percent: Int }
            return DigestQuery.ok(DigestQueryFormat.jsonValue(rows.map { Point(t: $0.t, percent: $0.percent) }))
        }
        guard !rows.isEmpty else { return DigestQuery.ok("") }

        let unix = parsed.flags["unix"] != nil
        let relative = parsed.flags["relative"] != nil
        let header = parsed.flags["header"] != nil

        // No M1 precedent covers a captionless `--relative` (`dateField`'s
        // relative branch requires a paired caption; every field here that
        // lacks one hardcodes `relative: false`) — a sample has none, so
        // this reuses the one M1 elapsed-time phrase that also has no
        // caption behind it (`runStatus`'s "fetched 2 min ago",
        // `UsageFormatting.duration`) rather than leave the plan's named
        // flag silently inert. `--relative` wins over `--unix`; `--json`
        // above already bypassed both.
        func timestampCell(_ t: Date) -> String {
            if relative { return "\(UsageFormatting.duration(max(0, now.timeIntervalSince(t)))) ago" }
            return unix ? String(Int(t.timeIntervalSince1970)) : DigestQueryFormat.iso(t)
        }

        // ALWAYS TSV, in both the --raw and human registers — matching the
        // M1 precedent for this exact shape (`seriesOutput`,
        // DigestQueryNouns.swift:210-218): a 56-day poll-resolution series
        // has no sensible "human table" (unbounded cardinality, unlike
        // `windows`'s bounded record rows), and the plan pins TSV outright.
        // `--header` therefore applies identically on both branches.
        let tsvRows = rows.map { [timestampCell($0.t), DigestQueryFormat.rawInt($0.percent)] }
        return DigestQuery.ok(DigestQueryFormat.tsv(tsvRows, header: header ? ["t", "percent"] : nil))
    }

    /// Mirrors `DigestQueryNouns.resolveSince`/`DigestQuery.digestCalendar`
    /// (both `private` to their own files): a duration OR a literal
    /// yyyy-MM-dd day key, parsed at midnight in the digest's own calendar
    /// when a digest is present, else UTC — the same fallback
    /// `digestCalendar` itself uses. Internal, not private: `windowsVerb`
    /// resolves its `--since` through this exact grammar too.
    static func resolveSinceCutoff(_ text: String, now: Date, digest: LiveState?) -> Date? {
        if let duration = DigestQuery.parseDuration(text) { return now.addingTimeInterval(-duration) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = digest.flatMap { TimeZone(identifier: $0.activity.timeZone) } ?? TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    /// Digest meter labels first, via the SAME id/tag/label-substring/
    /// worst/next vocabulary `limit` uses (`DigestQuery.selectMeter`) — an
    /// AMBIGUOUS digest match is a real conflict and fails immediately,
    /// never silently deferred to the fallback below. A digest MISS (or no
    /// digest at all — deep verbs tolerate a nil one) falls through to
    /// matching the token against the union of every sample's own label
    /// keys, the only vocabulary left once a meter has aged out of the
    /// live digest but still has recorded history. Consequence: `worst`/
    /// `next` only ever resolve with a digest present — without one
    /// they're just literal label text and (almost certainly) miss,
    /// exiting 20 like any other unresolved selector.
    private static func resolveLabel(
        _ token: String, digest: LiveState?, samples: [UsageSample]
    ) -> DigestQuery.Selection<String> {
        if let digest {
            switch DigestQuery.selectMeter(token, in: digest.meters) {
            case .found(let meter): return .found(meter.label)
            case .ambiguous(let ids): return .ambiguous(ids)
            case .none: break
            }
        }
        let needle = token.lowercased()
        let labels = Set(samples.flatMap { $0.percents.keys })
        if let exact = labels.first(where: { $0.lowercased() == needle }) { return .found(exact) }
        let candidates = labels.filter { $0.lowercased().contains(needle) }.sorted()
        switch candidates.count {
        case 0: return .none
        case 1: return .found(candidates[0])
        default: return .ambiguous(candidates)
        }
    }
}
