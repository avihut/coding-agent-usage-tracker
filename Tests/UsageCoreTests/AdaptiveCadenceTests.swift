import Foundation
import Testing
@testable import UsageCore

@Suite("AdaptiveCadence")
struct AdaptiveCadenceTests {
    let t0 = Date(timeIntervalSince1970: 1_755_000_000)

    @Test("starts attentive at the active interval")
    func startsActive() {
        let cadence = AdaptiveCadence(activeInterval: 300, now: t0)
        #expect(cadence.interval(now: t0) == 300)
        #expect(cadence.multiplier(now: t0) == 1)
    }

    @Test("quiet decays the pace in steps and caps at an hour")
    func decayLadder() {
        let cadence = AdaptiveCadence(activeInterval: 300, now: t0)
        #expect(cadence.interval(now: t0.addingTimeInterval(14 * 60)) == 300)
        #expect(cadence.interval(now: t0.addingTimeInterval(16 * 60)) == 600)
        #expect(cadence.interval(now: t0.addingTimeInterval(61 * 60)) == 1200)
        #expect(cadence.interval(now: t0.addingTimeInterval(5 * 3600)) == 2400)
        let slow = AdaptiveCadence(activeInterval: 900, now: t0)
        #expect(slow.interval(now: t0.addingTimeInterval(5 * 3600)) == 3600)
    }

    @Test("activity snaps a decayed pace back to active")
    func activitySnapsBack() {
        var cadence = AdaptiveCadence(activeInterval: 300, now: t0)
        let later = t0.addingTimeInterval(2 * 3600)
        #expect(cadence.multiplier(now: later) == 4)
        cadence.noteActivity(at: later)
        #expect(cadence.interval(now: later) == 300)
    }

    @Test("usage movement counts as evidence; an unchanged poll does not")
    func successEvidence() {
        var cadence = AdaptiveCadence(activeInterval: 300, now: t0)
        let later = t0.addingTimeInterval(70 * 60)
        cadence.noteSuccess(usageAdvanced: false, at: later)
        #expect(cadence.multiplier(now: later) == 4)
        cadence.noteSuccess(usageAdvanced: true, at: later)
        #expect(cadence.multiplier(now: later) == 1)
    }

    @Test("never faster than the 180s floor, even if a faster interval sneaks in")
    func floors() {
        let cadence = AdaptiveCadence(activeInterval: 60, now: t0)
        #expect(cadence.interval(now: t0) == TriggerGate.floor)
    }

    @Test("429s back off exponentially from five minutes, capped at an hour")
    func backoffLadder() {
        var cadence = AdaptiveCadence(activeInterval: 300, now: t0)
        var now = t0
        var delays: [TimeInterval] = []
        for _ in 0..<6 {
            cadence.noteRateLimited(retryAfter: nil, at: now)
            delays.append(cadence.interval(now: now))
            now = cadence.backoffUntil!
        }
        #expect(delays == [300, 600, 1200, 2400, 3600, 3600])
    }

    @Test("Retry-After wins when longer than the exponential step")
    func retryAfterHonored() {
        var cadence = AdaptiveCadence(activeInterval: 300, now: t0)
        cadence.noteRateLimited(retryAfter: 900, at: t0)
        #expect(cadence.interval(now: t0) == 900)
    }

    @Test("a short Retry-After never undercuts the exponential step")
    func retryAfterFloor() {
        var cadence = AdaptiveCadence(activeInterval: 300, now: t0)
        cadence.noteRateLimited(retryAfter: nil, at: t0)
        cadence.noteRateLimited(retryAfter: 30, at: t0)
        #expect(cadence.interval(now: t0) == 600)
    }

    @Test("an absurd Retry-After is capped at two hours")
    func retryAfterCap() {
        var cadence = AdaptiveCadence(activeInterval: 300, now: t0)
        cadence.noteRateLimited(retryAfter: 86_400, at: t0)
        #expect(cadence.interval(now: t0) == 7200)
    }

    @Test("success heals the backoff completely")
    func backoffHeals() {
        var cadence = AdaptiveCadence(activeInterval: 300, now: t0)
        cadence.noteRateLimited(retryAfter: nil, at: t0)
        cadence.noteRateLimited(retryAfter: nil, at: t0)
        let later = t0.addingTimeInterval(700)
        cadence.noteSuccess(usageAdvanced: true, at: later)
        #expect(!cadence.isBackingOff(now: later))
        #expect(cadence.rateLimitStrikes == 0)
        #expect(cadence.interval(now: later) == 300)
    }

