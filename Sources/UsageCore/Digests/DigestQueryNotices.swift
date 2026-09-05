import Foundation

/// The `notices` noun (v0.93.0): what is pending — vendor resets, outages
/// past and present — for scripts and status bars. Follows `health`'s shape:
/// a table, a `--check` with its own exit code, fields, and `--json` for the
/// whole card. Dismissal is a socket verb (`notices dismiss <id>|--all`),
/// handled by the CLI target — this layer never talks to an engine.
///
/// Absent-card discipline: an engine that publishes no card (a daemon before
/// 0.93.0) prints nothing and exits 0, and `--check` stays quiet — no card is
/// not "nothing pending", but it is not news either.
extension DigestQuery {
    /// `notices --check` exits with this while anything is pending. Next free
    /// code after 22 (health's incident), and part of the CLI's API.
    static let exitPending: Int32 = 23

    static func runNotices(
        parsed: ParsedArgs, digest: LiveState, json: Bool, raw: Bool
    ) -> QueryOutput {
        let card = digest.notices

        if parsed.flags["check"] != nil {
            let pending = (card?.pendingCount ?? 0) > 0
            return QueryOutput(stdout: "", exitCode: pending ? exitPending : exitOK)
        }

        func resolve(_ field: String, asJSON: Bool) -> QueryOutput {
            noticesField(field, card: card, json: asJSON, raw: raw)
        }
        if let output = multiFieldOutput(
            noun: "notices", parsed: parsed, positionalField: parsed.positionals.first,
            json: json, header: parsed.flags["header"] != nil, resolve: resolve)
        {
            return output
        }

        guard let field = parsed.positionals.first else {
            guard parsed.positionals.isEmpty else { return badQuery("too many arguments") }
            guard let card else { return ok(json ? "null" : "") }
            if json { return ok(DigestQueryFormat.jsonValue(card)) }
            return ok(itemsTable(card, raw: raw))
        }
        guard parsed.positionals.count == 1 else { return badQuery("too many arguments") }
        return resolve(field, asJSON: json)
    }

    static let noticeColumns = ["kind", "when", "title", "state", "id"]

    /// One row per pending notice, the digest's own words. `when` is the
    /// pre-phrased line in the human register and the ISO instant in `--raw`,
    /// where a machine wants something it can parse.
    private static func noticeRow(_ item: NoticeCard, raw: Bool) -> [String] {
        [
            item.kind,
            raw ? DigestQueryFormat.iso(item.occurredAt) : item.when,
            item.title,
            item.ongoing ? "ongoing" : "pending",
            item.id,
        ]
    }

    private static func itemsTable(_ card: NoticesCard, raw: Bool) -> String {
        let rows = card.items.map { noticeRow($0, raw: raw) }
        guard !rows.isEmpty else { return "" }
        return raw
            ? DigestQueryFormat.tsv(rows, header: noticeColumns)
            : DigestQueryFormat.table([noticeColumns] + rows)
    }

    private static func noticesField(
        _ field: String, card: NoticesCard?, json: Bool, raw: Bool
    ) -> QueryOutput {
        switch field {
        case "count": return DigestQueryFormat.intField(card?.pendingCount, json: json)
        case "indicator": return DigestQueryFormat.boolField(card?.indicator, json: json)
        case "items":
            guard let card else { return ok(json ? "null" : "") }
            if json { return ok(DigestQueryFormat.jsonValue(card.items)) }
            return ok(itemsTable(card, raw: raw))
        default: return unknownField(noun: "notices", field: field)
        }
    }
}
