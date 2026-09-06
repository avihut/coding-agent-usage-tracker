import Foundation
import Testing
@testable import UsageCore

@Suite("Profile formatting")
struct ProfileFormattingTests {
    private let timeZone = TimeZone(identifier: "Asia/Jerusalem")!
    private let locale = Locale(identifier: "en_US_POSIX")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
    /// Saturday 2026-09-05 08:42 local.
    private let now = FlexibleISO8601.date(from: "2026-09-05T05:42:00Z")!

    private func meter(_ rank: Int, label: String, resetsIn: TimeInterval?) -> Meter {
        Meter(
            id: "\(rank)-\(label)", label: label, percent: 40,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) }, level: .normal, rank: rank)
    }

    private func prediction(exhaustsIn: TimeInterval?) -> UsagePrediction {
        UsagePrediction(
            ratePerHour: 1, baselineRatePerHour: nil, paceFactor: nil, basis: .recentOnly,
            projectedAtReset: nil, exhaustsAt: exhaustsIn.map { now.addingTimeInterval($0) },
            verdict: .green, rawVerdict: .green, severity: 0, text: "", curve: [])
    }

    @Test("the strip caption names each meter's next event, crossings first")
    func stripCaption() {
        let meters = [
            meter(0, label: "Session", resetsIn: 2 * 3600 + 10 * 60),
            meter(1, label: "Weekly", resetsIn: 3 * 86400),
        ]
        #expect(UsageFormatting.accountStripCaption(
            meters: meters, predictions: [:], now: now, timeZone: timeZone, locale: locale)
            == "S resets in 2h 10m · W resets Tue 08:42")
        #expect(UsageFormatting.accountStripCaption(
            meters: meters, predictions: ["Weekly": prediction(exhaustsIn: 26 * 3600)],
            now: now, timeZone: timeZone, locale: locale)
            == "S resets in 2h 10m · W runs out Sun 10:42")
        #expect(UsageFormatting.accountStripCaption(
            meters: [meter(0, label: "Session", resetsIn: nil)], predictions: [:], now: now) == nil)
        #expect(UsageFormatting.accountStripCaption(meters: [], predictions: [:], now: now) == nil)
    }

    @Test("the state line: Active / Quiet / Dormant with the write's age and the fetch stamp")
    func stateLine() {
        func line(_ ago: TimeInterval?, fetched: TimeInterval? = -40 * 60) -> String {
            UsageFormatting.profileStateLine(
                lastWrite: ago.map { now.addingTimeInterval(-$0) },
                fetchedAt: fetched.map { now.addingTimeInterval($0) }, now: now,
                calendar: calendar, timeZone: timeZone, locale: locale)
        }
        #expect(line(12 * 60) == "Active · last used 12 min ago · Updated 08:02")
        #expect(line(30) == "Active · last used just now · Updated 08:02")
        #expect(line(3 * 3600) == "Quiet · last used 3 hr ago · Updated 08:02")
        #expect(line(36 * 3600) == "Quiet · last used yesterday · Updated 08:02")
        #expect(line(3 * 86400) == "Quiet · last used 3 days ago · Updated 08:02")
        #expect(line(34 * 86400) == "Dormant · last used Aug 2 · Updated 08:02")
        #expect(line(nil, fetched: nil) == "No sessions yet")
        #expect(line(5 * 60, fetched: nil) == "Active · last used 5 min ago")
    }
}

@Suite("profileFound phrasing")
struct ProfileFoundPhrasingTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
        return calendar
    }()
    private let locale = Locale(identifier: "en_US_POSIX")
    private let now = FlexibleISO8601.date(from: "2026-09-05T05:42:00Z")!

    @Test("the offer names the sign-in and the home, and leads to Accounts")
    func offerCopy() {
        let at = FlexibleISO8601.date(from: "2026-09-05T05:04:00Z")!
        let notice = Notice(
            id: Notice.profileFoundID(profileID: "c982130e"), kind: "profileFound",
            occurredAt: at, endedAt: at, recordedAt: at,
            subject: "~/.claude-personal", message: "p@example.com")
        let words = NoticePhrasing.phrase(
            notice, serviceName: "Claude", now: now, calendar: calendar, locale: locale)
        #expect(words.title == "Another Claude account")
        #expect(words.detail == "p@example.com · ~/.claude-personal — add it in Settings → Accounts to meter it.")
        #expect(words.when == "08:04")

        let card = NoticePhrasing.card(notice, serviceName: "Claude", now: now, calendar: calendar, locale: locale)
        #expect(card.severity == nil)
        #expect(card.dismissable)
        #expect(!card.ownsMenuBarSurface)
        #expect(ClaudeProvider().noticeDestination(for: card) == .accounts)
        #expect(CodexProvider().noticeDestination(for: card) == .accounts)

        let anonymous = Notice(
            id: Notice.profileFoundID(profileID: "1a2b3c4d"), kind: "profileFound",
            occurredAt: at, endedAt: at, recordedAt: at, subject: "~/.claude-work")
        #expect(NoticePhrasing.phrase(anonymous, serviceName: "Claude", now: now, calendar: calendar, locale: locale)
            .detail == "~/.claude-work — add it in Settings → Accounts to meter it.")
    }
}
