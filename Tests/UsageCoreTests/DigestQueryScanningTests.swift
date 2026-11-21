import Foundation
import Testing

@testable import UsageCore

/// Absent ≠ zero, printed (2026-11-21): while the account's first scan is
/// running, the nouns that read its rollup refuse with exit 28 instead of
/// printing the empty rollup as "0 tokens".
extension DigestQueryTests {
    func digest(activityStatus: [String: Any]?) throws -> (LiveState, Data) {
        var object = try #require(JSONSerialization.jsonObject(with: goldenRaw) as? [String: Any])
        object["activityStatus"] = activityStatus
        // A scanning writer's top level keeps an EMPTY rollup and shortlist.
        if (activityStatus?["state"] as? String) == "scanning" { object["sessions"] = [Any]() }
        let raw = try JSONSerialization.data(withJSONObject: object)
        return (try LiveState.decoder().decode(LiveState.self, from: raw), raw)
    }

    @Test func scanningActivityIsAbsentNeverZero() throws {
        let (scanning, raw) = try digest(activityStatus: ["state": "scanning"])
        for args in [["activity"], ["activity", "today", "tokens"], ["cost"], ["models"],
                     ["get", "activity.todayTokens"], ["account", "today-tokens"], ["account", "accounts"]] {
            let output = run(args, digest: scanning, rawDigest: raw)
            #expect(output.exitCode == DigestQuery.exitScanning, "\(args)")
            #expect(output.stdout.isEmpty, "\(args)")
            #expect(output.note?.contains("not zero") == true, "\(args)")
        }
        // Meters are not activity: limits answer as ever.
        #expect(run(["limits"], digest: scanning, rawDigest: raw).exitCode == DigestQuery.exitOK)
    }

    @Test func cachedOrScannedActivityAnswers() throws {
        for state: [String: Any]? in [nil, ["state": "scanned", "asOf": "2026-08-16T11:59:00Z"],
                                       ["state": "cached", "asOf": "2026-08-16T11:12:00Z"]] {
            let (digest, raw) = try digest(activityStatus: state)
            #expect(run(["activity", "today", "tokens"], digest: digest, rawDigest: raw).exitCode
                == DigestQuery.exitOK)
        }
    }

    /// The CLI routes `sessions`/`session` through `DeepQuerySessionsCLI`,
    /// never `DigestQuery.run` — the guard must hold on THAT path.
    @Test func scanningSessionsAreAbsentOnTheCLIsOwnPath() throws {
        let (scanning, _) = try digest(activityStatus: ["state": "scanning"])
        let list = DeepQuerySessionsCLI.run(
            noun: "sessions", arguments: [], digest: scanning, now: now, profiles: [])
        #expect(list.exitCode == DigestQuery.exitScanning)
        #expect(list.stdout.isEmpty)
        // No engine answered: still "not counted yet", never "no such session".
        let one = DeepQuerySessionsCLI.run(
            noun: "session", arguments: ["latest", "--no-scan"], digest: scanning, now: now, profiles: [],
            engine: { _, _ in .silent })
        #expect(one.exitCode == DigestQuery.exitScanning)
        // An engine still on its first scan is busy: 27, and never a scan.
        let busy = DeepQuerySessionsCLI.run(
            noun: "session", arguments: ["latest", "--all"], digest: scanning, now: now, profiles: [],
            engine: { _, _ in .busy })
        #expect(busy.exitCode == DeepQuery.exitScanBusy)
        // A scanned digest answers as ever.
        let (scanned, _) = try digest(activityStatus: ["state": "scanned", "asOf": "2026-08-16T11:59:00Z"])
        #expect(DeepQuerySessionsCLI.run(
            noun: "sessions", arguments: [], digest: scanned, now: now, profiles: []).exitCode == DigestQuery.exitOK)
    }

    @Test func aNewerWritersActivityStateReadsAsScanned() throws {
        let (future, _) = try digest(activityStatus: ["state": "rebuilding", "asOf": "2026-08-16T11:59:00Z"])
        #expect(future.activityStatus?.state == .scanned)
        #expect(run(["activity", "today", "tokens"], digest: future).exitCode == DigestQuery.exitOK)
    }
}
