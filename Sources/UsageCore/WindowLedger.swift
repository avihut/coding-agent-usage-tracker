import Foundation

/// What one limit window actually reached before it rolled over — the record
/// the audit views read to say "this week hit 87%" or "the limit was reached"
/// about windows the meters themselves have long forgotten.
public struct WindowOutcome: Codable, Sendable, Equatable, Identifiable {
    public let meterID: String
    /// The meter's display label at close time — also the key its percents
    /// use inside `UsageSample`.
    public let label: String
    /// The reset stamp that named the window while it ran — its end.
    public let end: Date
    /// `end − limitWindow` when the meter knew its window length.
    public let start: Date?
    /// The freshest percent observed before the roll — how full the window
    /// was when we last looked at it.
    public let lastPercent: Int?
    /// The highest percent any retained sample saw inside the window (never
    /// below `lastPercent`).
    public let peakPercent: Int?
    public let recordedAt: Date

    public var id: String { "\(meterID)|\(Int(end.timeIntervalSince1970))" }

    /// The window is KNOWN to have hit its limit. False means "not observed
    /// hitting it" — polling can miss a brief 100, and honesty beats a guess.
    public var reachedLimit: Bool {
        (peakPercent ?? 0) >= 100 || (lastPercent ?? 0) >= 100
    }

    public init(
        meterID: String, label: String, end: Date, start: Date?,
        lastPercent: Int?, peakPercent: Int?, recordedAt: Date
    ) {
        self.meterID = meterID
        self.label = label
        self.end = end
        self.start = start
        self.lastPercent = lastPercent
        self.peakPercent = peakPercent
        self.recordedAt = recordedAt
    }
}

/// Detects closed limit windows between consecutive snapshots and keeps the
/// outcome ledger. Detection is observational: a window closes when its
/// meter's reset stamp rolls FORWARD between two readings. Windows that come
/// and go entirely while the app is off are unknowable and stay unrecorded —
/// the ledger never guesses. Outcomes are tiny and kept indefinitely (a
/// session meter closes ~5/day; a weekly, once).
public struct WindowLedger: Sendable {
    public let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appending(path: "window-ledger.json")
    }

    public func load() -> [WindowOutcome] {
        guard let data = try? Data(contentsOf: fileURL),
              let outcomes = try? JSONDecoder().decode([WindowOutcome].self, from: data)
        else { return [] }
        return outcomes
    }

    /// Pure detection between two consecutive meter readings. `samples`
    /// supplies the in-window peak (percents keyed by meter LABEL, the
    /// sample vocabulary; meters are matched across readings by id). The
    /// old stamp must not sit meaningfully in the future — a "close" for a
    /// window that hasn't ended yet would be stamp weirdness, not history.
    public static func closedWindows(
        previous: [Meter], current: [Meter], samples: [UsageSample], now: Date
    ) -> [WindowOutcome] {
        let currentByID = Dictionary(
            current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var outcomes: [WindowOutcome] = []
        for old in previous {
            guard let oldReset = old.resetsAt,
                  oldReset <= now.addingTimeInterval(300),
                  let new = currentByID[old.id],
                  let newReset = new.resetsAt,
                  newReset > oldReset
            else { continue }
            let start = old.limitWindow.map { oldReset.addingTimeInterval(-$0) }
            let peak = samples
                .filter { sample in
                    sample.t <= oldReset && (start.map { sample.t >= $0 } ?? true)
                }
                .compactMap { $0.percents[old.label] }
                .max()
            outcomes.append(WindowOutcome(
                meterID: old.id, label: old.label, end: oldReset, start: start,
                lastPercent: old.percent,
                peakPercent: peak.map { max($0, old.percent ?? 0) } ?? old.percent,
                recordedAt: now))
        }
        return outcomes
    }

    /// Appends new outcomes (id-deduped — the same close observed twice
    /// records once), saves best-effort like UsageHistory, and returns the
    /// updated ledger sorted by window end.
    public func record(
        _ outcomes: [WindowOutcome], existing: [WindowOutcome]
    ) -> [WindowOutcome] {
        guard !outcomes.isEmpty else { return existing }
        var ledger = existing
        let known = Set(existing.map { $0.id })
        for outcome in outcomes where !known.contains(outcome.id) {
            ledger.append(outcome)
        }
        ledger.sort { $0.end < $1.end }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(ledger)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // The ledger is an enhancement; never let it break a refresh.
        }
        return ledger
    }
}
