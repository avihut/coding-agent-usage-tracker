import Foundation

/// The two ways a session breakdown chart can measure its series. Cost is the
/// priced running total; tokens count every call (unpriced models included).
public enum SessionChartMeasure: String, CaseIterable, Sendable, Equatable {
    case cost
    case tokens
}

/// Everything a running-breakdown chart needs, precomputed once per detail
/// load: cumulative series per row (carry-forward, so any row index answers
/// "what was the total here" in O(1)), per-model overlay series, the prompt
/// rows that anchor vertical markers, and the prompt-to-prompt sections with
/// their own cost/token subtotals.
public struct SessionChartModel: Sendable, Equatable {
    /// One model's cumulative curves, same row alignment as the totals.
    public struct ModelSeries: Sendable, Equatable, Identifiable {
        public let model: String
        /// Nil when the model has no rate — an unpriced model must draw no
        /// cost curve at all, never a flat $0 line (the ledger rule).
        public let cost: [Double]?
        public let tokens: [Double]
        /// The row of this model's first call. The arrays stay row-aligned
        /// (O(1) hover lookups) and hold zeros before it, but a chart draws
        /// the curve only from the row before — a model adopted mid-session
        /// must not appear as a flat zero line from the first row.
        public let firstRow: Int

        public var id: String { model }

        public init(model: String, cost: [Double]?, tokens: [Double], firstRow: Int = 0) {
            self.model = model
            self.cost = cost
            self.tokens = tokens
            self.firstRow = firstRow
        }

        /// Where the drawn curve starts: the row before the first call, so
        /// the line visibly rises from zero rather than materializing mid-air.
        public var drawStart: Int { max(0, firstRow - 1) }

        public func values(_ measure: SessionChartMeasure) -> [Double]? {
            measure == .cost ? cost : tokens
        }
    }

    /// The stretch of work one prompt set in motion: from its row up to (not
    /// including) the next prompt's row, with the spend inside it. Rows before
    /// the first prompt belong to no section.
    public struct Section: Sendable, Equatable {
        public let promptRow: Int
        /// Exclusive; the last section ends at the row count.
        public let endRow: Int
        /// Priced increments only — unpriced calls are absent, not $0.
        public let cost: Double
        public let tokens: Int

        public var range: Range<Int> { promptRow..<endRow }

        public init(promptRow: Int, endRow: Int, cost: Double, tokens: Int) {
            self.promptRow = promptRow
            self.endRow = endRow
            self.cost = cost
            self.tokens = tokens
        }

        public func value(_ measure: SessionChartMeasure) -> Double {
            measure == .cost ? cost : Double(tokens)
        }
    }

    /// Cumulative priced cost through each row — `ledger[i].running`, lifted
    /// so both measures read through one shape.
    public let runningCost: [Double]
    public let runningTokens: [Double]
    /// Heaviest model (by final tokens) first.
    public let models: [ModelSeries]
    public let promptRows: [Int]
    /// Where the context was compacted — marked on the chart in the meter
    /// chart's reset idiom (same semantic: a window reset), never as prompt
    /// lines.
    public let compactionRows: [Int]
    /// Each call's context footprint as a fraction of ITS model's window
    /// (inputSide / max_input_tokens), carried forward through non-call rows
    /// so any index answers "how full was the context here". Empty when no
    /// call's window is known — the overlay then has nothing honest to draw.
    public let contextFraction: [Double]
    public let sections: [Section]

    public init(
        runningCost: [Double], runningTokens: [Double], models: [ModelSeries],
        promptRows: [Int], compactionRows: [Int], contextFraction: [Double],
        sections: [Section]
    ) {
        self.runningCost = runningCost
        self.runningTokens = runningTokens
        self.models = models
        self.promptRows = promptRows
        self.compactionRows = compactionRows
        self.contextFraction = contextFraction
        self.sections = sections
    }

    public static let empty = SessionChartModel(
        runningCost: [], runningTokens: [], models: [], promptRows: [],
        compactionRows: [], contextFraction: [], sections: [])

