import Darwin
import Foundation
import Testing

@testable import UsageCore

/// "Busy", not "offline" (2026-11-21): the rule every face speaks about its
/// host with, pinned by vectors the Rust TUI decodes too.
@Suite("Engine liveness")
struct EngineLivenessTests {
    private struct Vectors: Decodable {
        struct Case: Decodable {
            let name: String
            let generatedAt: Date?
            let nextPollAt: Date?
            let now: Date
            let leaseHeld: Bool
            let expected: EngineLiveness
        }

        let cases: [Case]
    }

    private func vectors() throws -> [Vectors.Case] {
        let url = try #require(
            Bundle.module.url(forResource: "liveness-cases", withExtension: "json", subdirectory: "Fixtures"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Vectors.self, from: Data(contentsOf: url)).cases
    }

    @Test("every shared vector classifies as the fixture says")
    func sharedVectors() throws {
        let cases = try vectors()
        #expect(cases.count >= 8)
        for item in cases {
            let got = EngineHostBroker.liveness(
                generatedAt: item.generatedAt, nextPollAt: item.nextPollAt, now: item.now,
                leaseHeld: item.leaseHeld)
            #expect(got == item.expected, "\(item.name)")
        }
    }

    @Test("the liveness cutoff is the takeover rule's, unchanged")
    func cutoffMatchesTheBroker() {
        let generated = Date(timeIntervalSince1970: 1_800_000_000)
        for age in stride(from: 0.0, through: 900, by: 30) {
            let now = generated.addingTimeInterval(age)
            let stale = EngineHostBroker.heartbeatStale(
                generatedAt: generated, nextPollAt: generated.addingTimeInterval(300), now: now)
            let live = EngineHostBroker.liveness(
                generatedAt: generated, nextPollAt: generated.addingTimeInterval(300), now: now,
                leaseHeld: false)
            #expect((live == .live) == !stale)
        }
    }

    // MARK: - The probe

    private func lockURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "liveness-\(UUID().uuidString)").appending(path: "engine.lock")
    }

    @Test("an exclusive holder reads as held; a free lease doesn't")
    @MainActor
    func holderIsSeen() {
        let url = lockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(EngineLease.isHeld(at: url) == false)  // no file at all
        let lease = EngineLease(lockURL: url)
        #expect(lease.acquire())
        #expect(EngineLease.isHeld(at: url))
        lease.release()
        #expect(EngineLease.isHeld(at: url) == false)
    }

    /// The app and a TUI may probe the same starved host at the same moment.
    /// An exclusive trial lock would make each see the other as "held";
    /// a shared one never does.
    @Test("two probers never see each other as a holder")
    func probersDontCollide() throws {
        let url = lockURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        // Another prober mid-probe: a shared lock held on its own descriptor.
        let other = open(url.path, O_RDONLY)
        defer { close(other) }
        #expect(flock(other, LOCK_SH | LOCK_NB) == 0)
        #expect(EngineLease.isHeld(at: url) == false)
        flock(other, LOCK_UN)
    }
}
