import Foundation
import Testing

@testable import UsageCore

/// Pins the words every face prints verbatim. Times are Jerusalem local
/// (UTC+3 in September) so the day words and the overnight rule are
/// exercised against a real offset.
@Suite("Notice phrasing")
struct NoticePhrasingTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
        return calendar
    }()
    private let locale = Locale(identifier: "en_US_POSIX")

    private func date(_ iso: String) -> Date { FlexibleISO8601.date(from: iso)! }

    /// Saturday 2026-09-05 08:42 local.
    private var now: Date { date("2026-09-05T05:42:00Z") }

    private func words(_ notice: Notice) -> NoticePhrasing.Words {
        NoticePhrasing.phrase(
            notice, serviceName: "Claude", now: now, calendar: calendar, locale: locale)
    }

    @Test func theResetSpeaksInTheVendorsVoiceWithAnApproximateTime() {
        let at = date("2026-09-04T18:10:00Z") // 21:10 local, yesterday
        let notice = Notice(
            id: Notice.resetID(at: at), kind: "reset", occurredAt: at, endedAt: at,
            recordedAt: at, meterLabel: "Weekly (all)", fromPercent: 71)
        let words = words(notice)
        #expect(words.title == "Limit reset · Claude")
        #expect(words.detail == "Weekly (all) fell from 71% ahead of its reset.")
        #expect(words.when == "~21:10 yesterday")

        let card = NoticePhrasing.card(
            notice, serviceName: "Claude", now: now, calendar: calendar, locale: locale)
        #expect(card.severity == nil)
        #expect(card.dismissable)
        #expect(!card.ownsMenuBarSurface)
        #expect(card.meterLabel == "Weekly (all)")
    }

    @Test func aResetNobodyStoodAboveZeroForReadsGenerically() {
        let at = date("2026-09-05T03:00:00Z") // 06:00 local today
        let notice = Notice(
            id: Notice.resetID(at: at), kind: "reset", occurredAt: at, endedAt: at,
            recordedAt: at, meterLabel: "S", fromPercent: 0)
        let words = words(notice)
        #expect(words.detail == "Limits emptied ahead of their reset.")
        #expect(words.when == "~06:00")
    }

    @Test func anOngoingOutageCarriesPhaseMessageAndARunningClock() {
        let notice = Notice(
            id: Notice.outageID(incidentID: "a"), kind: "outage",
            occurredAt: date("2026-09-05T05:12:00Z"), ongoing: true,
            recordedAt: now, subject: "Elevated errors on Claude Code", impact: "major",
            phase: "identified", message: "We have identified the cause.")
        let words = words(notice)
        #expect(words.title == "Elevated errors on Claude Code")
        #expect(words.detail == "Identified · “We have identified the cause.”")
        #expect(words.when == "Ongoing · 30 min")

        let card = NoticePhrasing.card(
            notice, serviceName: "Claude", now: now, calendar: calendar, locale: locale)
        #expect(card.severity == "major")
        #expect(!card.dismissable)
        #expect(card.ownsMenuBarSurface)
    }

    @Test func aWatchedOutageEndsQuietly() {
        let notice = Notice(
            id: Notice.outageID(incidentID: "a"), kind: "outage",
            occurredAt: date("2026-09-04T22:10:00Z"), endedAt: date("2026-09-05T00:20:00Z"),
            ongoing: false, seenWhileOngoing: true, recordedAt: now,
            subject: "Elevated errors on Claude Code", impact: "major", phase: "resolved")
        let words = words(notice)
        #expect(words.title == "Outage ended")
        #expect(words.detail == "Elevated errors on Claude Code · resolved")
        #expect(words.when == "03:20 · lasted 2 hr 10 min")
    }

    @Test func anUnwatchedNightOutageIsSummarizedWhole() {
        let notice = Notice(
            id: Notice.outageID(incidentID: "a"), kind: "outage",
            occurredAt: date("2026-09-04T22:10:00Z"), endedAt: date("2026-09-05T00:20:00Z"),
            ongoing: false, seenWhileOngoing: false, recordedAt: now,
            subject: "Elevated errors on Claude Code", impact: "major", phase: "resolved")
        let words = words(notice)
        #expect(words.title == "Outage overnight")
        #expect(words.when == "01:10 – 03:20 · 2 hr 10 min")
    }

    @Test func anUnwatchedDaytimeOutageIsWhileAway() {
        let notice = Notice(
            id: Notice.outageID(incidentID: "a"), kind: "outage",
            occurredAt: date("2026-09-04T08:00:00Z"), endedAt: date("2026-09-04T09:00:00Z"),
            ongoing: false, seenWhileOngoing: false, recordedAt: now,
            subject: "Elevated errors", impact: "minor", phase: "resolved")
        let words = words(notice)
        #expect(words.title == "Outage while away")
        #expect(words.when == "yesterday 11:00 – 12:00 · 1 hr")
    }

    @Test func dayWordsStepFromClockToWeekdayToDate() {
        func clock(_ iso: String) -> String {
            NoticePhrasing.dayClock(date(iso), now: now, calendar: calendar, locale: locale)
        }
        #expect(clock("2026-09-05T03:00:00Z") == "06:00")
        #expect(clock("2026-09-04T18:10:00Z") == "21:10 yesterday")
        #expect(clock("2026-09-03T18:10:00Z") == "Thu 21:10")
        #expect(clock("2026-08-28T18:10:00Z") == "Aug 28, 21:10")
    }

    /// The card's indicator: a lone ongoing outage owns the glyph capsule
    /// and lights nothing; anything else pending lights the dot.
    @Test func theIndicatorIgnoresNoticesThatOwnTheirSurface() {
        let outage = Notice(
            id: Notice.outageID(incidentID: "a"), kind: "outage", occurredAt: now,
            ongoing: true, recordedAt: now, subject: "x", impact: "major")
        let reset = Notice(
            id: Notice.resetID(at: now), kind: "reset", occurredAt: now, endedAt: now,
            recordedAt: now)
        let alone = NoticePhrasing.card(
            pending: [outage], serviceName: "Claude", now: now, calendar: calendar, locale: locale)
        #expect(!alone.indicator)
        #expect(alone.pendingCount == 1)
        let both = NoticePhrasing.card(
            pending: [outage, reset], serviceName: "Claude", now: now,
            calendar: calendar, locale: locale)
        #expect(both.indicator)
        let none = NoticePhrasing.card(
            pending: [], serviceName: "Claude", now: now, calendar: calendar, locale: locale)
        #expect(!none.indicator && none.items.isEmpty)
    }
}