    @Test("activity during a backoff does not shorten the pause")
    func backoffOutranksActivity() {
        var cadence = AdaptiveCadence(activeInterval: 300, now: t0)
        cadence.noteRateLimited(retryAfter: 1800, at: t0)
        let during = t0.addingTimeInterval(60)
        cadence.noteActivity(at: during)
        #expect(cadence.isBackingOff(now: during))
        #expect(cadence.interval(now: during) == 1740)
    }

    @Test("activity polls when the data is older than the active pace")
    func activityPollsOnStaleData() {
        let cadence = AdaptiveCadence(activeInterval: 300, now: t0)
        // Fresh evidence throughout (an agent session churning) must not
        // suppress the poll — staleness alone decides.
        #expect(cadence.shouldPollOnActivity(dataAge: 300, now: t0))
        #expect(cadence.shouldPollOnActivity(dataAge: 1200, now: t0))
        #expect(!cadence.shouldPollOnActivity(dataAge: 299, now: t0))
        #expect(!cadence.shouldPollOnActivity(dataAge: 0, now: t0))
    }

    @Test("activity polls when there is no data at all")
    func activityPollsWithNoData() {
        let cadence = AdaptiveCadence(activeInterval: 300, now: t0)
        #expect(cadence.shouldPollOnActivity(dataAge: nil, now: t0))
    }

    @Test("activity never polls during a backoff, however stale the data")
    func activityPollRespectsBackoff() {
        var cadence = AdaptiveCadence(activeInterval: 300, now: t0)
        cadence.noteRateLimited(retryAfter: nil, at: t0)
        let during = t0.addingTimeInterval(60)
        #expect(!cadence.shouldPollOnActivity(dataAge: 9999, now: during))
        #expect(!cadence.shouldPollOnActivity(dataAge: nil, now: during))
        let after = t0.addingTimeInterval(600)
        #expect(cadence.shouldPollOnActivity(dataAge: 9999, now: after))
    }
}

@Suite("RetryAfter")
struct RetryAfterTests {
    @Test("delta-seconds, with whitespace tolerated")
    func deltaSeconds() {
        #expect(RetryAfter.seconds(from: "120") == 120)
        #expect(RetryAfter.seconds(from: " 45 ") == 45)
        #expect(RetryAfter.seconds(from: "0") == 0)
    }

    @Test("HTTP-date; past dates clamp to zero")
    func httpDate() {
        let now = Date(timeIntervalSince1970: 1_445_412_390) // Wed, 21 Oct 2015 07:26:30 GMT
        #expect(RetryAfter.seconds(from: "Wed, 21 Oct 2015 07:28:00 GMT", now: now) == 90)
        #expect(RetryAfter.seconds(from: "Wed, 21 Oct 2015 07:00:00 GMT", now: now) == 0)
    }

    @Test("garbage degrades to nil, negatives clamp to zero")
    func garbage() {
        #expect(RetryAfter.seconds(from: nil) == nil)
        #expect(RetryAfter.seconds(from: "") == nil)
        #expect(RetryAfter.seconds(from: "soon") == nil)
        #expect(RetryAfter.seconds(from: "inf") == nil)
        #expect(RetryAfter.seconds(from: "-5") == 0)
    }
}

@Suite("UsageMovement")
struct UsageMovementTests {
    private let day = Date(timeIntervalSince1970: 1_755_000_000)

    private func snapshot(_ limits: [UsageLimit]) -> Snapshot {
        makeSnapshot(response: UsageResponse(limits: limits, spend: nil), fetchedAt: day)
    }

    private func limit(_ kind: String, _ percent: Double?, resetsAt: Date? = nil) -> UsageLimit {
        UsageLimit(kind: kind, percent: percent, severity: nil, resetsAt: resetsAt, scope: nil)
    }

    @Test("a rising percent is movement")
    func rise() {
        let old = snapshot([limit("session", 10)])
        let new = snapshot([limit("session", 11)])
        #expect(UsageMovement.advanced(from: old, to: new))
    }

    @Test("unchanged percentages are not movement")
    func flat() {
        let old = snapshot([limit("session", 10), limit("weekly_all", 40)])
        #expect(!UsageMovement.advanced(from: old, to: old))
    }

