import Foundation
import Testing
@testable import UsageCore

@Suite("ProfileGroups")
struct ProfileGroupsTests {
    private func profile(_ id: String, _ providerID: String) -> Profile {
        Profile(id: id, providerID: providerID, home: nil, addedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("groups follow the first appearance of each harness, members keep their order")
    func order() {
        let work = profile("default", "claude")
        let codex = profile("default", "codex")
        let personal = profile("c982130e", "claude")
        let groups = ProfileGroups.byHarness([work, codex, personal])
        #expect(groups.map(\.providerID) == ["claude", "codex"])
        #expect(groups[0].profiles.map(\.key) == [work.key, personal.key])
        #expect(groups[1].profiles.map(\.key) == [codex.key])
    }

    @Test("every harness's standard account is `default` on disk, and still lands in its own group")
    func sameStorageID() {
        let groups = ProfileGroups.byHarness([
            profile("default", "claude"), profile("default", "codex"), profile("default", "gemini"),
        ])
        #expect(groups.count == 3)
        #expect(groups.allSatisfy { $0.profiles.count == 1 })
    }

    @Test("no profiles, no groups")
    func empty() {
        #expect(ProfileGroups.byHarness([]).isEmpty)
    }

    @Test("a lone account is the only one of its harness")
    func lone() {
        let work = profile("default", "claude")
        let personal = profile("c982130e", "claude")
        let codex = profile("default", "codex")
        let all = [work, personal, codex]
        #expect(!ProfileGroups.isLone(work, in: all))
        #expect(ProfileGroups.isLone(codex, in: all))
        #expect(ProfileGroups.isLone(work, in: [work, codex]))
    }
}
