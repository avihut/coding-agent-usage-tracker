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

/// Persists sampled usage percentages so burn rates, the hover graph, and
/// the weekly rhythm profile survive restarts. Stores percentages only — no
/// tokens, no account data. The recent week keeps every poll; older samples
/// thin to one per 15 minutes, so two months of history stays a small file
/// while still feeding the hour-of-week profile.
public struct UsageHistory: Sendable {
    public let fileURL: URL
    let retention: TimeInterval
    let denseWindow: TimeInterval
    let thinnedResolution: TimeInterval

    public init(
        directory: URL, retention: TimeInterval = 56 * 86400,
        denseWindow: TimeInterval = 7 * 86400,
        thinnedResolution: TimeInterval = 900
    ) {
        self.fileURL = directory.appending(path: "history.json")
        self.retention = retention
        self.denseWindow = denseWindow
        self.thinnedResolution = thinnedResolution
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
        samples = Self.thinned(
            samples, olderThan: now.addingTimeInterval(-denseWindow),
            resolution: thinnedResolution)

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

    /// One sample per resolution bucket for everything older than the dense
    /// boundary; the first in each bucket wins, so re-thinning stays stable
    /// as samples age across the boundary. Output is chronological.
    static func thinned(
        _ samples: [UsageSample], olderThan boundary: Date, resolution: TimeInterval
    ) -> [UsageSample] {
        var kept: [UsageSample] = []
        kept.reserveCapacity(samples.count)
        var lastBucket = -Double.infinity
        for sample in samples.sorted(by: { $0.t < $1.t }) {
            if sample.t >= boundary {
                kept.append(sample)
            } else {
                let bucket = (sample.t.timeIntervalSinceReferenceDate / resolution)
                    .rounded(.down)
                if bucket != lastBucket {
                    kept.append(sample)
                    lastBucket = bucket
                }
            }
        }
        return kept
    }
}

// Burn-rate math lives in PredictionEngine.swift — the consolidated engine
// every prediction surface reads.
