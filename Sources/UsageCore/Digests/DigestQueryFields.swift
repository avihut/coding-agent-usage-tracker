import Foundation

/// The field VOCABULARY — which names each noun answers to and what shape
/// each one comes back in. The switch statements in `DigestQueryNouns.swift`
/// and `DigestQuerySessions.swift` stay the resolvers; this table is what
/// they can be asked about WITHOUT resolving:
///
/// - an unknown field enumerates the legal ones instead of leaving a
///   consumer's author to guess (`session has no field 'bogusfield'` was
///   the first wall anybody writing against this surface hit), and
/// - `--fields a,b,c` validates its whole list up front, so a table-shaped
///   name is refused by NAME rather than by sniffing a resolved value for
///   newlines.
///
/// Keeping it a separate table means it can drift from a switch — so
/// `DigestQueryFieldsTests` walks every name here against a full fixture and
/// fails if one doesn't resolve. Drift in the other direction (a resolvable
/// field missing from the table) costs only its mention in an error line.
extension DigestQuery {
    /// `scalar` = one value, TSV-able. `table` = a list of rows (`limit …
    /// series`, `activity … days`), which prints as its own TSV/JSON block
    /// and therefore can't be a cell inside another row.
    enum FieldShape {
        case scalar
        case table
    }

    static let fieldCatalog: [String: [String: FieldShape]] = [
        "status": scalars([
            "provider", "service", "agent", "glyph", "plan", "plan.type", "plan.tier", "host", "pid", "version",
            "schema", "sessions-cap", "generated", "fetched", "age", "next-poll", "backoff", "gate-floor",
            "stale", "local", "pace", "pace.multiplier", "error", "error.code", "error.hint", "error.http",
            "accent", "system-accent", "forecast.ready", "forecast.remaining", "forecast.caption", "timezone",
        ]),
        "limit": scalars([
            "percent", "left", "label", "tag", "level", "rank", "severity", "risk", "resets-at", "resets-in",
            "caption", "window", "rate-window", "forces-warning", "scoped-model", "exhausted",
            "forecast.severity", "forecast.projected", "forecast.exhausts-at", "forecast.exhausts-in",
            "forecast.verdict", "forecast.raw-verdict", "forecast.rate", "forecast.baseline", "forecast.pace",
            "forecast.basis", "forecast.caption",
        ]).merging(tables(["series", "curve", "stretches", "models"])) { lhs, _ in lhs },
        "health": scalars([
            "indicator", "description", "page", "page-url", "ok", "stale", "checked", "age",
            "incident", "impact", "phase", "started", "duration", "message", "message-at",
            "incident-url",
        ]).merging(tables(["components", "incidents", "resolved", "maintenances"])) { lhs, _ in lhs },
        "budget": scalars(["used", "ceiling", "left", "fraction"]),
        "spend": scalars(["used", "limit", "left", "currency"]),
        "activity": scalars(["tokens", "prompts", "cost"])
            .merging(tables(["days", "hours", "models"])) { lhs, _ in lhs },
        "model": scalars([
            "name", "id", "color", "cost", "share", "tokens", "tokens.input", "tokens.output", "tokens.cache-read",
            "tokens.cache-write", "tokens.cache-write-1h", "tokens.uncached-input", "tokens.input-side",
            "tokens.cached-share",
        ]),
        "session": scalars([
            "id", "title", "project", "branch", "started", "end", "active", "cost", "tokens", "prompts",
            "api-calls", "source", "kind", "tool-calls", "subagents", "compactions", "agent-version",
        ]).merging(tables(["models"])) { lhs, _ in lhs },
        // M2 verbs answer field names too, and enumerate them the same way.
        "price": scalars([
            "input", "output", "cache-read", "cache-write", "cache-write-1h", "context", "source", "fetched",
            "listed",
        ]),
        "windows": scalars(["hit-rate"]),
    ]

    /// Which nouns actually WIRE `--fields`. Not simply every catalogued
    /// noun: `windows` has exactly one field, so the flag there would parse
    /// and then do nothing — and a flag that's accepted but inert is the
    /// defect class M2's verify barrier caught twice. It enumerates its
    /// field like everyone else; it just can't combine one.
    static let multiFieldNouns = Set(fieldCatalog.keys).subtracting(["windows"])

    private static func scalars(_ names: [String]) -> [String: FieldShape] {
        Dictionary(uniqueKeysWithValues: names.map { ($0, .scalar) })
    }

    private static func tables(_ names: [String]) -> [String: FieldShape] {
        Dictionary(uniqueKeysWithValues: names.map { ($0, .table) })
    }

    /// The one "no such field" answer, everywhere. Still exit 19 with the
    /// same leading sentence a caller may already be matching on — the list
    /// is appended, not substituted.
    static func unknownField(noun: String, field: String) -> QueryOutput {
        let known = (fieldCatalog[noun] ?? [:]).keys.sorted()
        guard !known.isEmpty else { return badQuery("\(noun) has no field '\(field)'") }
        return badQuery("\(noun) has no field '\(field)' — fields: \(known.joined(separator: ", "))")
    }

    /// `--fields tokens,cost,active,started` — one invocation, one row.
    /// Without it a consumer needing four numbers either forks four times or
    /// scrapes the human summary line, and scraping a presentation string is
    /// exactly what the raw register exists to prevent.
    ///
    /// Returns nil when `--fields` wasn't given, so a noun handler asks with
    /// a single `if let` before its own field/summary fork. Every value is
    /// the RAW register's (the same bytes the field alone would print), so
    /// this composes with `--unix`/`--relative` rather than reinventing them.
    ///
    /// `--json` yields an object in the REQUESTED order — the one place this
    /// surface departs from `LiveState.encoder()`'s sorted keys, because the
    /// column order a caller asked for is the answer's own shape here, the
    /// same as it is for the TSV row.
    static func multiFieldOutput(
        noun: String, parsed: ParsedArgs, positionalField: String?, json: Bool, header: Bool,
        resolve: (String, Bool) -> QueryOutput
    ) -> QueryOutput? {
        guard let list = parsed.flags["fields"] else { return nil }
        guard positionalField == nil else {
            return badQuery("'\(positionalField!)' and --fields both name fields — give one or the other")
        }
        let names = list.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !names.contains(where: \.isEmpty) else {
            return badQuery("--fields wants a comma-separated list — e.g. --fields tokens,cost")
        }
        let shapes = fieldCatalog[noun] ?? [:]
        for name in names {
            guard let shape = shapes[name] else { return unknownField(noun: noun, field: name) }
            guard shape == .scalar else {
                return badQuery("--fields can't carry '\(name)' — it's a table; query it on its own")
            }
        }

        var values: [String] = []
        for name in names {
            let output = resolve(name, json)
            // A field can still fail past its NAME being legal — a deep
            // session field on a shortlist hit, say. That failure is the
            // whole query's, verbatim: partial rows would be worse than none.
            guard output.exitCode == exitOK else { return output }
            values.append(output.stdout)
        }
        if json {
            let entries = zip(names, values).map { "  \(DigestQueryFormat.jsonValue($0)) : \($1)" }
            return ok("{\n" + entries.joined(separator: ",\n") + "\n}")
        }
        return ok(DigestQueryFormat.tsv([values], header: header ? names : nil))
    }
}
