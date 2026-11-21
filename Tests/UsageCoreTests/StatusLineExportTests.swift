import Foundation
import Testing

@testable import UsageCore

@Suite("Status-line export")
struct StatusLineExportTests {
    private let now = Date()

    private func payload(_ remaining: Double, reset: Date? = nil) -> Data {
        AntigravityStatusLine.payload(quota: AntigravityStatusLine.quota([
            AntigravityStatusLine.bucket(
                "gemini-5h", remaining: remaining, reset: reset ?? now.addingTimeInterval(3600)),
        ]))
    }

    private func age(_ url: URL, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }

    @Test("written once, left alone while unchanged, rewritten when it changes or goes stale")
    func writeRules() throws {
        let fixture = try AntigravityFixture()
        defer { fixture.tearDown() }
        let export = try #require(fixture.provider().statusLineExport)
        let reset = now.addingTimeInterval(3600)

        #expect(StatusLineExportWriter.run(export, stdin: payload(0.8, reset: reset), now: now)
            == .written)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.export.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(StatusLineExportWriter.run(
            export, stdin: payload(0.801, reset: reset.addingTimeInterval(10)), now: now + 5)
            == .unchanged)
        #expect(StatusLineExportWriter.run(export, stdin: payload(0.7, reset: reset), now: now + 6)
            == .written)
        try age(fixture.export, by: 120)
        #expect(StatusLineExportWriter.run(export, stdin: payload(0.7, reset: reset), now: now)
            == .written)
        // Only the export file sits in its folder — no temp file left behind.
        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.export.deletingLastPathComponent().path)
        #expect(names == ["statusline-export.json"])
    }

    @Test("nothing worth keeping writes nothing")
    func ignored() throws {
        let fixture = try AntigravityFixture()
        defer { fixture.tearDown() }
        let export = try #require(fixture.provider().statusLineExport)
        for stdin in [
            Data(), Data("{".utf8), AntigravityStatusLine.payload(quota: nil),
            Data(count: StatusLineExportWriter.stdinCap + 1),
        ] {
            #expect(StatusLineExportWriter.run(export, stdin: stdin, now: now) == .ignored)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.export.path))
    }

    @Test("the command exits 0 and prints nothing, whatever happens")
    func command() throws {
        let fixture = try AntigravityFixture()
        defer { fixture.tearDown() }
        let providers: [any UsageProvider] = [fixture.provider(), CodexProvider()]
        let stdin = payload(0.5)

        let ok = StatusLineExportCommand.run(
            arguments: ["antigravity"], stdin: { stdin }, executablePath: "/x/usage-cli",
            providers: providers, now: now)
        #expect(ok == .init(stdout: "", stderr: "", code: 0))
        #expect(FileManager.default.fileExists(atPath: fixture.export.path))

        let elsewhere = fixture.root.appending(path: "elsewhere/out.json")
        let redirected = StatusLineExportCommand.run(
            arguments: ["antigravity", "--to", elsewhere.path], stdin: { stdin },
            executablePath: "/x/usage-cli", providers: providers, now: now)
        #expect(redirected.code == 0)
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))

        let unknown = StatusLineExportCommand.run(
            arguments: ["codex"], stdin: { stdin }, executablePath: "/x/usage-cli",
            providers: providers, now: now)
        #expect(unknown.code == 0 && unknown.stdout.isEmpty)
        #expect(unknown.stderr.contains("known: antigravity"))

        let unwritable = StatusLineExportCommand.run(
            arguments: ["antigravity", "--to", "/dev/null/out.json"], stdin: { stdin },
            executablePath: "/x/usage-cli", providers: providers, now: now)
        #expect(unwritable.code == 0 && unwritable.stdout.isEmpty)
        #expect(unwritable.stderr.contains("could not write"))
    }

    @Test("--print-config gives the agent's settings entry for this binary")
    func printConfig() throws {
        let fixture = try AntigravityFixture()
        defer { fixture.tearDown() }
        let result = StatusLineExportCommand.run(
            arguments: ["antigravity", "--print-config"],
            stdin: { Issue.record("print-config read stdin"); return Data() },
            executablePath: "/Apps/Agent's Usage.app/Contents/MacOS/usage-cli",
            providers: [fixture.provider()], now: now)
        #expect(result.code == 0)
        #expect(result.stdout.contains("~/.gemini/antigravity-cli/settings.json"))
        #expect(result.stdout.contains(#""stack_with_default": true"#))
        #expect(result.stdout.contains(
            #"'/Apps/Agent'\\''s Usage.app/Contents/MacOS/usage-cli' export-statusline antigravity 2>/dev/null; exit 0"#))
        #expect(!FileManager.default.fileExists(atPath: fixture.export.path))
        let unknown = StatusLineExportCommand.run(
            arguments: ["nope", "--print-config"], stdin: { Data() }, executablePath: "/x",
            providers: [fixture.provider()], now: now)
        #expect(unknown.code == 19)
    }
}
