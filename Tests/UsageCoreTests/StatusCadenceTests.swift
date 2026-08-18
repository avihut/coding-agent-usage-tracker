import Foundation
import Testing

@testable import UsageCore

/// The polling cadence (decision D1). Every number here is load-bearing for
/// politeness toward a feed we don't own, so each transition is pinned rather
/// than left to a comment.
@Suite("Status cadence")
struct StatusCadenceTests {
    let t0 = Date(timeIntervalSince1970: 1_787_000_000)

    /// Jitter pinned to its midpoint, so `nextDelay` returns the base.
    let noJitter: () -> Double = { 0.5 }

    @Test("healthy polls every five minutes")
    func healthy() {
        var cadence = StatusCadence()
        cadence.record(.observed(hasIncident: false), now: t0)

        #expect(cadence.phase == .healthy)
        #expect(cadence.nextDelay(jitter: noJitter) == 300)
    }

    @Test("an incident tightens to a minute")
    func incident() {
        var cadence = StatusCadence()
        cadence.record(.observed(hasIncident: true), now: t0)

        #expect(cadence.phase == .incident)
        #expect(cadence.nextDelay(jitter: noJitter) == 60)
    }

    @Test("resolution enters a ten-minute cooldown, then settles back")
    func cooldown() {
        var cadence = StatusCadence()
        cadence.record(.observed(hasIncident: true), now: t0)
        cadence.record(.observed(hasIncident: false), now: t0.addingTimeInterval(60))

        #expect(cadence.phase == .cooldown)
        #expect(cadence.nextDelay(jitter: noJitter) == 120)

        // Still inside the window: stays in cooldown.
        cadence.record(.observed(hasIncident: false), now: t0.addingTimeInterval(300))
        #expect(cadence.phase == .cooldown)

        // Past it: back to the slow lane.
        cadence.record(.observed(hasIncident: false), now: t0.addingTimeInterval(700))
        #expect(cadence.phase == .healthy)
        #expect(cadence.nextDelay(jitter: noJitter) == 300)
    }

    @Test("a reopen during cooldown goes straight back to the incident pace")
    func reopen() {
        var cadence = StatusCadence()
        cadence.record(.observed(hasIncident: true), now: t0)
        cadence.record(.observed(hasIncident: false), now: t0.addingTimeInterval(60))
        #expect(cadence.phase == .cooldown)

        cadence.record(.observed(hasIncident: true), now: t0.addingTimeInterval(180))
        #expect(cadence.phase == .incident)
        #expect(cadence.nextDelay(jitter: noJitter) == 60)

        // And the stale cooldown expiry must not resurface later: resolving
        // again starts a FRESH ten minutes.
        cadence.record(.observed(hasIncident: false), now: t0.addingTimeInterval(240))
        #expect(cadence.phase == .cooldown)
        cadence.record(.observed(hasIncident: false), now: t0.addingTimeInterval(600))
        #expect(cadence.phase == .cooldown, "the window restarts from the new resolution")
    }

    @Test("failures back off by doubling, capped at fifteen minutes")
    func backoff() {
        var cadence = StatusCadence()
        var now = t0
        let expected: [TimeInterval] = [60, 120, 240, 480, 900, 900]
        for delay in expected {
            cadence.record(.failed, now: now)
            #expect(cadence.phase == .unreachable)
            #expect(cadence.nextDelay(jitter: noJitter) == delay)
            now = now.addingTimeInterval(delay)
        }
    }

    @Test("three consecutive failures make the card unknown; one success heals it")
    func unknownThreshold() {
        var cadence = StatusCadence()
        cadence.record(.failed, now: t0)
        #expect(!cadence.isUnknown, "one miss says nothing about the service")
        cadence.record(.failed, now: t0.addingTimeInterval(60))
        #expect(!cadence.isUnknown)
        cadence.record(.failed, now: t0.addingTimeInterval(180))
        #expect(cadence.isUnknown)

        cadence.record(.observed(hasIncident: false), now: t0.addingTimeInterval(400))
        #expect(!cadence.isUnknown)
        #expect(cadence.failures == 0)
        #expect(cadence.phase == .healthy)
    }

    @Test("jitter stays within ten percent and never dips under the CDN floor")
    func jitterBounds() {
        var cadence = StatusCadence()
        cadence.record(.observed(hasIncident: false), now: t0)

        #expect(cadence.nextDelay(jitter: { 0 }) == 270)
        #expect(cadence.nextDelay(jitter: { 1 }) == 330)

        // Even at the tightest pace with maximum negative jitter, the CDN's
        // own 10s cache TTL is the hard floor.
        var incident = StatusCadence()
        incident.record(.observed(hasIncident: true), now: t0)
        #expect(incident.nextDelay(jitter: { 0 }) == 54)
        #expect(incident.nextDelay(jitter: { 0 }) >= StatusCadence.minimumSpacing)
    }

    @Test("out-of-band pokes wait out the CDN cache window")
    func pokeSpacing() {
        var cadence = StatusCadence()
        #expect(cadence.mayPollNow(t0), "nothing polled yet")

        cadence.record(.observed(hasIncident: false), now: t0)
        #expect(!cadence.mayPollNow(t0.addingTimeInterval(5)))
        #expect(cadence.mayPollNow(t0.addingTimeInterval(10)))
    }
}
