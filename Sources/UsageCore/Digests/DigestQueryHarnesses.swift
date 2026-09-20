import Foundation

/// The `harnesses` noun (0.101.0): every agent this Mac has, what each has
/// been doing lately, and whether it is displayed — the CLI face of the
/// Settings card, and the answer to "what is this thing metering".
///
/// Every DETECTED harness is listed, hidden ones included: hiding is a
/// display choice and a face that dropped them could not say so. A table by
/// default (`--raw` TSV, `--json` the digest's own `harnesses` list) plus
/// four scalars: `count` (every detected harness), `shown`, `focused` (the
/// harness the focused account belongs to) and `hidden`.
///
/// Absent-card discipline: a writer before 0.101.0 publishes no roster, so
/// the table prints nothing and every scalar goes absent — never a
/// confident "1", which would be this build's own assumption, not its word.
extension DigestQuery {
    static let harnessesColumns = ["id", "agent", "glyph", "accounts", "state", "activity", "health"]

    static func runHarnesses(
        parsed: ParsedArgs, digest: LiveState, now: Date, json: Bool, raw: Bool
    ) -> QueryOutput {
        func resolve(_ field: String, asJSON: Bool) -> QueryOutput {
            harnessesField(field, digest: digest, now: now, json: asJSON, raw: raw)
        }
        if let output = multiFieldOutput(
            noun: "harnesses", parsed: parsed, positionalField: parsed.positionals.first,
            json: json, header: parsed.flags["header"] != nil, resolve: resolve)
        {
            return output
        }
        guard let field = parsed.positionals.first else {
            guard parsed.positionals.isEmpty else { return badQuery("too many arguments") }
            guard let harnesses = digest.harnesses else { return ok(json ? "null" : "") }
            if json { return ok(DigestQueryFormat.jsonValue(harnesses)) }
            return ok(itemsTable(harnesses, now: now, raw: raw))
        }
        guard parsed.positionals.count == 1 else { return badQuery("too many arguments") }
        return resolve(field, asJSON: json)
    }

    private static func harnessesField(
        _ field: String, digest: LiveState, now: Date, json: Bool, raw: Bool
    ) -> QueryOutput {
        let harnesses = digest.harnesses
        switch field {
        case "count": return DigestQueryFormat.intField(harnesses?.count, json: json)
        case "shown":
            return DigestQueryFormat.intField(harnesses?.filter(\.shown).count, json: json)
        case "hidden":
            return DigestQueryFormat.intField(harnesses?.filter { !$0.shown }.count, json: json)
        case "focused":
            // The harness the focused ACCOUNT belongs to — focus is one
            // thing, and it lives on an account.
            let focused = digest.focusedProfile.flatMap { id in
                digest.profiles?.first { $0.id == id }?.providerID
            } ?? harnesses?.first?.id
            return DigestQueryFormat.textField(harnesses == nil ? nil : focused, json: json)
        case "items":
            guard let harnesses else { return ok(json ? "null" : "") }
            if json { return ok(DigestQueryFormat.jsonValue(harnesses)) }
            return ok(itemsTable(harnesses, now: now, raw: raw))
        default: return unknownField(noun: "harnesses", field: field)
        }
    }

    private static func itemsTable(_ harnesses: [HarnessState], now: Date, raw: Bool) -> String {
        let rows = harnesses.map { harnessRow($0, now: now, raw: raw) }
        guard !rows.isEmpty else { return "" }
        return raw
            ? DigestQueryFormat.tsv(rows, header: harnessesColumns)
            : DigestQueryFormat.table([harnessesColumns] + rows)
    }

    private static func harnessRow(_ harness: HarnessState, now: Date, raw: Bool) -> [String] {
        [
            harness.id,
            harness.agentName,
            harness.glyph,
            String(harness.accountCount),
            harnessState(harness, raw: raw),
            harnessActivity(harness, now: now, raw: raw),
            harnessHealth(harness),
        ]
    }

    /// Present and displayed, present and hidden, or not on this Mac at all.
    /// "hidden" is about the bar and the panel — never about metering.
    static func harnessState(_ harness: HarnessState, raw: Bool) -> String {
        if !harness.present { return "absent" }
        return harness.shown ? "shown" : "hidden"
    }

    /// "217 files · 7 days" in raw, "217 session files over 7 days" in the
    /// human register; a harness with none says when it was last used, and
    /// one nobody ever used says so plainly.
    static func harnessActivity(_ harness: HarnessState, now: Date, raw: Bool) -> String {
        if let files = harness.recentFiles, files > 0 {
            let days = harness.activeDays ?? 0
            return raw
                ? "\(files) files · \(days) days"
                : "\(files) session files over \(days) active day\(days == 1 ? "" : "s")"
        }
        guard let newest = harness.newestActivityAt else { return "" }
        // The caller's clock, never `Date()`: every DigestQuery answer is
        // pinned to the digest's own stamp, which is what makes the suite's
        // fixtures reproducible on any host.
        let age = UsageFormatting.duration(max(0, now.timeIntervalSince(newest)))
        return raw ? "quiet \(age)" : "quiet — last active \(age) ago"
    }

    /// Its own service's health, in the status card's own word. ABSENT IS
    /// NOT HEALTHY: a harness that publishes no feed says nothing.
    static func harnessHealth(_ harness: HarnessState) -> String {
        guard let card = harness.serviceStatus else { return "" }
        return card.indicator
    }
}
