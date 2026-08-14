import Foundation

/// One sampled reading: when, and each meter's percent keyed by meter label.
public struct UsageSample: Codable, Sendable, Equatable {
    public let t: Date
    public let percents: [String: Int]
    /// Each meter's reported window end at sample time — the exact cliff
    /// moment for reset-aware drawing. Absent in samples from older builds.
    public let resets: [String: Date]?

    public init(t: Date, percents: [String: Int], resets: [String: Date]? = nil) {
        self.t = t
        self.percents = percents
        self.resets = resets
    }
}

/// Persists sampled usage percentages so burn rates and the hover graph
/// survive restarts. Stores percentages only — no tokens, no account data.
public struct UsageHistory: Sendable {
    let fileURL: URL
    let retention: TimeInterval

    public init(directory: URL, retention: TimeInterval = 7 * 86400) {
        self.fileURL = directory.appending(path: "history.json")
        self.retention = retention
    }

    public static func standard(bundleID: String) -> UsageHistory {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return UsageHistory(directory: base.appending(path: bundleID))
    }

    public func load() -> [UsageSample] {
        guard let data = try? Data(contentsOf: fileURL),
              let samples = try? JSONDecoder().decode([UsageSample].self, from: data)
        else { return [] }
        return samples
    }

    /// Appends a sample from the snapshot, prunes old entries, saves, and
    /// returns the updated series. Best-effort persistence, like UsageCache.
    public func append(_ snapshot: Snapshot, existing: [UsageSample], now: Date = Date()) -> [UsageSample] {
        var percents: [String: Int] = [:]
        var resets: [String: Date] = [:]
        for meter in snapshot.meters {
            if let percent = meter.percent { percents[meter.label] = percent }
            if let reset = meter.resetsAt { resets[meter.label] = reset }
        }
        var samples = existing
        samples.append(UsageSample(
            t: now, percents: percents, resets: resets.isEmpty ? nil : resets))
        samples.removeAll { now.timeIntervalSince($0.t) > retention }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(samples)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // History is an enhancement; never let persistence break a refresh.
        }
        return samples
    }
}

// Burn-rate math lives in PredictionEngine.swift — the consolidated engine
// every prediction surface reads.
