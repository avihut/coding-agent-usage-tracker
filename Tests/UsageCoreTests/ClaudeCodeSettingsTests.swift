import Foundation
import Testing

@testable import UsageCore

@Suite("ClaudeCodeSettings")
struct ClaudeCodeSettingsTests {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "claude-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "settings.json")
    }

    @Test("a missing file reads as no value")
    func missingReadsNil() throws {
        let settings = ClaudeCodeSettings(fileURL: try temp())
        #expect(settings.readCleanupPeriodDays() == nil)
    }

    @Test("reads the existing value")
    func readsValue() throws {
        let url = try temp()
        try Data(#"{"cleanupPeriodDays":365,"model":"opus"}"#.utf8).write(to: url)
        #expect(ClaudeCodeSettings(fileURL: url).readCleanupPeriodDays() == 365)
    }

    @Test("writing preserves every other key, nested ones included")
    func preservesOtherKeys() throws {
        let url = try temp()
        try Data(#"{"model":"opus","env":{"FOO":"bar"},"cleanupPeriodDays":30}"#.utf8)
            .write(to: url)
        let settings = ClaudeCodeSettings(fileURL: url)
        #expect(settings.writeCleanupPeriodDays(180))
        let dict = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            as? [String: Any]
        #expect(dict?["cleanupPeriodDays"] as? Int == 180)
        #expect(dict?["model"] as? String == "opus")
        #expect((dict?["env"] as? [String: Any])?["FOO"] as? String == "bar")
    }

    @Test("writing creates the file when missing")
    func createsFile() throws {
        let url = try temp()
        let settings = ClaudeCodeSettings(fileURL: url)
        #expect(settings.writeCleanupPeriodDays(90))
        #expect(settings.readCleanupPeriodDays() == 90)
    }

    @Test("unparseable content is never clobbered")
    func refusesGarbage() throws {
        let url = try temp()
        let garbage = Data("not json {".utf8)
        try garbage.write(to: url)
        let settings = ClaudeCodeSettings(fileURL: url)
        #expect(!settings.writeCleanupPeriodDays(90))
        #expect(try Data(contentsOf: url) == garbage)
    }

    @Test("a JSON array is refused too — only an object is a settings file")
    func refusesNonObject() throws {
        let url = try temp()
        let array = Data("[1,2,3]".utf8)
        try array.write(to: url)
        #expect(!ClaudeCodeSettings(fileURL: url).writeCleanupPeriodDays(90))
        #expect(try Data(contentsOf: url) == array)
    }
}
