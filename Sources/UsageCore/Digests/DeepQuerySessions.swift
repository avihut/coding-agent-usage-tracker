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
        scan.sessions.map { entry($0, pricing: pricing) }
    }

    /// One session priced — the pass `index` runs per scanned session, and
    /// the whole of what `transcript <path>` does once it has a summary.
    static func entry(_ summary: SessionSummary, pricing: PricingTable) -> Entry {
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

    /// Resolves the provider, scans the selected profile's `projects` tree
    /// fresh (`persistCache: false` — spec §10: the lease holder, app or
    /// usaged, is the sole cache writer; a bare CLI run must never race or
    /// clobber it), and prices every session against the same disk-cached
    /// pricing table the legacy dump used. `home` nil = the standard home;
    /// the read-only cache is the profile's own directory, so root and
    /// cache always agree. Nil when the resolved provider isn't "claude" —
    /// the transcript format this scanner reads is Claude-only; callers
    /// translate that into exit 11, `DeepQuery.exitWrongProvider`.
    static func buildIndex(providerFlag: String?, home: URL? = nil, profileID: String, now: Date) -> [Entry]? {
        let providerID = DeepQuery.resolveProviderID(flag: providerFlag)
        guard providerID == "claude" else { return nil }
        let root = (home.map { ClaudeHome(directory: $0) } ?? .standard).projectsDirectory
        let scan = TranscriptScanner(
            root: root, cacheDirectory: DeepQuery.profileDirectory(providerID: providerID, profileID: profileID)
        ).scan(now: now, persistCache: false)
        return index(scan: scan, pricing: pricingTable(support: providerDirectory(providerID: providerID)))
    }

    /// `transcript <path>`'s data layer: ONE transcript (plus the subagent
    /// parts beside it) parsed fresh and priced against the same disk-cached
    /// table the scan uses. The daemon indexes exactly one `projects` tree,
    /// so a session Claude Code wrote under another config dir has no
    /// shortlist row and no scan to fall back to — this is the door that
    /// prices it anyway, with the app's own parser and the app's own rates
    /// (spec §10: a read of the one local file named on the command line
    /// and its `<id>/subagents/**` siblings; no cache is read or written).
    /// Nil when the path holds no transcript with a call or a prompt. The
    /// scanner's `root` is the file's own projects tree, which
    /// `sessionSummary(at:)` never consults — it's named for honesty.
    static func transcriptEntry(at url: URL, providerID: String) -> Entry? {
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        guard let summary = TranscriptScanner(
            root: root,
            cacheDirectory: DeepQuery.profileDirectory(
                providerID: providerID, profileID: StorageScope.defaultProfileID)
        ).sessionSummary(at: url)
        else { return nil }
        return entry(summary, pricing: pricingTable(support: providerDirectory(providerID: providerID)))
    }

    /// pricing.json's home: vendor-level, shared by every profile.
    private static func providerDirectory(providerID: String) -> URL {
        StorageScope.providerDirectory(bundleID: "com.avihu.ClaudeUsage", providerID: providerID)
    }

    /// The same disk-cached LiteLLM table the legacy dump used, bundled
    /// floor underneath — `current()` never blocks on the network.
    private static func pricingTable(support: URL) -> PricingTable {
        let provider = ClaudeProvider()
        return PricingService(
            cacheDirectory: support, fallback: provider.bundledRates, selector: provider.pricingSelector
        ).current()
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
            end: entry.summary.end,
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
    /// The nouns that route here rather than through `DigestQuery.run`:
    /// the two shortlist nouns that can fall through to a scan, and
    /// `transcript`, which only ever parses. `transcript` is NOT in
    /// `DigestQuery.nouns` — a digest can't answer it — so the CLI's
    /// noun gate checks this set alongside the other two.
    public static let nouns: Set<String> = ["sessions", "session", "transcript"]

    /// `environment`, `profiles`, `homes`: the account selector's inputs
    /// (`DigestQuery.selectProfile`) — `sessions`/`session` answer for one
    /// profile's shortlist and scan its HOME; `transcript` names its own
    /// file and never selects. nil `profiles`/`homes` read the app's store
    /// and the provider's facts; tests inject both.
    public static func run(
        noun: String, arguments: [String], digest: LiveState?, now: Date,
        environment: [String: String] = [:], profiles: [Profile]? = nil,
        homes: ProfileSelector.Homes? = nil
    ) -> QueryOutput {
        let parsed = DigestQuery.parseArgs(arguments)
        if let error = parsed.error { return DigestQuery.badQuery(error) }
        if let rejection = DigestQuery.rejectInapplicableFlags(noun: noun, parsed: parsed) {
            return rejection
        }

        let providerID = DeepQuery.resolveProviderID(flag: parsed.flags["provider"])
        let stored = profiles ?? DeepQuery.storedProfiles(providerID: providerID, now: now)
        let view: DigestQuery.ProfileView
        switch DigestQuery.selectProfile(
            noun: noun, parsed: parsed, environment: environment, digest: digest,
            profiles: stored, homes: homes ?? DeepQuery.storedHomes(providerID: providerID))
        {
        case .failure(let output): return output
        case .success(let selected): view = selected
        }
        let digest = view.digest ?? digest

        // The scan roots at the profile's home. A profile the writer names
        // but the store holds no home for cannot be scanned honestly —
        // rooting at the standard home would list the OTHER account's
        // sessions — so any query that could scan refuses up front.
        let home = stored.first { $0.id == view.id }?.home
        let mayScan = parsed.flags["all"] != nil || (noun == "session" && parsed.flags["no-scan"] == nil)
        if noun != "transcript", view.id != Profile.defaultID, home == nil, mayScan {
            return DigestQuery.noMatch(
                "account \(view.id) has no home on record — the transcript scan can't be rooted; "
                    + "answer from the shortlist with --no-scan")
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
        let isAllScan = (noun == "sessions" && parsed.flags["all"] != nil) || noun == "transcript"
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
        let scan = {
            DeepQuerySessions.buildIndex(
                providerFlag: parsed.flags["provider"], home: home, profileID: view.id, now: now)
        }
        switch noun {
        case "sessions":
            return DigestQuery.runSessionsList(
                parsed: parsed, digest: digest, now: now, calendar: calendar, json: json,
                raw: parsed.flags["raw"] != nil, scan: scan)
        case "session":
            return DigestQuery.runSession(
                parsed: parsed, digest: digest, now: now, calendar: calendar, json: json, scan: scan)
        case "transcript":
            // Exit 11 ahead of the verb body, like every other Claude-only
            // path: the format this parser reads is Claude Code's.
            guard providerID == "claude" else {
                return QueryOutput(
                    stdout: "", note: "transcript reads Claude Code transcripts only; provider is '\(providerID)'",
                    exitCode: DeepQuery.exitWrongProvider)
            }
            return DigestQuery.runTranscript(parsed: parsed, json: json) {
                DeepQuerySessions.transcriptEntry(at: $0, providerID: providerID)
            }
        default:
            return DigestQuery.badQuery("unknown noun '\(noun)'")
        }
    }
}
