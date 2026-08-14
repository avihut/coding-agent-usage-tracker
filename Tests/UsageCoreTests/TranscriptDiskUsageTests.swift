import Foundation
import Testing

@testable import UsageCore

@Suite("TranscriptDiskUsage")
struct TranscriptDiskUsageTests {
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "disk-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appending(path: "project-a"), withIntermediateDirectories: true)
        return root
    }

    private func write(
        _ bytes: Int, at path: String, in root: URL, modified: Date
    ) throws {
        let url = root.appending(path: path)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: url.path)
    }

    @Test("sums nested files and spans days from the oldest one")
    func measures() throws {
        let root = try makeTree()
        let now = Date()
        try write(1000, at: "project-a/one.jsonl", in: root, modified: now.addingTimeInterval(-3600))
        try write(500, at: "project-a/two.jsonl", in: root,
                  modified: now.addingTimeInterval(-9.5 * 86400))
        let usage = TranscriptDiskUsage.measure(root: root, now: now)
        #expect(usage?.bytes == 1500)
        #expect(usage?.days == 10)
    }

    @Test("a missing or empty root measures as nothing")
    func emptyIsNil() throws {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "disk-usage-missing-\(UUID().uuidString)")
        #expect(TranscriptDiskUsage.measure(root: missing) == nil)
        let empty = try makeTree()
        #expect(TranscriptDiskUsage.measure(root: empty) == nil)
    }

    @Test("projection scales the per-day rate to the target window")
    func projects() {
        let usage = TranscriptDiskUsage(bytes: 2000, days: 2)
        #expect(usage.projectedBytes(forDays: 5) == 5000)
        #expect(usage.projectedBytes(forDays: 1) == 1000)
    }
}
