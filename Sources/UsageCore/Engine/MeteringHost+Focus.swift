import Foundation

extension MeteringHost {
    /// Whether a harness's eligible accounts give the focus rule anything to
    /// lead with (`HarnessFocusCandidate.reportsMeters`). False only when
    /// EVERY one of them has read its usage and holds no limit. An engine
    /// that hasn't read yet answers from its cached last fetch, so a launch
    /// or a takeover doesn't briefly lead with a harness that had nothing to
    /// show; one with neither (no local data, no cache) counts as "has
    /// meters", so a quiet harness is never demoted on a guess.
    func reportsMeters(eligibleKeys: [String]) -> Bool {
        guard !eligibleKeys.isEmpty else { return true }
        return eligibleKeys.contains { key in
            guard let engine = engines[key],
                  let snapshot = engine.state.snapshot ?? engine.cachedSnapshot()
            else { return true }
            return !snapshot.meters.isEmpty
        }
    }

    /// The harnesses that report no limits right now — what `sink` compares
    /// against to re-run focus only when that changes (focus is otherwise
    /// recomputed on activity and reprobes, never on a plain publish).
    func meterlessHarnesses(rows: [HarnessRoster.Row]) -> Set<String> {
        Set(rows.compactMap { row in
            let keys = row.profiles.filter(\.isEnrolled)
                .filter { $0.enabled && !dormant.contains($0.key) }
                .map(\.key)
            return reportsMeters(eligibleKeys: keys) ? nil : row.id
        })
    }
}
