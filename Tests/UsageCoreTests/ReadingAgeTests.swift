import Foundation
import Testing
@testable import UsageCore

/// A limits reading's AGE (2026-11-22, user-reported: a three-day-old Codex
/// reading named a plan the account had left and forecast from a weekly it
/// no longer had). Distinct from each window's own roll rule.
@Suite("Reading age")
struct ReadingAgeTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func meter(
        _ label: String, percent: Int? = 40, window: TimeInterval?, rank: Int = 1,
        resetsAt: Date? = nil
    ) -> Meter {
        Meter(
            id: label, label: label, percent: percent,
            resetsAt: resetsAt ?? now.addingTimeInterval(3 * 86400),
            level: .normal, rank: rank, limitWindow: window)
    }

    @Test("the horizon is the shortest window, capped at six hours")
    func horizon() {
        let session = meter("Session", window: 5 * 3600, rank: 0)
        let weekly = meter("Weekly", window: 7 * 86400)
        #expect(ReadingAge.horizon(meters: [session, weekly]) == 5 * 3600)
        #expect(ReadingAge.horizon(meters: [weekly]) == ReadingAge.cap)
        #expect(ReadingAge.cap == 6 * 3600)
        // A window stated nowhere, or no meters at all: the cap.
        #expect(ReadingAge.horizon(meters: [meter("Unknown", window: nil)]) == ReadingAge.cap)
        #expect(ReadingAge.horizon(meters: []) == ReadingAge.cap)
        // A nonsensical zero window states nothing.
        #expect(ReadingAge.horizon(meters: [meter("Zero", window: 0)]) == ReadingAge.cap)
    }

    @Test("old is strictly past the horizon")
    func boundary() {
        let meters = [meter("Weekly", window: 7 * 86400)]
        func old(_ age: TimeInterval) -> Bool {
            ReadingAge.isOld(fetchedAt: now.addingTimeInterval(-age), meters: meters, now: now)
        }
        #expect(!old(0))
        #expect(!old(ReadingAge.cap - 1))
        #expect(!old(ReadingAge.cap))
        #expect(old(ReadingAge.cap + 1))
        #expect(old(3.5 * 86400))
        #expect(ReadingAge.oldAt(fetchedAt: now, meters: meters) == now.addingTimeInterval(ReadingAge.cap))
    }

    @Test("a reading stamped in the future is never called old")
    func futureStamp() {
        let meters = [meter("Weekly", window: 7 * 86400)]
        #expect(!ReadingAge.isOld(fetchedAt: now.addingTimeInterval(7200), meters: meters, now: now))
    }

    /// The cap must outlast the slowest spacing between two GOOD polls,
    /// or a healthy slow-paced account would flicker old between them.
    @Test("a healthy engine's poll spacing never reaches the horizon")
    func outlastsCadence() {
        #expect(ReadingAge.cap > AdaptiveCadence.maxActiveInterval)
        #expect(ReadingAge.cap > AdaptiveCadence.ceiling)
        #expect(ReadingAge.cap > AdaptiveCadence.backoffCeiling)
        // Claude's shortest window, the 5 h session, sits above them too.
        #expect(5 * 3600 > AdaptiveCadence.maxActiveInterval)
    }

    @Test("the snapshot and display state answer with the same rule")
    func snapshotAndState() {
        let meters = [meter("Weekly", window: 7 * 86400)]
        let fresh = Snapshot(meters: meters, fetchedAt: now.addingTimeInterval(-600))
        let old = Snapshot(meters: meters, fetchedAt: now.addingTimeInterval(-3 * 86400))
        #expect(!fresh.isOld(at: now))
        #expect(old.isOld(at: now))
        #expect(old.oldAt == old.fetchedAt.addingTimeInterval(ReadingAge.cap))
        #expect(DisplayState.live(fresh).asOf(at: now) == nil)
        #expect(DisplayState.live(old).asOf(at: now) == old.fetchedAt)
        // Old and cache-served are independent facts.
        #expect(DisplayState.cached(old, error: .network).asOf(at: now) == old.fetchedAt)
        #expect(DisplayState.cached(fresh, error: .network).asOf(at: now) == nil)
        #expect(DisplayState.loading.asOf(at: now) == nil)
        #expect(DisplayState.unavailable(.noLocalData).asOf(at: now) == nil)
    }

    /// Gemini's meter is a count re-taken on every poll — its reading is
    /// always as of now, so the rule never touches it.
    @Test("a reading re-taken every poll never ages")
    func recountedNeverAges() {
        let daily = meter("Daily · counted locally", window: 86400, rank: 0)
        let counted = Snapshot(meters: [daily], fetchedAt: now)
        #expect(!counted.isOld(at: now))
        #expect(!counted.isOld(at: now.addingTimeInterval(ReadingAge.cap)))
    }
}

