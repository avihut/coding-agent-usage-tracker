import Foundation
import Testing
@testable import UsageCore

/// One out-of-process transcript scan per account: a second caller gives up
/// instead of queueing (issue #24), and the lock adds no file.
@Suite("Transcript scan lock")
struct TranscriptScanLockTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "scan-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a second holder is refused while the first holds it, and gets it once released")
    func secondCallerGivesUp() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let first = TranscriptScanLock.acquire(directory: directory)
            guard case .held = first else {
                Issue.record("the first caller should hold the lock")
                return
            }
            withExtendedLifetime(first) {
                guard case .busy = TranscriptScanLock.acquire(directory: directory) else {
                    Issue.record("a second caller must be refused while a scan runs")
                    return
                }
            }
        }
        guard case .held = TranscriptScanLock.acquire(directory: directory) else {
            Issue.record("the lock must free with its holder")
            return
        }
        // Nothing was created beside the account's own files.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("an account whose folder doesn't exist yet has nothing to contend over")
    func missingDirectoryIsUnavailable() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "scan-lock-missing-\(UUID().uuidString)")
        guard case .unavailable = TranscriptScanLock.acquire(directory: missing) else {
            Issue.record("a missing folder should leave the scan unguarded, not refused")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
