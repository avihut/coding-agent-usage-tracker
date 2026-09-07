import Foundation
import Testing
@testable import UsageCore

@Suite("Menu bar countdowns")
struct MenuBarCountdownTests {
    private let now = Date(timeIntervalSince1970: 0) // Thu 1970-01-01 00:00 UTC
    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_US_POSIX")

    private func segment(
        _ tag: String, percent: Int? = 50, exhaustsIn: TimeInterval? = nil, resetsIn: TimeInterval? = nil
    ) -> MenuBarSegment {
        MenuBarSegment(
            tag: tag, percent: percent, level: .normal, severity: exhaustsIn == nil ? 0 : 1,
            exhaustsAt: exhaustsIn.map(now.addingTimeInterval), resetsAt: resetsIn.map(now.addingTimeInterval))
    }

    private func countdowns(_ segments: [MenuBarSegment], _ scope: RunsOutScope) -> [MenuBarCountdown] {
        UsageFormatting.menuBarCountdowns(segments, scope: scope, now: now, timeZone: utc, locale: posix)
    }

    @Test("a quiet triple yields nothing under every scope")
    func quiet() {
        let quiet = [segment("S"), segment("W"), segment("F")]
        for scope in RunsOutScope.allCases {
            #expect(countdowns(quiet, scope).isEmpty, "\(scope)")
        }
        // A reset alone is not a story: the element counts to a reset
        // only once the limit is spent.
        #expect(countdowns([segment("S", resetsIn: 3600)], .earliest).isEmpty)
    }

    @Test("the compact tiers: minutes, hours, weekday beyond a day")
    func tiers() {
        #expect(countdowns([segment("S", exhaustsIn: 31 * 60)], .earliest).map(\.text) == ["31m"])
        #expect(countdowns([segment("S", exhaustsIn: 3600)], .earliest).map(\.text) == ["1h"])
        #expect(countdowns([segment("S", exhaustsIn: 65 * 60)], .earliest).map(\.text) == ["1h 05m"])
        #expect(countdowns([segment("S", exhaustsIn: 30)], .earliest).map(\.text) == ["1m"])
        // Sat 1970-01-03 14:00 UTC.
        #expect(countdowns([segment("F", exhaustsIn: 2 * 86400 + 14 * 3600)], .earliest).map(\.text) == ["Sat 14:00"])
    }

    @Test("earliest keeps the first crossing; each keeps every one in meter order")
    func scopes() {
        let triple = [
            segment("S", exhaustsIn: 3 * 3600),
            segment("W"),
            segment("F", exhaustsIn: 45 * 60),
        ]
        let earliest = countdowns(triple, .earliest)
        #expect(earliest.map(\.tag) == ["F"] && earliest.map(\.text) == ["45m"])
        #expect(countdowns(triple, .each).map(\.tag) == ["S", "F"])
        #expect(countdowns(triple, .session).map(\.tag) == ["S"])
        #expect(countdowns(triple, .weekly).isEmpty)
        #expect(countdowns(triple, .scoped).map(\.text) == ["45m"])
    }

    @Test("a spent limit counts down to its reset, and a past crossing is not a countdown")
    func spent() {
        let spent = [segment("S", percent: 100, exhaustsIn: -600, resetsIn: 2 * 3600 + 10 * 60), segment("W")]
        let result = countdowns(spent, .earliest)
        #expect(result.count == 1 && result[0].spent && result[0].text == "2h 10m" && result[0].tag == "S")
        // Spent with the reset already behind: nothing to count.
        #expect(countdowns([segment("S", percent: 100, resetsIn: -60)], .earliest).isEmpty)
        // A crossing stamp in the past under 100%: stale news, nothing.
        #expect(countdowns([segment("S", percent: 97, exhaustsIn: -60)], .earliest).isEmpty)
        // Earliest across a spent session and a far weekly crossing: the
        // reset comes first.
        let mixed = spent + [segment("F", exhaustsIn: 86400 * 2)]
        #expect(countdowns(mixed, .earliest).map(\.tag) == ["S"])
    }

    @Test("segments carry the crossing only under the smoothed red verdict")
    func segmentsCarryCrossings() throws {
        let meters = MeterBuilder.meters(from: try UsageResponse.decode(from: loadFixture("real-2026-08-07")))
        let session = try #require(meters.first { $0.rank == 0 })
        let reset = try #require(session.resetsAt)
        let clock = reset.addingTimeInterval(-2 * 3600)
        func prediction(verdict: UsagePrediction.Verdict, exhaustsAt: Date?) -> UsagePrediction {
            UsagePrediction(
                ratePerHour: 20, baselineRatePerHour: nil, paceFactor: nil, basis: .recentOnly,
                projectedAtReset: 100, exhaustsAt: exhaustsAt, verdict: verdict, rawVerdict: .red,
                severity: 1, text: "", curve: [])
        }
        let crossing = clock.addingTimeInterval(1800)
        let red = UsageFormatting.menuBarSegments(
            from: meters, predictions: [session.label: prediction(verdict: .red, exhaustsAt: crossing)])
        #expect(red[0].exhaustsAt == crossing)
        #expect(red[0].resetsAt == reset)
        // Raw red, displayed yellow (hysteresis mid-flip): no crossing yet.
        let yellow = UsageFormatting.menuBarSegments(
            from: meters, predictions: [session.label: prediction(verdict: .yellow, exhaustsAt: crossing)])
        #expect(yellow[0].exhaustsAt == nil && yellow[0].resetsAt == reset)
        // No prediction at all: the reset still rides along.
        let none = UsageFormatting.menuBarSegments(from: meters)
        #expect(none[0].exhaustsAt == nil && none[0].resetsAt == reset)
        #expect(none[2].resetsAt != nil)
    }

    @Test("the digest segment round-trips the new fields and tolerates their absence")
    func digestSegment() throws {
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let status = SegmentStatus(
            tag: "S", percent: 82, level: "critical", severity: 1, risk: nil,
            exhaustsAt: stamp, resetsAt: stamp.addingTimeInterval(3600))
        let data = try LiveState.encoder().encode(status)
        let back = try LiveState.decoder().decode(SegmentStatus.self, from: data)
        #expect(back == status)
        #expect(MenuBarSegment(back).exhaustsAt == stamp)
        let legacy = try LiveState.decoder().decode(
            SegmentStatus.self, from: Data("{\"tag\":\"S\",\"percent\":10,\"level\":\"normal\"}".utf8))
        #expect(legacy.exhaustsAt == nil && legacy.resetsAt == nil)
    }
}
