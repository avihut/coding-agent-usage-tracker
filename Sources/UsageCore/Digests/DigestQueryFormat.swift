import Foundation

/// `DigestQuery`'s presentation layer: turning a resolved digest value into
/// the three output registers (human / raw / json), plus the raw-JSON path
/// walker `get` rides. Split from `DigestQuery` along the house rule (a file
/// over ~600 lines splits along a whole-type seam) — that file decides WHICH
/// value a query points at, this one decides how it prints.
///
/// A field access is ALWAYS raw-shaped unless `--json` is given (registers
/// table: "raw ... auto when a field path resolves to a scalar"). Human
/// formatting only happens for a noun's own summary/list line, built
/// directly by `DigestQuery` from these same primitives plus existing
/// captions — never from a named field.
enum DigestQueryFormat {

    // MARK: - Field output
    // One constructor per field "kind" — the raw/json branch a named field
    // always resolves through. Optional-in throughout: a caller passes a
    // non-optional value where the language auto-wraps it.

    static func textField(_ value: String?, json: Bool) -> QueryOutput {
        QueryOutput(stdout: json ? jsonValue(value) : (value ?? ""), exitCode: 0)
    }

    static func intField(_ value: Int?, json: Bool) -> QueryOutput {
        QueryOutput(stdout: json ? jsonValue(value) : rawInt(value), exitCode: 0)
    }

    /// Rates, pace factor, severity — a plain number with no pinned unit.
    static func numberField(_ value: Double?, json: Bool) -> QueryOutput {
        QueryOutput(stdout: json ? jsonValue(value) : rawNumber(value), exitCode: 0)
    }

    static func boolField(_ value: Bool?, json: Bool) -> QueryOutput {
        QueryOutput(stdout: json ? jsonValue(value) : (value.map(rawBool) ?? ""), exitCode: 0)
    }

    /// Raw = bare integer seconds (may be negative — an exhaustion already
    /// past is honest data, not an error). `--relative` prints the house
    /// duration phrase instead, exactly as it makes `dateField` print a
    /// pre-phrased caption: money and tokens arrive pre-formatted, and a
    /// duration had been the one quantity every consumer was left to
    /// re-format (and drift) on its own. `--json` ignores it — a seconds
    /// field stays a number, so scripts can rely on the shape.
    static func secondsField(_ value: TimeInterval?, json: Bool, relative: Bool) -> QueryOutput {
        let seconds = value.map { Int($0) }
        guard !json, relative else {
            return QueryOutput(stdout: json ? jsonValue(seconds) : rawInt(seconds), exitCode: 0)
        }
        guard let seconds else { return QueryOutput(stdout: "", exitCode: 0) }
        // `UsageFormatting.duration` phrases magnitudes only (it floors at
        // "1 min"), so a negative — a reset already past — carries its sign
        // here rather than reading as its own opposite.
        let text = UsageFormatting.duration(TimeInterval(abs(seconds)))
        return QueryOutput(stdout: seconds < 0 ? "-\(text)" : text, exitCode: 0)
    }

    static func hexField(_ value: RGBColor?, json: Bool) -> QueryOutput {
        QueryOutput(stdout: json ? jsonValue(value?.hexString) : (value?.hexString ?? ""), exitCode: 0)
    }

    /// `--relative`, present, and a paired caption exists (resets-at ↔
    /// resetCaption, forecast.exhausts-at ↔ forecast.caption): print that
    /// caption verbatim rather than inventing a duration phrase — the
    /// pre-phrased-caption rule applies to fields too, not just summary
    /// lines. `--json` ignores `--relative`: a date field must stay a date,
    /// never a caption string, so scripts can rely on the shape.
    static func dateField(
        _ value: Date?, json: Bool, unix: Bool, relative: Bool, caption: String? = nil
    ) -> QueryOutput {
        if !json, relative, let caption {
            return QueryOutput(stdout: caption, exitCode: 0)
        }
        if json {
            let text = value.map { unix ? jsonValue(Int($0.timeIntervalSince1970)) : jsonValue($0) } ?? "null"
            return QueryOutput(stdout: text, exitCode: 0)
        }
        guard let value else { return QueryOutput(stdout: "", exitCode: 0) }
        return QueryOutput(stdout: unix ? String(Int(value.timeIntervalSince1970)) : iso(value), exitCode: 0)
    }

