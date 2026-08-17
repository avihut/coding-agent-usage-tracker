import Foundation

/// The scan-backed session index — `sessions --all`'s data layer and the
/// shortlist-miss fallback for `session <id-prefix>`. This file owns exactly
/// two things: turning a fresh `TranscriptScanner.scan` into priced entries,
/// and the one PUBLIC door (`DeepQuerySessionsCLI`) the `usage-cli` target
/// calls when no digest exists at all. Everything else — the actual noun
/// grammar, the SessionCard row/field builders, the shortlist-first ordering
/// — stays in `DigestQueryNouns.swift`'s `sessions`/`session` handlers, which
/// call INTO this file rather than duplicating it (house rule: one
/// formatting path serving both sources).
enum DeepQuerySessions {
    /// One scanned session plus its priced cost(s), computed once per scan
    /// so the `--all` list, the singular deep-field lookup, and the `models`
    /// field all read the same pricing pass instead of re-pricing per call.
    struct Entry {
        let summary: SessionSummary
        /// Whole-session cost — nil only when NOTHING in it was priceable
        /// (absent, never $0; mirrors `SessionCard.cost`'s own contract).
        let cost: Double?
        /// Per-model dollar cost, priced models only — backs the `models`
        /// deep field without threading a `PricingTable` further downstream.
        let modelCosts: [String: Double]
    }

    /// Prices every scanned session. Pure — no filesystem, no UserDefaults —
    /// so tests feed it a real `TranscriptScanner.scan` over a temp-dir
    /// fixture directly, without going through `buildIndex`'s hardwired
    /// home directory.
    static func index(scan: TranscriptScan, pricing: PricingTable) -> [Entry] {
        scan.sessions.map { summary in
            var modelCosts: [String: Double] = [:]
            var total = 0.0
            for (model, tally) in summary.models {
                guard let rates = pricing.rates(for: model) else { continue }
                let dollars = rates.dollars(for: tally)
                modelCosts[model] = dollars
                total += dollars
            }
            return Entry(summary: summary, cost: modelCosts.isEmpty ? nil : total, modelCosts: modelCosts)
        }
    }

    /// Resolves the provider, scans `~/.claude/projects` fresh
    /// (`persistCache: false` — spec §10: the lease holder, app or usaged,
    /// is the sole cache writer; a bare CLI run must never race or clobber
    /// it), and prices every session against the same disk-cached pricing
    /// table the legacy dump used. Nil when the resolved provider isn't
    /// "claude" — the transcript format this scanner reads is Claude-only;
    /// callers translate that into exit 11, `DeepQuery.exitWrongProvider`.
    static func buildIndex(providerFlag: String?, now: Date) -> [Entry]? {
        let providerID = DeepQuery.resolveProviderID(flag: providerFlag)
        guard providerID == "claude" else { return nil }
        let bundleID = "com.avihu.ClaudeUsage"
        let support = StorageScope.supportDirectory(bundleID: bundleID, providerID: providerID)
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
        let scan = TranscriptScanner(root: root, cacheDirectory: support).scan(now: now, persistCache: false)

        let provider = ClaudeProvider()
        let pricing = PricingService(
            cacheDirectory: support, fallback: provider.bundledRates, selector: provider.pricingSelector
        ).current()

        return index(scan: scan, pricing: pricing)
    }

    /// `id` prefix only (case-insensitive) — the plan's own selector for the
    /// shortlist-miss fallback; `latest`/index sugar stays a shortlist-only
    /// affordance (the scan has no "top 8" notion to index into).
    static func select(_ token: String, in entries: [Entry]) -> DigestQuery.Selection<Entry> {
        let needle = token.lowercased()
        let candidates = entries.filter { $0.summary.id.lowercased().hasPrefix(needle) }
        switch candidates.count {
        case 0: return .none
        case 1: return .found(candidates[0])
        default: return .ambiguous(candidates.map { $0.summary.id })
        }
    }