/// The one forecast engine makes no forecast from an old reading.
@Suite("Reading age — forecasts")
struct ReadingAgeForecastTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let label = "Weekly"

    private var weekly: Meter {
        Meter(
            id: "1-weekly", label: label, percent: 75,
            resetsAt: now.addingTimeInterval(47 * 3600), level: .normal, rank: 1,
            limitWindow: 7 * 86400)
    }

    /// A steep climb: forecast to cross before the reset.
    private var samples: [UsageSample] {
        (0...8).map { step in
            UsageSample(
                t: now.addingTimeInterval(Double(step - 8) * 1800),
                percents: [label: 59 + step * 2])
        }
    }

    private func forecast(readingAge: TimeInterval?) -> [String: UsagePrediction] {
        PredictionEngine.predictAll(
            meters: [weekly], samples: samples, profiles: [:], previous: [:],
            readingAt: readingAge.map { now.addingTimeInterval(-$0) }, now: now)
    }

    @Test("a fresh reading forecasts exactly as without an age")
    func freshForecasts() throws {
        let fresh = forecast(readingAge: 120)
        let prediction = try #require(fresh[label])
        #expect(prediction.exhaustsAt != nil)
        #expect(fresh == forecast(readingAge: nil))
    }

    @Test("an old reading forecasts nothing")
    func oldForecastsNothing() {
        #expect(forecast(readingAge: 3 * 86400).isEmpty)
    }

    @Test("the forecast stops exactly past the horizon")
    func boundary() {
        #expect(!forecast(readingAge: ReadingAge.cap).isEmpty)
        #expect(forecast(readingAge: ReadingAge.cap + 1).isEmpty)
    }

    /// Codex's window rolls on its own reset whatever the reading's age:
    /// an old reading whose window has reset reads 0%, no reset — and old.
    @Test("old and rolled: the roll still applies, and the reading is old")
    func oldAndRolled() throws {
        let read = now.addingTimeInterval(-3 * 86400)
        let payload = """
        {"capturedAt": \(read.timeIntervalSinceReferenceDate),
         "planType": "prolite",
         "primary": {"usedPercent": 60, "windowMinutes": 300,
                     "resetsAt": \(read.addingTimeInterval(3600).timeIntervalSinceReferenceDate)},
         "secondary": {"usedPercent": 75, "windowMinutes": 10080,
                       "resetsAt": \(now.addingTimeInterval(47 * 3600).timeIntervalSinceReferenceDate)}}
        """
        let snapshot = try CodexMeterBuilder.snapshot(
            fromPayload: Data(payload.utf8), thresholds: .standard, now: now)
        let session = try #require(snapshot.meters.first { $0.rank == 0 })
        #expect(session.percent == 0)
        #expect(session.resetsAt == nil)
        let weekly = try #require(snapshot.meters.first { $0.rank == 1 })
        #expect(weekly.percent == 75)
        #expect(snapshot.isOld(at: now))
        #expect(DisplayState.live(snapshot).asOf(at: now) == read)
        #expect(snapshot.plan?.displayLabel == "Pro Lite plan")
        #expect(PredictionEngine.predictAll(
            meters: snapshot.meters, samples: samples, profiles: [:], previous: [:],
            readingAt: snapshot.fetchedAt, now: now).isEmpty)
    }
}

/// What an old cell keeps: a SPENT window's countdown to its reset — the
/// one thing a locked-out account waits on, while its reading ages through
/// the lockout — and nothing a forecast says.
@Suite("Reading age — countdowns and words")
struct ReadingAgeCountdownTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A session forecast to cross in 40 min, a weekly spent until Sat.
    private var segments: [MenuBarSegment] {
        [
            MenuBarSegment(
                tag: "S", percent: 80, level: .warning, severity: 1,
                exhaustsAt: now.addingTimeInterval(40 * 60), resetsAt: now.addingTimeInterval(3 * 3600)),
            MenuBarSegment(
                tag: "W", percent: 100, level: .critical, severity: 1,
                exhaustsAt: now.addingTimeInterval(-3600), resetsAt: now.addingTimeInterval(2 * 86400)),
        ]
    }

    private func tags(_ cached: Bool, _ old: Bool, _ scope: RunsOutScope) -> [String] {
        UsageFormatting.menuBarCountdowns(
            segments, scope: scope, now: now, cached: cached, old: old,
            timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US_POSIX"))
            .map { "\($0.tag)\($0.spent ? "↺" : "")" }
    }

    @Test("current counts everything; cached nothing; old only the spent reset")
    func rule() {
        #expect(tags(false, false, .each) == ["S", "W↺"])
        #expect(tags(true, false, .each) == [])
        #expect(tags(false, true, .each) == ["W↺"])
        // Cached AND old: cache-served never alarms, whatever its age.
        #expect(tags(true, true, .each) == [])
    }

    /// `.earliest` picks AFTER the forecast is shed: the session's crossing
    /// (40 min) would otherwise crowd out the weekly's reset (2 days).
    @Test("an old cell's earliest countdown is the spent reset, never a crossing")
    func earliest() {
        #expect(tags(false, false, .earliest) == ["S"])
        #expect(tags(false, true, .earliest) == ["W↺"])
    }

    @Test("the account state line says as of for an old reading, Updated otherwise")
    func stateLine() {
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let fetched = now.addingTimeInterval(-3 * 86400)
        let posix = Locale(identifier: "en_US_POSIX")
        let old = UsageFormatting.profileStateLine(
            lastWrite: fetched, fetchedAt: fetched, old: true, now: now,
            calendar: calendar, timeZone: utc, locale: posix)
        let current = UsageFormatting.profileStateLine(
            lastWrite: fetched, fetchedAt: fetched, now: now,
            calendar: calendar, timeZone: utc, locale: posix)
        #expect(old.hasSuffix(" · as of " + UsageFormatting.updatedStamp(
            fetched, now: now, calendar: calendar, timeZone: utc, locale: posix)))
        #expect(current.contains(" · Updated "))
        #expect(!current.contains("as of"))
    }
}
