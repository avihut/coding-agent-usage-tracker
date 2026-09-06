import Foundation
import Testing
@testable import UsageCore

@Suite("ProfileID")
struct ProfileIDTests {
    @Test("a custom home hashes to Claude Code's Keychain suffix")
    func derivesClaudeCodeSuffix() {
        // Verified against the real item on the machine this was built on:
        // `Claude Code-credentials-c982130e` for CLAUDE_CONFIG_DIR=~/.claude-personal.
        #expect(ProfileID.derive(homePath: "/Users/avihu/.claude-personal") == "c982130e")
    }

    @Test("a trailing slash never changes the id")
    func trailingSlash() {
        #expect(ProfileID.derive(homePath: "/Users/avihu/.claude-personal/")
            == ProfileID.derive(homePath: "/Users/avihu/.claude-personal"))
        #expect(ProfileID.derive(homePath: "/Users/avihu/.claude-personal//")
            == "c982130e")
    }

    @Test("ids are eight lowercase hex digits, zero-padded")
    func shape() {
        for path in ["/a", "/Users/x/.claude-work", "/tmp/h", "/Users/x/.claude-3"] {
            let id = ProfileID.derive(homePath: path)
            #expect(id.count == 8)
            #expect(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
    }

    @Test("the standard home is `default`; anything else derives")
    func forHome() {
        let standard = URL(filePath: "/Users/avihu/.claude")
        #expect(ProfileID.forHome(standard, standard: standard) == "default")
        #expect(ProfileID.forHome(URL(filePath: "/Users/avihu/.claude/"), standard: standard) == "default")
        #expect(ProfileID.forHome(URL(filePath: "/Users/avihu/.claude-personal"), standard: standard)
            == "c982130e")
        #expect(ProfileID.standard == StorageScope.defaultProfileID)
    }
}

@Suite("PathDisplay")
struct PathDisplayTests {
    @Test("paths under the home abbreviate to ~; others stay absolute")
    func abbreviation() {
        let home = URL(filePath: "/Users/someone")
        #expect(PathDisplay.abbreviated(URL(filePath: "/Users/someone/.claude"), home: home) == "~/.claude")
        #expect(PathDisplay.abbreviated(URL(filePath: "/Users/someone/.claude/"), home: home) == "~/.claude")
        #expect(PathDisplay.abbreviated(URL(filePath: "/Users/someone"), home: home) == "~")
        #expect(PathDisplay.abbreviated(URL(filePath: "/Users/someone-else/.claude"), home: home)
            == "/Users/someone-else/.claude")
        #expect(PathDisplay.abbreviated(URL(filePath: "/tmp/x"), home: home) == "/tmp/x")
    }
}
