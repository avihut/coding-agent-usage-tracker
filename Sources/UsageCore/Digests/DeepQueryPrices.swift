import Foundation

/// `prices`/`price` nouns — the priced model catalog. `digest` being
/// optional on `DeepQuery.run` exists for exactly this verb: it must answer
/// from the on-disk pricing cache (or the bundled `PricingTable.bundled`
/// floor when no cache exists yet) with no live-state digest and no daemon
/// running at all — a machine that has never launched the app or `usaged`
/// still gets a price list. Read-only (`PricingService.current()` never
/// fetches — spec §10's "no network anywhere in these verbs"), so `now` is
/// unused: pricing here is never re-fetched, only ever read off disk.
///
/// Unlike `windows`/`history`, "prices" and "price" share this ONE handler
/// (`DeepQuery.run`'s switch merges both cases) — the M2-wide verb
/// signature can't express which noun was typed, so it's threaded in as an
/// explicit `noun` param (the dispatcher's call site passes it) purely to
/// enforce the plural/singular arity `DigestQueryNouns.runModels`/
/// `.runModel` do: "prices" takes no selector, "price" requires one.
extension DeepQuery {
    static func pricesVerb(
        noun: String, parsed: DigestQuery.ParsedArgs, digest: LiveState?, providerID: String, now: Date
    ) -> QueryOutput {
        pricesVerb(
            noun: noun, parsed: parsed, providerID: providerID,
            cacheDirectory: defaultCacheDirectory(providerID: providerID))
    }

    /// The dispatcher-facing overload above resolves the real on-disk cache
    /// directory, which on a machine that has actually run the app is NOT a
    /// hermetic path for tests (it reads that machine's real pricing.json).
    /// This overload takes the directory directly so tests can point it at
    /// a synthetic temp dir instead — the one seam this verb needs that the
    /// M2-wide `(parsed:digest:providerID:now:)` contract has no room for,
    /// added alongside it rather than in place of it.
    static func pricesVerb(
        noun: String, parsed: DigestQuery.ParsedArgs, providerID: String, cacheDirectory: URL
    ) -> QueryOutput {
        var positionals = parsed.positionals
        let json = parsed.flags["json"] != nil
        let raw = parsed.flags["raw"] != nil
        let header = parsed.flags["header"] != nil

        // Arity validated BEFORE the cache read below: an arity error must
        // never touch disk, which is what makes it reachable hermetically
        // through `DeepQuery.run` (the dispatcher's own cache directory is
        // this machine's real one, not a test's synthetic dir).
        if noun == "prices" {
            guard positionals.isEmpty else {
                return DigestQuery.badQuery(
                    "prices takes no selector — did you mean 'price \(positionals[0])'?")
            }
        } else {
            guard !positionals.isEmpty else {
                return DigestQuery.badQuery("price needs a selector — a model id")
            }
            guard positionals.count <= 2 else { return DigestQuery.badQuery("too many arguments") }
        }

        // `providerID == "claude"` is already enforced by `DeepQuery.run`'s
        // guard before this ever runs — `.claude`/`.bundled` (PricingService's
        // own defaults) are the correct selector/floor unconditionally here.
        let table = PricingService(cacheDirectory: cacheDirectory, fallback: .bundled, selector: .claude).current()

        if noun == "prices" {
            return pricesListOutput(table, json: json, raw: raw, header: header)
        }

        let selectorToken = positionals.removeFirst()
        let field = positionals.first

        guard let match = resolveModel(selectorToken, in: table) else {
            return DigestQuery.noMatch(
                "no priced model matches '\(selectorToken)'\(candidateSuffix(selectorToken, in: table))")
        }

        func resolve(_ name: String, asJSON: Bool) -> QueryOutput {
            priceField(
                name, rates: match.rates, table: table, listed: match.listed, json: asJSON,
                unix: parsed.flags["unix"] != nil)
        }
        if let output = DigestQuery.multiFieldOutput(
            noun: "price", parsed: parsed, positionalField: field, json: json, header: header,
            resolve: resolve) {
            return output
        }
        guard let field else {
            if json {
                return DigestQuery.ok(DigestQueryFormat.jsonValue(
                    PriceJSON(id: match.id, rates: match.rates, table: table, listed: match.listed)))
            }
            if raw {
                return DigestQuery.ok(DigestQueryFormat.tsv(
                    [priceRawRow(id: match.id, rates: match.rates)], header: header ? priceColumns : nil))
            }
            return DigestQuery.ok(priceSummaryLine(id: match.id, rates: match.rates, table: table))
        }
        return resolve(field, asJSON: json)
    }

    /// Mirrors exactly how `UsageCLI`/`UsageEngine` build a `PricingService`
    /// for the Claude provider (`StorageScope.supportDirectory` under this
    /// app's bundle id — literal, matching every other call site in this
    /// codebase; there's no shared constant for it).
    private static func defaultCacheDirectory(providerID: String) -> URL {
        StorageScope.supportDirectory(bundleID: "com.avihu.ClaudeUsage", providerID: providerID)
    }