/// Where a click on a notice leads is the provider's call.
@Suite("Notice destinations")
struct NoticeDestinationTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func card(kind: String, url: String? = nil, meterLabel: String? = nil) -> NoticeCard {
        NoticeCard(
            id: "\(kind)|x", kind: kind, severity: nil, title: "t", detail: nil, when: "w",
            occurredAt: now, endedAt: nil, ongoing: false, dismissable: true, seen: false,
            ownsMenuBarSurface: false, url: url, components: [], meterLabel: meterLabel)
    }

    @Test func claudeOutagesOpenTheirIncidentReport() {
        let provider = ClaudeProvider()
        #expect(
            provider.noticeDestination(for: card(kind: "outage", url: "https://stspg.io/abc"))
                == .web(URL(string: "https://stspg.io/abc")!))
        // No shortlink: the status page itself.
        #expect(
            provider.noticeDestination(for: card(kind: "outage"))
                == .web(URL(string: "https://status.claude.com")!))
    }

    /// Anthropic publishes no feed of limit resets, so the reset lands on
    /// the meter that voiced it, lit at the reset's moment.
    @Test func claudeResetsOpenTheMeterCard() {
        let provider = ClaudeProvider()
        #expect(
            provider.noticeDestination(for: card(kind: "reset", meterLabel: "Weekly (all)"))
                == .meterHistory(meterLabel: "Weekly (all)", at: now))
        #expect(provider.noticeDestination(for: card(kind: "quota")) == nil)
    }

    @Test func theDefaultPolicyMatchesForProvidersWithoutAStatusFeed() {
        // Codex declares no status feed: an outage without a URL goes nowhere.
        let provider = CodexProvider()
        #expect(provider.noticeDestination(for: card(kind: "outage")) == nil)
        #expect(
            provider.noticeDestination(for: card(kind: "reset", meterLabel: "Weekly"))
                == .meterHistory(meterLabel: "Weekly", at: now))
    }
}
