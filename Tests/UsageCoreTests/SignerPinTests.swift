import Foundation
import Testing
@testable import UsageCore

/// Real signatures, made on the spot: copies of two system tools, re-signed
/// ad-hoc. An ad-hoc signature's designated requirement is its own code hash
/// — so "same code" satisfies it and "validly signed, but different" does
/// not, which is exactly the distinction `codesign --verify` cannot make.
@Suite("Signer pin")
struct SignerPinTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "signer-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func adHocCopy(of tool: String, named name: String, in dir: URL) throws -> URL {
        let copy = dir.appending(path: name)
        try FileManager.default.copyItem(at: URL(filePath: tool), to: copy)
        let sign = Process()
        sign.executableURL = URL(filePath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--identifier", name, copy.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        try #require(sign.terminationStatus == 0)
        return copy
    }

    @Test("the same signed code satisfies its own requirement")
    func sameCodePasses() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let installed = try adHocCopy(of: "/usr/bin/true", named: "installed", in: dir)
        let twin = dir.appending(path: "twin")
        try FileManager.default.copyItem(at: installed, to: twin)
        #expect(throws: Never.self) {
            try SignerPin.verify(candidate: twin, against: installed)
        }
        #expect(SignerPin.requirementText(of: installed)?.contains("cdhash") == true)
    }

    @Test("a VALID signature that isn't ours is refused — the case codesign --verify lets through")
    func otherSignerRefused() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let installed = try adHocCopy(of: "/usr/bin/true", named: "installed", in: dir)
        let stranger = try adHocCopy(of: "/bin/echo", named: "stranger", in: dir)
        #expect {
            try SignerPin.verify(candidate: stranger, against: installed)
        } throws: { error in
            guard case SignerPin.Failure.notSatisfied = error else { return false }
            return true
        }
    }

    @Test("something that isn't signed code at all is refused, never trusted")
    func unsignedRefused() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let installed = try adHocCopy(of: "/usr/bin/true", named: "installed", in: dir)
        let junk = dir.appending(path: "junk")
        try Data("not code".utf8).write(to: junk)
        #expect(throws: SignerPin.Failure.self) {
            try SignerPin.verify(candidate: junk, against: installed)
        }
        // …and an installed side with no signature can vouch for nothing.
        #expect(throws: SignerPin.Failure.self) {
            try SignerPin.verify(candidate: installed, against: junk)
        }
    }
}