    /// Converts a scanned entry into the exact `SessionCard` shape the
    /// digest shortlist already renders — the one conversion point that lets
    /// `sessionRawRow`/`sessionHumanRow`/`sessionColumns` serve both sources
    /// unforked. `project` is trimmed to a basename (never a path, matching
    /// `SessionCard`'s own contract); `modelColors` is honestly empty — the
    /// ledger that assigns them is app-side persisted state this read-only
    /// CLI path has no business touching (spec §10).
    static func card(_ entry: Entry) -> SessionCard {
        SessionCard(
            id: entry.summary.id,
            title: entry.summary.title,
            project: entry.summary.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent },
            branch: entry.summary.gitBranch,
            startedAt: entry.summary.start,
            activeSeconds: entry.summary.activeSeconds,
            cost: entry.cost,
            tokens: entry.summary.totalTokens,
            prompts: entry.summary.prompts,
            apiCalls: entry.summary.apiCalls,
            modelColors: [])
    }
}

/// The `usage-cli` entry point for the `sessions`/`session` nouns —
/// `UsageCLI` calls this INSTEAD OF `DigestQuery.run` for those two, since
/// only here (not in the pure `DigestQuery.run`, which never touches a
/// disk) can a shortlist miss / `--all` fall through to a real
/// `TranscriptScanner` pass. Mirrors `DigestQuery.run`'s own pre-dispatch
/// steps (arg parsing, `--max-age`, the digest's own calendar) exactly, so
/// behavior for a noun that DOES resolve from the shortlist is identical to
/// going through `DigestQuery.run` directly — the only new behavior is what
/// happens on a miss.
public enum DeepQuerySessionsCLI {
    public static func run(noun: String, arguments: [String], digest: LiveState?, now: Date) -> QueryOutput {
        let parsed = DigestQuery.parseArgs(arguments)
        if let error = parsed.error { return DigestQuery.badQuery(error) }
        if let rejection = DigestQuery.rejectInapplicableFlags(noun: noun, parsed: parsed) {
            return rejection
        }

        // Mirrors `DigestQuery.run`'s own `--max-age` gate (that function
        // is this file's entry point for every OTHER noun, and its check is
        // private to it). The GRAMMAR validates unconditionally — a
        // malformed duration is a bad query no matter which source ends up
        // answering. The staleness COMPARISON is scoped: meaningless with
        // no digest to read `generatedAt` off, and excluded outright for
        // `sessions --all`, whose answer comes entirely from a fresh
        // `TranscriptScanner.scan` below, never from
        // `digest.engine.generatedAt` — the scan IS live data, not a stale
        // cache (mirrors the M2 sibling: `DeepQuery.run` for
        // windows/history/prices has no stale gate at all). A
        // shortlist-backed `sessions` or `session` answer, by contrast, IS
        // digest-backed and must still gate.
        let isAllScan = noun == "sessions" && parsed.flags["all"] != nil
        if let maxAgeText = parsed.flags["max-age"] {
            guard let maxAge = DigestQuery.parseDuration(maxAgeText) else {
                return DigestQuery.badQuery("bad --max-age duration '\(maxAgeText)' — e.g. 90s, 5m, 2h, 7d")
            }
            if !isAllScan, let digest,
               now.timeIntervalSince(digest.engine.generatedAt) > maxAge {
                return QueryOutput(stdout: "", exitCode: DigestQuery.exitStale)
            }
        }

        // The digest's own `activity.timeZone` when one exists (identical
        // fallback chain to `DigestQuery`'s private `digestCalendar`); the
        // system's own only when there's no digest to source one from at
        // all — never silently UTC, and never disagreeing with what a
        // digest-backed call to the SAME noun would have used.
        var calendar = Calendar(identifier: .gregorian)
        if let digest {
            calendar.timeZone = TimeZone(identifier: digest.activity.timeZone) ?? TimeZone(identifier: "UTC")!
        } else {
            calendar.timeZone = .current
        }

        let json = parsed.flags["json"] != nil
        let scan = { DeepQuerySessions.buildIndex(providerFlag: parsed.flags["provider"], now: now) }
        switch noun {
        case "sessions":
            return DigestQuery.runSessionsList(
                parsed: parsed, digest: digest, now: now, calendar: calendar, json: json,
                raw: parsed.flags["raw"] != nil, scan: scan)
        case "session":
            return DigestQuery.runSession(
                parsed: parsed, digest: digest, now: now, calendar: calendar, json: json, scan: scan)
        default:
            return DigestQuery.badQuery("unknown noun '\(noun)'")
        }
    }
}
