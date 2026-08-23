import Foundation
import Testing

@testable import UsageCore

@Suite("AppVersion")
struct AppVersionTests {
    @Test("tags parse with or without the v, garbage does not")
    func parsing() {
        #expect(AppVersion("0.87.0")?.parts == [0, 87, 0])
        #expect(AppVersion("v0.87.0")?.parts == [0, 87, 0])
        #expect(AppVersion("V1.2")?.parts == [1, 2])
        #expect(AppVersion("") == nil)
        #expect(AppVersion("v") == nil)
        #expect(AppVersion("0.87.0-beta.1") == nil)
        #expect(AppVersion("release-2") == nil)
        #expect(AppVersion("1..2") == nil)
    }

    @Test("comparison is numeric per component, not lexicographic")
    func ordering() throws {
        let a = try #require(AppVersion("0.9.9"))
        let b = try #require(AppVersion("0.10.0"))
        #expect(a < b)
        // Shorter side pads with zeros.
        #expect(AppVersion("1.0") == AppVersion("1.0.0"))
        #expect(try #require(AppVersion("1.0")) < #require(AppVersion("1.0.1")))
    }

    @Test("isNewer stays quiet on equal, older, and unparseable input")
    func newer() {
        #expect(AppVersion.isNewer("0.88.0", than: "0.87.1"))
        #expect(AppVersion.isNewer("v1.0.0", than: "0.99.9"))
        #expect(!AppVersion.isNewer("0.87.1", than: "0.87.1"))
        #expect(!AppVersion.isNewer("0.86.0", than: "0.87.1"))
        // A feed that stops making sense must never raise the flag.
        #expect(!AppVersion.isNewer("nightly", than: "0.87.1"))
        #expect(!AppVersion.isNewer("1.0.0", than: "unknown"))
    }
}