    public func running(_ measure: SessionChartMeasure) -> [Double] {
        measure == .cost ? runningCost : runningTokens
    }

    public func section(containing row: Int) -> Section? {
        sections.first { $0.range.contains(row) }
    }

    /// Builds from the detail rows and their index-aligned ledger. A ledger of
    /// the wrong length (never produced by `SessionLedger`) yields `.empty`
    /// rather than misaligned curves. `windows` maps model ids to their
    /// context windows (the pricing feed's max_input_tokens) — models absent
    /// from it simply don't move the context curve.
    public static func build(
        rows: [SessionEvent], ledger: [SessionLedger.Entry], windows: [String: Int] = [:]
    ) -> SessionChartModel {
        guard rows.count == ledger.count, !rows.isEmpty else { return .empty }
        var runningCost: [Double] = []
        var runningTokens: [Double] = []
        runningCost.reserveCapacity(rows.count)
        runningTokens.reserveCapacity(rows.count)
        var tokens = 0
        var promptRows: [Int] = []
        var compactionRows: [Int] = []
        var contextFraction: [Double] = []
        contextFraction.reserveCapacity(rows.count)
        var contextNow = 0.0
        var contextKnown = false
        // A model is priced iff its call rows carry ledger increments; rates
        // are per-model constants, so one row answers for all of them.
        var priced: [String: Bool] = [:]
        var firstRow: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            if case .apiCall(let model, let tally, _) = row.kind {
                tokens += tally.total
                priced[model] = priced[model] ?? (ledger[index].incremental != nil)
                if firstRow[model] == nil { firstRow[model] = index }
                if let window = windows[model], window > 0 {
                    contextNow = Double(tally.inputSide) / Double(window)
                    contextKnown = true
                }
            }
            if case .prompt = row.kind { promptRows.append(index) }
            if case .compaction = row.kind { compactionRows.append(index) }
            runningCost.append(ledger[index].running)
            runningTokens.append(Double(tokens))
            contextFraction.append(contextNow)
        }
        var modelCost: [String: [Double]] = [:]
        var modelTokens: [String: [Double]] = [:]
        for model in priced.keys {
            modelCost[model] = []
            modelCost[model]?.reserveCapacity(rows.count)
            modelTokens[model] = []
            modelTokens[model]?.reserveCapacity(rows.count)
        }
        var costSoFar: [String: Double] = [:]
        var tokensSoFar: [String: Double] = [:]
        for (index, row) in rows.enumerated() {
            if case .apiCall(let model, let tally, _) = row.kind {
                costSoFar[model, default: 0] += ledger[index].incremental ?? 0
                tokensSoFar[model, default: 0] += Double(tally.total)
            }
            for model in priced.keys {
                modelCost[model]?.append(costSoFar[model] ?? 0)
                modelTokens[model]?.append(tokensSoFar[model] ?? 0)
            }
        }
        let models = priced.keys
            .map { model in
                ModelSeries(
                    model: model,
                    cost: priced[model] == true ? modelCost[model] : nil,
                    tokens: modelTokens[model] ?? [],
                    firstRow: firstRow[model] ?? 0)
            }
            .sorted { ($0.tokens.last ?? 0) > ($1.tokens.last ?? 0) }
        var sections: [Section] = []
        for (offset, promptRow) in promptRows.enumerated() {
            let endRow = offset + 1 < promptRows.count ? promptRows[offset + 1] : rows.count
            var cost = 0.0
            var sectionTokens = 0
            for index in promptRow..<endRow {
                if case .apiCall(_, let tally, _) = rows[index].kind {
                    cost += ledger[index].incremental ?? 0
                    sectionTokens += tally.total
                }
            }
            sections.append(Section(
                promptRow: promptRow, endRow: endRow, cost: cost, tokens: sectionTokens))
        }
        return SessionChartModel(
            runningCost: runningCost, runningTokens: runningTokens, models: models,
            promptRows: promptRows, compactionRows: compactionRows,
            contextFraction: contextKnown ? contextFraction : [], sections: sections)
    }
}
