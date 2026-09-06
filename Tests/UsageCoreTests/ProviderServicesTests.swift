import Foundation
import Testing
@testable import UsageCore

@Suite("Provider services")
@MainActor
struct ProviderServicesTests {
    private func roots() throws -> (StorageScope.Roots, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "provider-services-\(UUID().uuidString)")
        let roots = StorageScope.Roots(
            support: root.appending(path: "support"), caches: root.appending(path: "caches"))
        try FileManager.default.createDirectory(at: roots.support, withIntermediateDirectories: true)
        return (roots, root)
    }

    private func reset(_ hours: Double, profileID: String) -> Notice {
        let at = Date(timeIntervalSinceReferenceDate: hours * 3600)
        return Notice(
            id: Notice.resetID(profileID: profileID, at: at), kind: "reset", occurredAt: at,
            endedAt: at, recordedAt: at, meterLabel: "Weekly (all)", fromPercent: 40,
            profileID: profileID)
    }

    @Test("pollsStatus false builds no poller; the provider still declares whether it tracks status")
    func noPoller() throws {
        let (roots, root) = try roots()
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = ProviderServices(
            provider: ClaudeProvider(), bundleID: "com.test", roots: roots, pollsStatus: false)
        claude.start()
        #expect(claude.serviceStatus == nil)
        #expect(claude.tracksStatus)
        // Tracked but nothing recorded: an empty floor, not an absent one.
        #expect(claude.outageSpans(now: Date()) == [])
        claude.stop()

        let codex = ProviderServices(
            provider: CodexProvider(), bundleID: "com.test", roots: roots, pollsStatus: false)
        #expect(!codex.tracksStatus)
        #expect(codex.outageSpans(now: Date()) == nil)
    }

    @Test("a ledger edit from any engine signals the host once, and lands in the provider's file")
    func ledgerChangeSignals() throws {
        let (roots, root) = try roots()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = ProviderServices(
            provider: ClaudeProvider(), bundleID: "com.test", roots: roots, pollsStatus: false)
        let changes = Box(0)
        services.onChange = { changes.value += 1 }

        let first = services.notices.mutate { $0.record(self.reset(10, profileID: "default")) }
        let second = services.notices.mutate { $0.record(self.reset(10, profileID: "c982130e")) }
        let repeated = services.notices.mutate { $0.record(self.reset(10, profileID: "default")) }
        #expect(first && second && !repeated)
        #expect(changes.value == 2)
        #expect(services.notices.pending.count == 2)

        let file = StorageScope.providerDirectory(bundleID: "com.test", providerID: "claude", roots: roots)
            .appending(path: "notices.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(NoticeLedger(directory: file.deletingLastPathComponent()).notices.count == 2)
    }

    @Test("pricing serves the bundled floor before any feed, from the provider directory")
    func pricingFloor() throws {
        let (roots, root) = try roots()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = ProviderServices(
            provider: ClaudeProvider(), bundleID: "com.test", roots: roots, pollsStatus: false)
        #expect(services.pricing.rates(for: "claude-fable-5") != nil)
        #expect(!services.isRefreshingPricing && services.pricingRefreshError == nil)
    }

    @Test("stop drops the change signal")
    func stopDropsSignals() throws {
        let (roots, root) = try roots()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = ProviderServices(
            provider: ClaudeProvider(), bundleID: "com.test", roots: roots, pollsStatus: false)
        let changes = Box(0)
        services.onChange = { changes.value += 1 }
        services.stop()
        services.notices.mutate { $0.record(self.reset(10, profileID: "default")) }
        #expect(changes.value == 0)
    }
}