    // MARK: - prices (the whole catalog)

    private static let priceColumns = [
        "id", "input", "output", "cache-read", "cache-write", "cache-write-1h", "context",
    ]

    private static func pricesListOutput(_ table: PricingTable, json: Bool, raw: Bool, header: Bool) -> QueryOutput {
        // Defensive, not reachable through this verb's own entry point:
        // `PricingService.current()` already treats an empty-rates cache as
        // absent and falls back to `fallback` (never hands back `table`
        // with empty `rates`) — kept in case that contract ever loosens.
        guard !table.rates.isEmpty else {
            return DigestQuery.ok(json ? DigestQueryFormat.jsonValue([PriceJSON]()) : "")
        }
        let ids = table.rates.keys.sorted()
        if json {
            // Shaped exactly like the singular's own `--json` (the SAME
            // `PriceJSON` type) rather than the raw `PricingTable` verbatim:
            // dollars-per-MTok (not the on-disk per-token wire unit) and the
            // wire's own key names (`cacheWrite1h`, `contextTokens`,
            // `fetchedAt`) renamed to the vocabulary the header row / field
            // table / singular json all already use. This also fixes the
            // bundled floor's `fetchedAt`: `PriceJSON.init` nils it out on
            // `.bundled` instead of publishing the `.distantPast` sentinel
            // as if it were a real fetch time. `listed: true` throughout —
            // these ids came straight from `table.rates`'s own keys, never
            // date-stripped.
            let rows = ids.map { PriceJSON(id: $0, rates: table.rates[$0]!, table: table, listed: true) }
            return DigestQuery.ok(DigestQueryFormat.jsonValue(rows))
        }
        if raw {
            let rows = ids.map { priceRawRow(id: $0, rates: table.rates[$0]!) }
            return DigestQuery.ok(DigestQueryFormat.tsv(rows, header: header ? priceColumns : nil))
        }
        let rows = ids.map { id -> [String] in
            let rates = table.rates[id]!
            return [
                id, UsageFormatting.ratePerMTok(rates.input), UsageFormatting.ratePerMTok(rates.output),
                rates.cacheRead.map(UsageFormatting.ratePerMTok) ?? "—",
                rates.cacheWrite.map(UsageFormatting.ratePerMTok) ?? "—",
                rates.cacheWrite1h.map(UsageFormatting.ratePerMTok) ?? "—",
                rates.contextTokens.map(TokenFormat.compact) ?? "—",
            ]
        }
        return DigestQuery.ok(DigestQueryFormat.table(rows))
    }

    /// Rates are stored per-token; raw is dollars per MTok like human is
    /// (rate × 1e6) — the design's own vocabulary — never the raw
    /// per-token float, which nobody queries this for.
    private static func priceRawRow(id: String, rates: ModelRates) -> [String] {
        [
            id, DigestQueryFormat.rawNumber(mtok(rates.input)),
            DigestQueryFormat.rawNumber(mtok(rates.output)),
            DigestQueryFormat.rawNumber(rates.cacheRead.map(mtok)),
            DigestQueryFormat.rawNumber(rates.cacheWrite.map(mtok)),
            DigestQueryFormat.rawNumber(rates.cacheWrite1h.map(mtok)),
            DigestQueryFormat.rawInt(rates.contextTokens),
        ]
    }

    /// The one rate→dollars-per-MTok conversion every raw/json path routes
    /// through. `perToken * 1_000_000` alone is not exact for rates this
    /// verb actually ships — `1e-7 * 1e6 == 0.09999999999999999` and
    /// `2e-7 * 1e6 == 0.19999999999999998` on Darwin (both real bundled
    /// rates: claude-haiku-4-5/claude-sonnet-5 cache-read) — so raw/json
    /// would print that noise while the human register's
    /// `UsageFormatting.ratePerMTok` rounds the SAME fact to "$0.10"/"$0.20".
    /// Rounding to nanodollar precision (9 decimal places — far finer than
    /// any real price granularity) discards the binary-floating-point error
    /// without touching a legitimate digit a feed rate could carry.
    private static func mtok(_ perToken: Double) -> Double {
        (perToken * 1_000_000 * 1e9).rounded() / 1e9
    }

    // MARK: - price (one model)

    /// Exact id, then release-date-stripped — the SAME two-step
    /// `PricingTable.rates(for:)` already does, replicated here (rather than
    /// widening that core API's return shape) only because this verb also
    /// needs to know WHICH step matched: the resulting `listed` means "this
    /// id has its OWN table entry" — a distinct sense from
    /// `CostComponent.listed` elsewhere in this module ("this token class
    /// had a feed rate, vs. a standard fallback multiplier").
    private static func resolveModel(
        _ token: String, in table: PricingTable
    ) -> (id: String, rates: ModelRates, listed: Bool)? {
        if let exact = table.rates[token] { return (token, exact, true) }
        guard let stripped = table.rates(for: token) else { return nil }
        return (token, stripped, false)
    }