    // MARK: - Raw scalars
    // The same shapes a named field auto-selects — reused directly by list
    // row-building so a TSV column and a lone field access never disagree.

    static func rawInt(_ value: Int?) -> String { value.map(String.init) ?? "" }

    /// NSNumber's shortest round-trip text — the SAME function `get`'s
    /// raw-JSON walk lands on for a number too (`canonicalNumberText`,
    /// below), so a typed field and its raw-JSON twin always agree byte for
    /// byte. NOT `NSNumber(value:).stringValue` — verified NOT
    /// shortest-round-trip (0.069 comes back "0.06900000000000001",
    /// 5.4485981308411215 loses its last digit) even though it happens to
    /// suppress ".0" on whole numbers; `JSONEncoder`'s Double encoding is
    /// the one formatter here confirmed to do BOTH correctly.
    static func rawNumber(_ value: Double?) -> String {
        value.map { jsonValue($0) } ?? ""
    }

    /// Unrounded decimal dollars (spec: raw money never rounds, never K/M).
    static func rawMoney(_ value: Double?) -> String { rawNumber(value) }

    static func rawBool(_ value: Bool) -> String { value ? "true" : "false" }

    // MARK: - Human scalars
    // Reached only from a noun's own summary/list builder — never from a
    // named field (which auto-raws, above).

    static func humanPercent(_ value: Int?) -> String { value.map { "\($0)%" } ?? "—" }
    static func humanMoney(_ value: Double?) -> String { value.map(UsageFormatting.money) ?? "—" }

    // MARK: - JSON
    // One generic encoder for every typed field AND every sub-tree (a list
    // of Codable rows) — matches LiveState's own wire settings, so
    // `--json` output is never a bespoke shape.

