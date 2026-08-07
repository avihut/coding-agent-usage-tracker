import Foundation

/// One sampled reading: when, and each meter's percent keyed by meter label.
public struct UsageSample: Codable, Sendable, Equatable {
    public let t: Date
    public let percents: [String: Int]

    public init(t: Date, percents: [String: Int]) {
        self.t = t
        self.percents = percents
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
        for meter in snapshot.meters {
            if let percent = meter.percent { percents[meter.label] = percent }
        }
        var samples = existing
        samples.append(UsageSample(t: now, percents: percents))
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

/// Burn verdict for one meter at the current consumption rate.
public struct BurnEstimate: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// On track — projected to stay under the limit until reset.
        case green
        /// Possibly exceeding — projected close to the limit at reset.
        case yellow
        /// Definitely exceeding — current rate exhausts the limit before reset.
        case red
    }

    public let verdict: Verdict
    public let text: String
}

public enum BurnRate {
    /// Projected-at-reset percentage above which the verdict turns yellow.
    public static let yellowProjectionThreshold = 85.0
    /// Minimum sample span before a rate is considered meaningful.
    public static let minimumSpan: TimeInterval = 300

    /// Sampling window per meter rank: sessions move fast, weeklies slowly.
    public static func window(forRank rank: Int) -> TimeInterval {
        rank == 0 ? 45 * 60 : 4 * 3600
    }

    /// Percent-per-hour from recent samples of one meter. Uses only the
    /// monotonic tail after the most recent drop, so a limit reset (percent
    /// falling back to ~0) never produces a bogus negative rate.
    public static func ratePerHour(
        samples: [UsageSample], label: String, window: TimeInterval, now: Date
    ) -> Double? {
        let points = samples
            .filter { now.timeIntervalSince($0.t) <= window }
            .compactMap { sample in sample.percents[label].map { (sample.t, $0) } }
            .sorted { $0.0 < $1.0 }
        guard points.count >= 2 else { return nil }

        var tail = points
        for index in points.indices.dropFirst().reversed() {
            if points[index].1 < points[index - 1].1 {
                tail = Array(points[index...])
                break
            }
        }
        guard let first = tail.first, let last = tail.last else { return nil }
        let span = last.0.timeIntervalSince(first.0)
        guard span >= minimumSpan else { return nil }
        return Double(last.1 - first.1) / (span / 3600)
    }

    /// Nil when there isn't enough data yet — the row simply shows nothing.
    public static func estimate(
        percent: Int, resetsAt: Date?, ratePerHour: Double?, now: Date
    ) -> BurnEstimate? {
        guard let rate = ratePerHour else { return nil }
        guard rate > 0.1 else {
            return BurnEstimate(verdict: .green, text: "steady — not burning")
        }

        let hoursToExhaust = Double(100 - percent) / rate
        guard let resetsAt else {
            return BurnEstimate(verdict: .green, text: "≈\(durationText(hours: hoursToExhaust)) to limit")
        }

        let hoursToReset = resetsAt.timeIntervalSince(now) / 3600
        let projectedAtReset = Double(percent) + rate * hoursToReset
        if projectedAtReset >= 100 {
            return BurnEstimate(
                verdict: .red,
                text: "≈\(durationText(hours: hoursToExhaust)) until limit")
        }
        if projectedAtReset >= yellowProjectionThreshold {
            return BurnEstimate(
                verdict: .yellow,
                text: "tight — proj. \(Int(projectedAtReset.rounded()))% at reset")
        }
        return BurnEstimate(
            verdict: .green,
            text: "on track — proj. \(Int(projectedAtReset.rounded()))% at reset")
    }

    static func durationText(hours: Double) -> String {
        let totalMinutes = max(1, Int((hours * 60).rounded()))
        let (h, m) = (totalMinutes / 60, totalMinutes % 60)
        if h == 0 { return "\(m)m" }
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }
}