    private static func candidateSuffix(_ token: String, in table: PricingTable) -> String {
        let candidates = nearbyCandidates(token, in: table)
        guard !candidates.isEmpty else { return "" }
        return " — nearby: \(candidates.joined(separator: ", "))"
    }

    /// Substring match either direction first (catches a short query inside
    /// a longer id, and a longer query with a stray suffix); a
    /// shared-prefix ranking as the fallback so a typo'd tail
    /// ("claude-sonnet-5-wrong") still surfaces its family.
    private static func nearbyCandidates(_ token: String, in table: PricingTable, limit: Int = 5) -> [String] {
        let needle = token.lowercased()
        let ids = table.rates.keys.sorted()
        let substring = ids.filter { $0.lowercased().contains(needle) || needle.contains($0.lowercased()) }
        if !substring.isEmpty { return Array(substring.prefix(limit)) }
        return ids
            .map { ($0, sharedPrefixLength($0.lowercased(), needle)) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    private static func sharedPrefixLength(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }

    private static func priceSummaryLine(id: String, rates: ModelRates, table: PricingTable) -> String {
        var parts = [
            "\(id) · in \(UsageFormatting.ratePerMTok(rates.input))/MTok",
            "out \(UsageFormatting.ratePerMTok(rates.output))/MTok",
        ]
        if let context = rates.contextTokens { parts.append("ctx \(TokenFormat.compact(context))") }
        parts.append(table.source.rawValue)
        return parts.joined(separator: " · ")
    }

    /// `--json` on BOTH the singular (one value) and the plural (one row
    /// per model, via `pricesListOutput`) — unlike `--raw`'s bare TSV row,
    /// this needs its own shape (`ModelRates` alone carries no id, and
    /// dollars-per-MTok isn't its wire unit) rather than riding
    /// `ModelRates`'s own Codable conformance — that struct's JSON is
    /// per-token, in dollars, for the on-disk cache, not this verb's
    /// contract. One shape for both registers keeps `prices --json` and
    /// `price <id> --json` agreeing on units and key names for the same
    /// fact.
    private struct PriceJSON: Encodable {
        let id: String
        let input: Double
        let output: Double
        let cacheRead: Double?
        let cacheWrite: Double?
        let cacheWrite1h: Double?
        let context: Int?
        let source: PricingTable.Source
        let fetched: Date?
        let listed: Bool

        init(id: String, rates: ModelRates, table: PricingTable, listed: Bool) {
            self.id = id
            input = mtok(rates.input)
            output = mtok(rates.output)
            cacheRead = rates.cacheRead.map(mtok)
            cacheWrite = rates.cacheWrite.map(mtok)
            cacheWrite1h = rates.cacheWrite1h.map(mtok)
            context = rates.contextTokens
            source = table.source
            // The bundled floor's `fetchedAt` is a `.distantPast` sentinel,
            // not a real fetch time — absent discipline applies to it too.
            fetched = table.source == .bundled ? nil : table.fetchedAt
            self.listed = listed
        }
    }

    /// A field access is always raw-shaped unless `--json` (house rule,
    /// `DigestQueryFormat`'s own header comment) — `ratePerMTok`'s "$15"
    /// human string belongs to the list/summary lines above, never here.
    private static func priceField(
        _ field: String, rates: ModelRates, table: PricingTable, listed: Bool, json: Bool, unix: Bool
    ) -> QueryOutput {
        switch field {
        case "input": return DigestQueryFormat.numberField(mtok(rates.input), json: json)
        case "output": return DigestQueryFormat.numberField(mtok(rates.output), json: json)
        case "cache-read":
            return DigestQueryFormat.numberField(rates.cacheRead.map(mtok), json: json)
        case "cache-write":
            return DigestQueryFormat.numberField(rates.cacheWrite.map(mtok), json: json)
        case "cache-write-1h":
            return DigestQueryFormat.numberField(rates.cacheWrite1h.map(mtok), json: json)
        case "context": return DigestQueryFormat.intField(rates.contextTokens, json: json)
        case "source": return DigestQueryFormat.textField(table.source.rawValue, json: json)
        case "fetched":
            let fetched = table.source == .bundled ? nil : table.fetchedAt
            // relative: false like every singular date FIELD across the
            // surface (M1's `session started` sets the precedent) —
            // `dateField`'s relative branch is caption-paired and belongs
            // to summary lines, not bare field values.
            return DigestQueryFormat.dateField(fetched, json: json, unix: unix, relative: false)
        case "listed": return DigestQueryFormat.boolField(listed, json: json)
        default: return DigestQuery.unknownField(noun: "price", field: field)
        }
    }
}