    static func jsonValue<T: Encodable>(_ value: T) -> String {
        (try? LiveState.encoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    // MARK: - Dates
    // The exact shape LiveState.encoder() writes ("2026-08-16T14:00:00Z") —
    // one formatter, so a raw ISO string and a JSON-encoded date print
    // identically apart from the surrounding quotes.

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - Lists

    /// No trailing newline — `DigestQuery` never bakes one in, so a caller
    /// (test or CLI) controls line termination once, in one place.
    static func tsv(_ rows: [[String]], header: [String]?) -> String {
        var lines: [String] = []
        if let header { lines.append(header.map(sanitizeCell).joined(separator: "\t")) }
        lines.append(contentsOf: rows.map { $0.map(sanitizeCell).joined(separator: "\t") })
        return lines.joined(separator: "\n")
    }

    /// A cell can NEVER contain the separator. `--raw` is the register
    /// machines read positionally, and its cells carry free text nothing
    /// upstream sanitizes for this purpose: `SessionMeta.scrub` collapses
    /// whitespace in a title (so titles are safe only by luck), while
    /// `project` and `branch` never pass through it at all — and a macOS
    /// directory name may legally contain a tab. One such character used to
    /// shift every later column, silently. Control characters collapse to a
    /// space each, 1:1 so a cell keeps its length; JSON is untouched, having
    /// its own escaping.
    static func sanitizeCell(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isControl) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars { scalars.append(isControl(scalar) ? " " : scalar) }
        return String(scalars)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    /// Space-padded columns, " · " between them (house style) — the human
    /// register's list shape. The last column is never padded, so a long
    /// trailing field (a title, a caption) never grows trailing whitespace.
    /// Trailing empty cells are dropped per row first — an absent trailing
    /// caption must vanish, not leave a dangling " · " pointing at nothing.
    static func table(_ rows: [[String]]) -> String {
        let trimmed = rows.map { row -> [String] in
            var row = row.map(sanitizeCell)
            while row.last == "" { row.removeLast() }
            return row
        }
        guard let columnCount = trimmed.map(\.count).max(), columnCount > 0 else { return "" }
        var widths = [Int](repeating: 0, count: columnCount)
        for row in trimmed {
            for (index, cell) in row.enumerated() {
                widths[index] = max(widths[index], cell.count)
            }
        }
        return trimmed.map { row in
            row.enumerated().map { index, cell -> String in
                index == row.count - 1
                    ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: " · ")
        }.joined(separator: "\n")
    }

    // MARK: - `prompt` coloring

    static func tint(_ color: RGBColor, _ text: String, tmux: Bool) -> String {
        tmux ? tmuxColor(color, text) : ansiColor(color, text)
    }

    static func ansiColor(_ color: RGBColor, _ text: String) -> String {
        let (r, g, b) = bytes(color)
        return "\u{1B}[38;2;\(r);\(g);\(b)m\(text)\u{1B}[0m"
    }

    static func tmuxColor(_ color: RGBColor, _ text: String) -> String {
        "#[fg=\(color.hexString)]\(text)#[default]"
    }

    static func staleMarker(colorOn: Bool, tmux: Bool) -> String {
        guard colorOn else { return " stale" }
        return tmux ? " #[dim]stale#[default]" : " \u{1B}[2mstale\u{1B}[0m"
    }

    private static func bytes(_ color: RGBColor) -> (Int, Int, Int) {
        func byte(_ component: Double) -> Int { Int((min(1, max(0, component)) * 255).rounded()) }
        return (byte(color.red), byte(color.green), byte(color.blue))
    }

    // MARK: - `get`: raw-JSON path walking
    // `rawDigest` bytes only, via JSONSerialization — never the typed
    // structs, so a digest field added tomorrow resolves today (house
    // rule). A missing key or bad index is ABSENT, not an error: `get`'s
    // whole point is forward compatibility, so a typo and an
    // not-yet-shipped field must degrade the same way.

    enum PathStep {
        case key(String)
        /// The one sugar (design §16): "meters[<sel>]" resolves through the
        /// SAME selector `limit` uses, so its failures stay real errors
        /// (19 ambiguous / 20 no match) rather than silently absent.
        case meterSelector(String)
    }

    static func splitPath(_ path: String) -> [PathStep] {
        path.split(separator: ".", omittingEmptySubsequences: false).map { segment in
            if segment.hasPrefix("meters["), segment.hasSuffix("]") {
                let inner = segment.dropFirst("meters[".count).dropLast()
                return .meterSelector(String(inner))
            }
            return .key(String(segment))
        }
    }

    /// One path step: an object key, or a non-negative array index. `nil`
    /// for anything else — including indexing into a scalar, which is a
    /// structurally invalid path, not worth a distinct error class here.
    static func walkOne(_ node: Any, key: String) -> Any? {
        if let dict = node as? [String: Any] { return dict[key] }
        if let array = node as? [Any] {
            guard let index = Int(key), array.indices.contains(index) else { return nil }
            return array[index]
        }
        return nil
    }

    /// Foundation's JSONSerialization distinguishes JSON `true`/`false`
    /// from numbers only by CFTypeID — NSNumber's `as? Bool` cast is NOT
    /// reliable (it succeeds for any nonzero number too, a classic bridging
    /// trap), so booleans must be told apart this way.
    static func isJSONBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// `NSNumber.stringValue` is NOT reliably shortest-round-trip (verified:
    /// 0.069 comes back "0.06900000000000001"; 5.4485981308411215 loses its
    /// last digit) even though it correctly drops ".0" from whole numbers.
    /// Routing every raw-JSON number through `.doubleValue` and
    /// `jsonValue(_:)` (JSONEncoder, confirmed to do BOTH correctly) is what
    /// makes a `get`'d number match `rawNumber`'s typed-field twin exactly.
    static func canonicalNumberText(_ number: NSNumber) -> String {
        isJSONBool(number) ? (number.boolValue ? "true" : "false") : jsonValue(number.doubleValue)
    }

    /// `nil` for a scalar that doesn't exist (JSONSerialization's `NSNull`
    /// included — get's absence is one thing, not two) as well as for an
    /// object/array, which the caller re-serializes as JSON instead.
    static func scalarText(_ value: Any) -> String? {
        if value is NSNull { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return canonicalNumberText(number) }
        return nil
    }

    /// `get`'s bare-scalar `--json` rendering — the value is `Any` from
    /// JSONSerialization, not a typed Encodable, so it can't ride
    /// `jsonValue(_:)` directly. JSON numbers/booleans are already unquoted
    /// text (identical to the raw register for a number — only strings
    /// need escaping/quoting).
    static func jsonEncodeRawScalar(_ value: Any) -> String {
        if let string = value as? String { return jsonValue(string) }
        if let number = value as? NSNumber { return canonicalNumberText(number) }
        return "null"
    }

    static func compactJSON(_ value: Any) -> String { serialize(value, pretty: false, level: 0) }
    static func prettyJSON(_ value: Any) -> String { serialize(value, pretty: true, level: 0) }

    /// A hand-rolled walker, not `JSONSerialization.data(withJSONObject:)`:
    /// that writer's OWN double formatting is not shortest-round-trip (it
    /// re-serializes a JSONSerialization-decoded 0.6118 as
    /// "0.61180000000000001" — verified) even though `canonicalNumberText`
    /// on the SAME NSNumber gives "0.6118". Numbers here route through that
    /// same helper, so a `get`'d object's numbers print exactly as a
    /// `get`'d scalar leaf inside it would.
    private static func serialize(_ value: Any, pretty: Bool, level: Int) -> String {
        let colon = pretty ? " : " : ":"
        let newline = pretty ? "\n" : ""
        func pad(_ depth: Int) -> String { pretty ? String(repeating: "  ", count: depth) : "" }

        if let dict = value as? [String: Any] {
            guard !dict.isEmpty else { return "{}" }
            let entries = dict.keys.sorted().map { key in
                pad(level + 1) + jsonValue(key) + colon + serialize(dict[key]!, pretty: pretty, level: level + 1)
            }
            return "{" + newline + entries.joined(separator: "," + newline) + newline + pad(level) + "}"
        }
        if let array = value as? [Any] {
            guard !array.isEmpty else { return "[]" }
            let entries = array.map { pad(level + 1) + serialize($0, pretty: pretty, level: level + 1) }
            return "[" + newline + entries.joined(separator: "," + newline) + newline + pad(level) + "]"
        }
        if value is NSNull { return "null" }
        if let string = value as? String { return jsonValue(string) }
        if let number = value as? NSNumber { return canonicalNumberText(number) }
        return "null"
    }
}

/// `prompt`/`get` sit here rather than in DigestQueryNouns.swift: both are
/// thin orchestrators directly over this file's OWN primitives (tint/
/// staleMarker for prompt; splitPath/walkOne/scalarText/compactJSON/
/// prettyJSON for get) — the whole-type seam that kept the plain digest-field
/// nouns' file under the house rule's ~600 lines.
extension DigestQuery {
    // MARK: - prompt

    /// Renders `menuBar[]` — the SAME resolved segments `usage-tui --status`
    /// draws (tui/src/status.rs) — as a shell-prompt line: glyph, then
    /// "TAG value" pairs space-separated ("S 34%" style, both in ANSI and
    /// `--tmux` mode; only the color MARKUP swaps, never the layout, so the
    /// two faces read as the same sentence). A segment is tinted ONLY when
    /// its `risk` RGBColor is present — no invented warning/critical
    /// fallback palette; that math belongs to RiskRamp, not a second copy
    /// here.
    static func runPrompt(parsed: ParsedArgs, digest: LiveState, environment: [String: String]) -> QueryOutput {
        guard parsed.positionals.isEmpty else { return badQuery("prompt takes no positional arguments") }
        let json = parsed.flags["json"] != nil
        let tmux = parsed.flags["tmux"] != nil
        let noGlyph = parsed.flags["no-glyph"] != nil
        let colorOn = parsed.flags["no-color"] == nil && parsed.flags["raw"] == nil
            && environment["NO_COLOR"] == nil

        var segments = digest.menuBar
        if !parsed.segments.isEmpty {
            let byTag = Dictionary(grouping: digest.menuBar) { $0.tag.lowercased() }
            var matched: [SegmentStatus] = []
            for tag in parsed.segments {
                guard let segment = byTag[tag.lowercased()]?.first else {
                    return noMatch("no menu bar segment tagged '\(tag)'")
                }
                matched.append(segment)
            }
            segments = matched
        }

        if json {
            struct PromptJSON: Encodable {
                let glyph: String?
                let segments: [SegmentStatus]
                let stale: Bool
            }
            let payload = PromptJSON(
                glyph: noGlyph ? nil : digest.engine.glyph, segments: segments, stale: digest.engine.stale)
            return ok(DigestQueryFormat.jsonValue(payload))
        }

        var out = ""
        if !noGlyph {
            let glyph = digest.engine.glyph
            out += colorOn ? DigestQueryFormat.tint(digest.engine.accent, glyph, tmux: tmux) : glyph
            if !segments.isEmpty { out += " " }
        }
        out += segments.map { segment -> String in
            let valueText = segment.percent.map { "\($0)%" } ?? "—"
            guard colorOn, let risk = segment.risk else { return "\(segment.tag) \(valueText)" }
            return "\(segment.tag) \(DigestQueryFormat.tint(risk, valueText, tmux: tmux))"
        }.joined(separator: " ")
        if digest.engine.stale {
            out += DigestQueryFormat.staleMarker(colorOn: colorOn, tmux: tmux)
        }
        return QueryOutput(stdout: out, exitCode: exitOK)
    }

    // MARK: - get

    /// The raw-JSON path walker: dotted wire-vocabulary keys, numeric array
    /// indices, and the `meters[<sel>]` sugar. Everything else in this file
    /// reads the TYPED `digest`; this is the one place that reads
    /// `rawDigest` instead — new digest fields must be reachable the day
    /// they ship, before any verb here learns their name.
    static func runGet(parsed: ParsedArgs, rawDigest: Data, digest: LiveState, json: Bool) -> QueryOutput {
        guard let path = parsed.positionals.first else {
            return badQuery("get needs a path — e.g. engine.planLabel")
        }
        guard parsed.positionals.count == 1 else { return badQuery("too many arguments") }
        guard let root = try? JSONSerialization.jsonObject(with: rawDigest, options: [.fragmentsAllowed]) else {
            return badQuery("digest bytes are not valid JSON")
        }

        var node: Any = root
        for step in DigestQueryFormat.splitPath(path) {
            switch step {
            case .key(let key):
                guard let next = DigestQueryFormat.walkOne(node, key: key) else {
                    return ok(json ? "null" : "")
                }
                node = next
            case .meterSelector(let token):
                switch selectMeter(token, in: digest.meters) {
                case .none:
                    return noMatch("no meter matches '\(token)'")
                case .ambiguous(let ids):
                    return badQuery("ambiguous selector '\(token)' matches: \(ids.joined(separator: ", "))")
                case .found(let meter):
                    guard let rawMeters = DigestQueryFormat.walkOne(root, key: "meters") as? [Any],
                          let index = digest.meters.firstIndex(where: { $0.id == meter.id }),
                          rawMeters.indices.contains(index)
                    else { return ok(json ? "null" : "") }
                    node = rawMeters[index]
                }
            }
        }

        if node is NSNull { return ok(json ? "null" : "") }
        if let scalar = DigestQueryFormat.scalarText(node) {
            return ok(json ? DigestQueryFormat.jsonEncodeRawScalar(node) : scalar)
        }
        return ok(json ? DigestQueryFormat.prettyJSON(node) : DigestQueryFormat.compactJSON(node))
    }
}
