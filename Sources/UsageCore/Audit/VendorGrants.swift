import Foundation

/// A vendor's mid-window reset (`ResetCliffs.Cliff.Kind.midWindow`) empties
/// the whole account at once, so it is ONE event however many meters it
/// showed on — and a meter that was already sitting at zero when it landed
/// shows nothing at all (2026-09-04: the 5h session window had closed at
/// its own boundary two hours before Anthropic's reset, so the day drill
/// drew no mark while the weekly charts did). Every chart therefore reads
/// the grant off EVERY meter's samples: what any one of them saw, all of
/// them mark.
public enum VendorGrants {
    /// Mid-window resets observed on any meter OTHER than `label`, placed as
    /// that meter's cliffs place them (the gap's midpoint) and re-voiced for
    /// `label`: `from` is the percent `label` itself stood at going in —
    /// the readout speaks about the chart it is on, never about the meter
    /// that happened to catch the drop. Only grants at or before `through`
    /// (nothing measured past now can have granted anything), deduplicated
    /// across meters: two meters dropping between the same two polls share
    /// an instant to the second, and a wider tolerance still names one
    /// event.
    public static func observed(
        samples: [UsageSample], for label: String, through: Date,
        tolerance: TimeInterval = 120
    ) -> [ResetCliffs.Cliff] {
        let filled = ResetCarry.fill(samples).filter { $0.t <= through }
        let labels = Set(filled.flatMap { $0.percents.keys }).subtracting([label]).sorted()
        var found: [ResetCliffs.Cliff] = []
        for other in labels {
            let series = filled.compactMap { sample -> ResetCliffs.Sample? in
                guard let percent = sample.percents[other] else { return nil }
                return ResetCliffs.Sample(
                    t: sample.t, percent: percent, resetsAt: sample.resets?[other])
            }
            for (a, b) in zip(series, series.dropFirst())
            where ResetCliffs.resetKind(from: a, to: b) == .midWindow {
                let at = ResetCliffs.midpoint(a, b)
                let standing = filled.last { $0.t <= at }?.percents[label] ?? 0
                found.append(ResetCliffs.Cliff(at: at, from: standing, kind: .midWindow))
            }
        }
        return dedupe(found.sorted { $0.at < $1.at }, tolerance: tolerance)
    }

    /// A meter's own grants first — they carry the percent it truly fell
    /// from — then the ones only its siblings caught, minus any that name
    /// an instant already listed.
    public static func union(
        own: [ResetCliffs.Cliff], foreign: [ResetCliffs.Cliff],
        tolerance: TimeInterval = 120
    ) -> [ResetCliffs.Cliff] {
        dedupe((own + foreign).sorted { $0.at < $1.at }, tolerance: tolerance, preferring: own)
    }

    private static func dedupe(
        _ cliffs: [ResetCliffs.Cliff], tolerance: TimeInterval,
        preferring favored: [ResetCliffs.Cliff] = []
    ) -> [ResetCliffs.Cliff] {
        var kept: [ResetCliffs.Cliff] = []
        for cliff in cliffs {
            if let index = kept.firstIndex(where: { abs($0.at.timeIntervalSince(cliff.at)) <= tolerance }) {
                // Within one instant the favored (own) reading wins.
                if favored.contains(cliff), !favored.contains(kept[index]) { kept[index] = cliff }
                continue
            }
            kept.append(cliff)
        }
        return kept.sorted { $0.at < $1.at }
    }
}