    @Test("a drop alone is a limit reset, not movement")
    func resetDrop() {
        let old = snapshot([limit("session", 87, resetsAt: day)])
        let new = snapshot([limit("session", 0, resetsAt: nil)])
        #expect(!UsageMovement.advanced(from: old, to: new))
    }

    @Test("a fresh window that already has usage in it is movement")
    func freshWindowWithUsage() {
        let old = snapshot([limit("session", 87, resetsAt: day)])
        let new = snapshot([limit("session", 3, resetsAt: day.addingTimeInterval(5 * 3600))])
        #expect(UsageMovement.advanced(from: old, to: new))
    }

    @Test("sub-second reset jitter alone is not movement")
    func jitteredStamp() {
        // The API restates the same boundary with ±0.5s noise on every
        // poll; reading that as movement kept the cadence pinned at the
        // active interval — quiet-time decay never engaged.
        let old = snapshot([limit("weekly_all", 40, resetsAt: day)])
        let new = snapshot([limit("weekly_all", 40, resetsAt: day.addingTimeInterval(0.437))])
        #expect(!UsageMovement.advanced(from: old, to: new))
    }

    @Test("a brand-new scoped meter with usage is movement")
    func newScopedMeter() {
        let old = snapshot([limit("session", 10)])
        let new = snapshot([limit("session", 10), limit("weekly_scoped", 5)])
        #expect(UsageMovement.advanced(from: old, to: new))
    }

    @Test("no previous snapshot is not movement")
    func noBaseline() {
        #expect(!UsageMovement.advanced(from: nil, to: snapshot([limit("session", 10)])))
    }

    @Test("meters without percentages never count as movement")
    func nilPercents() {
        let old = snapshot([limit("session", nil)])
        let new = snapshot([limit("session", nil, resetsAt: day)])
        #expect(!UsageMovement.advanced(from: old, to: new))
    }
}

@Suite("RefreshIntervalScale")
struct RefreshIntervalScaleTests {
    @Test("a chosen pace slower than the decay cap is honored")
    func slowPaceHonored() {
        let t0 = Date(timeIntervalSince1970: 1_755_000_000)
        let cadence = AdaptiveCadence(activeInterval: 7200, now: t0)
        // Five quiet hours: ×8 decay must not be re-capped below the pace.
        #expect(cadence.interval(now: t0.addingTimeInterval(5 * 3600)) == 7200)
    }

    @Test("endpoints and marks map onto the unit track")
    func positions() {
        #expect(RefreshIntervalScale.position(of: 180) == 0)
        #expect(RefreshIntervalScale.position(of: 7200) == 1)
        let mid = RefreshIntervalScale.position(of: 900)
        #expect(mid > 0.42 && mid < 0.45)
    }

    @Test("near-mark positions snap to the mark")
    func snapping() {
        let nearFive = RefreshIntervalScale.position(of: 300) + 0.02
        #expect(RefreshIntervalScale.value(at: nearFive) == 300)
    }

    @Test("between marks, values round to clean steps")
    func rounding() {
        let fast = RefreshIntervalScale.value(at: 0.29)
        #expect(fast.truncatingRemainder(dividingBy: 60) == 0)
        #expect(fast > 300 && fast < 900)
        let slow = RefreshIntervalScale.value(at: 0.93)
        #expect(slow.truncatingRemainder(dividingBy: 300) == 0)
        #expect(slow > 3600 && slow < 7200)
    }

    @Test("duration labels for the dial")
    func durationLabels() {
        #expect(UsageFormatting.duration(180) == "3 min")
        #expect(UsageFormatting.duration(900) == "15 min")
        #expect(UsageFormatting.duration(3600) == "1 hr")
        #expect(UsageFormatting.duration(5400) == "1 hr 30 min")
        #expect(UsageFormatting.duration(7200) == "2 hr")
    }

    @Test("day-scale durations read in days, not stacked hours")
    func dayScaleDurations() {
        #expect(UsageFormatting.duration(23 * 3600) == "23 hr")
        #expect(UsageFormatting.duration(24 * 3600) == "1 day")
        #expect(UsageFormatting.duration(26 * 3600) == "1 day 2 hr")
        #expect(UsageFormatting.duration(24 * 3600 + 1800) == "1 day")
        #expect(UsageFormatting.duration(7 * 86400) == "7 days")
    }
}
