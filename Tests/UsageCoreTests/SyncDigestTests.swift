import Foundation
import Testing
@testable import UsageCore

@Suite("SyncDigest")
struct SyncDigestTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: iso)!
    }

    private func device(_ providerID: String = "claude") -> DeviceDigest {
        DeviceDigest(
            deviceID: "D-1", name: "Test Mac", providerID: providerID,
            accountLabel: "Max plan · 20x", appVersion: "0.51.0",
            timeZone: "UTC", capturedAt: date("2026-08-16T12:00:00Z"))
    }

    private func summary(
        id: String = "s-1", title: String = "Ship the digest",
        projectPath: String? = "/Users/someone/Projects/claude-usage-menubar/main",
        kind: SessionKind = .interactive,
        end: Date
    ) -> SessionSummary {
        SessionSummary(
            id: id, title: title, projectPath: projectPath, gitBranch: "feature/sync",
            agentVersion: "2.1.231", kind: kind,
            start: end.addingTimeInterval(-1800), end: end,
            activeSeconds: 900, prompts: 3, apiCalls: 12, toolCalls: 7,
            subagentCount: 1, compactions: 1,
            models: ["claude-fable-5": TokenTally(input: 1000, output: 200)])
    }

    // Record names are the frozen half of the CloudKit schema: once the
    // production schema deploys, changing any of these strands every
    // already-published record. These literals ARE the contract.
    @Test("record names are pinned")
    func recordNames() {
        #expect(SyncRecordName.zone(deviceID: "D-1") == "device-D-1")
        #expect(SyncRecordName.device(providerID: "claude") == "device|claude")
        #expect(SyncRecordName.day(providerID: "claude", dayKey: "2026-08-16")
            == "day|claude|2026-08-16")
        #expect(SyncRecordName.session(providerID: "codex", sessionID: "abc")
            == "session|codex|abc")
        #expect(SyncRecordName.meters(providerID: "claude") == "meters|claude")
    }

    @Test("days map with local-calendar keys, apiCalls from messages, ascending")
    func dayMapping() {
        let daily = [
            DailyActivity(
                day: date("2026-08-16T00:00:00Z"), tokens: 500, messages: 4, prompts: 2,
                models: ["claude-fable-5": TokenTally(input: 400, output: 100)]),
            DailyActivity(day: date("2026-08-14T00:00:00Z"), tokens: 0, messages: 0, prompts: 6),
        ]
        let digest = SyncDigestBuilder.build(
            device: device(), daily: daily, sessions: [], meters: nil, calendar: utc)
        #expect(digest.days.map(\.dayKey) == ["2026-08-14", "2026-08-16"])
        // The prompt-only day (transcripts already cleaned up) publishes
        // honestly rather than vanishing.
        #expect(digest.days[0].prompts == 6)
        #expect(digest.days[0].tokens == 0)
        #expect(digest.days[1].apiCalls == 4)
        #expect(digest.days[1].models["claude-fable-5"] == TokenTally(input: 400, output: 100))
    }

    @Test("sessions carry the repo folder name, never the path, end-descending")
    func sessionMapping() {
        let older = summary(id: "s-old", end: date("2026-08-15T10:00:00Z"))
        let newer = summary(
            id: "s-new", kind: .background, end: date("2026-08-16T10:00:00Z"))
        let digest = SyncDigestBuilder.build(
            device: device(), daily: [], sessions: [older, newer], meters: nil,
            calendar: utc)
        #expect(digest.sessions.map(\.sessionID) == ["s-new", "s-old"])
        #expect(digest.sessions[0].repoName == "main")
        #expect(digest.sessions[0].kind == "background")
        #expect(digest.sessions[1].kind == "interactive")
        #expect(digest.sessions[1].title == "Ship the digest")
        #expect(digest.sessions[1].prompts == 3)
        #expect(digest.sessions[1].models["claude-fable-5"]?.total == 1200)
    }

    @Test("meter snapshot maps display fields only")
    func meterMapping() {
        let meters = [
            Meter(
                id: "session", label: "Session (5h)", percent: 53,
                resetsAt: date("2026-08-16T03:09:00Z"), level: .normal, rank: 0,
                limitWindow: 5 * 3600),
            Meter(id: "weekly_all", label: "Weekly (all)", percent: nil, resetsAt: nil,
                  level: .normal, rank: 1),
        ]
        let snapshot = MeterSnapshotDigest(
            capturedAt: date("2026-08-16T01:00:00Z"), planLabel: "Max plan · 20x",
            meters: meters)
        #expect(snapshot.meters.count == 2)
        #expect(snapshot.meters[0].percent == 53)
        #expect(snapshot.meters[0].limitWindow == TimeInterval(5 * 3600))
        #expect(snapshot.meters[1].percent == nil)
        #expect(snapshot.planLabel == "Max plan · 20x")
    }

    @Test("digest round-trips through Codable")
    func roundTrip() throws {
        let digest = SyncDigestBuilder.build(
            device: device(),
            daily: [DailyActivity(
                day: date("2026-08-16T00:00:00Z"), tokens: 100, messages: 1, prompts: 1,
                models: ["claude-fable-5": TokenTally(input: 90, output: 10)])],
            sessions: [summary(end: date("2026-08-16T10:00:00Z"))],
            meters: MeterSnapshotDigest(
                capturedAt: date("2026-08-16T01:00:00Z"), planLabel: nil,
                meters: [Meter(id: "session", label: "Session (5h)", percent: 10,
                               resetsAt: nil, level: .normal, rank: 0)]),
            calendar: utc)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let revived = try decoder.decode(
            SyncDigest.self, from: encoder.encode(digest))
        #expect(revived == digest)
        #expect(revived.schemaVersion == SyncDigest.schemaVersion)
    }

    // The privacy line, enforced against the actual encoded bytes: full
    // filesystem paths and prompt-preview fields must never appear in what
    // would leave the machine.
    @Test("encoded digest never contains paths or preview fields")
    func privacyInvariants() throws {
        let digest = SyncDigestBuilder.build(
            device: device(),
            daily: [],
            sessions: [summary(
                projectPath: "/Users/someone/Secret Client/projectx",
                end: date("2026-08-16T10:00:00Z"))],
            meters: nil, calendar: utc)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(digest), as: UTF8.self)
        #expect(!json.contains("/Users/"))
        #expect(!json.contains("Secret Client"))
        #expect(json.contains("projectx"))
        #expect(!json.contains("firstPrompt"))
        #expect(!json.contains("projectPath"))
        #expect(!json.contains("dollars"))
    }
}
