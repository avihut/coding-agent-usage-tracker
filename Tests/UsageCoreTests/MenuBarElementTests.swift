import Foundation
import Testing
@testable import UsageCore

@Suite("Menu bar elements")
struct MenuBarElementTests {
    @Test("tokens round-trip and an unknown token drops out alone")
    func tokens() throws {
        #expect(MenuBarElement.meters.token == "meters")
        #expect(MenuBarElement.runsOut(.each).token == "runsOut:each")
        #expect(MenuBarElement(token: "runsOut:weekly") == .runsOut(.weekly))
        #expect(MenuBarElement(token: "runsOut:hologram") == nil)
        #expect(MenuBarElement(token: "clock") == nil)
        let decoded = MenuBarLayout.decode(tokens: ["clock", "runsOut:scoped", "meters"])
        #expect(decoded == [.runsOut(.scoped), .meters])
        // Codable spells the token, nothing structural.
        let data = try JSONEncoder().encode([MenuBarElement.meters, .runsOut(.earliest)])
        #expect(String(decoding: data, as: UTF8.self) == "[\"meters\",\"runsOut:earliest\"]")
        #expect(try JSONDecoder().decode([MenuBarElement].self, from: data) == [.meters, .runsOut(.earliest)])
    }

    @Test("normalization keeps exactly one meters and at most one runs-out")
    func normalization() {
        #expect(MenuBarLayout.normalized([]) == [.meters])
        #expect(MenuBarLayout.normalized([.runsOut(.each)]) == [.meters, .runsOut(.each)])
        #expect(MenuBarLayout.normalized([.meters, .meters, .runsOut(.each), .runsOut(.session)])
            == [.meters, .runsOut(.each)])
        #expect(MenuBarLayout.normalized([.runsOut(.each), .meters]) == [.runsOut(.each), .meters])
    }

    @Test("placing before or after the meters keeps an existing scope; removal and re-scoping")
    func arranging() {
        let standard = MenuBarLayout.standard
        #expect(MenuBarLayout.placing(.runsOut(.earliest), beforeMeters: true, in: standard)
            == [.runsOut(.earliest), .meters])
        #expect(MenuBarLayout.placing(.runsOut(.earliest), beforeMeters: false, in: standard)
            == [.meters, .runsOut(.earliest)])
        let scoped: [MenuBarElement] = [.meters, .runsOut(.weekly)]
        // A re-placement (a second drag from the palette) moves the one
        // that is there rather than resetting its scope.
        #expect(MenuBarLayout.placing(.runsOut(.earliest), beforeMeters: true, in: scoped)
            == [.runsOut(.weekly), .meters])
        #expect(MenuBarLayout.runsOutScope(in: scoped) == .weekly)
        #expect(MenuBarLayout.runsOutScope(in: standard) == nil)
        #expect(MenuBarLayout.settingRunsOut(.each, in: scoped) == [.meters, .runsOut(.each)])
        #expect(MenuBarLayout.settingRunsOut(.each, in: standard) == [.meters, .runsOut(.each)])
        #expect(MenuBarLayout.removingRunsOut(from: scoped) == [.meters])
        #expect(MenuBarLayout.removingRunsOut(from: standard) == [.meters])
    }

    @Test("a profile carries its elements; a pre-0.98 record reads as the standard list")
    func profileElements() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let json = """
        [{"id":"default","providerID":"claude","addedAt":"2026-09-06T10:00:00Z"},
         {"id":"c982130e","providerID":"claude","homePath":"/h","addedAt":"2026-09-06T10:00:00Z",
          "menuBarElements":["runsOut:each","meters","clock"]}]
        """
        let profiles = try decoder.decode([Profile].self, from: Data(json.utf8))
        #expect(profiles[0].menuBarElements == MenuBarLayout.standard)
        #expect(profiles[1].menuBarElements == [.runsOut(.each), .meters])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let profile = Profile(
            id: "c982130e", providerID: "claude", home: URL(filePath: "/h"),
            menuBarElements: [.runsOut(.session), .runsOut(.each)], addedAt: Date(timeIntervalSince1970: 0))
        #expect(profile.menuBarElements == [.meters, .runsOut(.session)])
        let text = String(decoding: try encoder.encode(profile), as: UTF8.self)
        #expect(text.contains("\"menuBarElements\":[\"meters\",\"runsOut:session\"]"))
        let back = try decoder.decode(Profile.self, from: Data(text.utf8))
        #expect(back.menuBarElements == profile.menuBarElements)
    }
}
