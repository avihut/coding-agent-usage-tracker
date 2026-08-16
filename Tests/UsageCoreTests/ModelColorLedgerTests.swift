import Foundation
import Testing

@testable import UsageCore

@Suite("ModelColorLedger")
struct ModelColorLedgerTests {
    @Test("families take hue slots in arrival order; versions take shades")
    func freshAssignment() {
        let ledger = ModelColorLedger().assigning([
            ("claude-fable-5", "Fable"),
            ("claude-opus-4-8", "Opus"),
            ("claude-opus-5", "Opus"),
        ])
        #expect(ledger.hues == ["Fable": 0, "Opus": 1])
        #expect(ledger.shades["Opus"] == ["claude-opus-4-8": 0, "claude-opus-5": 1])
        #expect(ledger.slots(for: "claude-opus-5", family: "Opus")! == (1, 1))
    }

    @Test("shade slots are independent per family — each family starts at 0")
    func shadesPerFamily() {
        let ledger = ModelColorLedger().assigning([
            ("claude-opus-5", "Opus"), ("claude-sonnet-5", "Sonnet"),
        ])
        #expect(ledger.shades["Opus"]?["claude-opus-5"] == 0)
        #expect(ledger.shades["Sonnet"]?["claude-sonnet-5"] == 0)
    }

    @Test("existing assignments never move; new arrivals take the lowest free slot")
    func stability() {
        let first = ModelColorLedger(
            hues: ["Fable": 0, "Opus": 1],
            shades: ["Opus": ["claude-opus-4-8": 0]])
        let grown = first.assigning([
            ("claude-opus-5", "Opus"), ("claude-haiku-4-5", "Haiku"),
        ])
        #expect(grown.hues == ["Fable": 0, "Opus": 1, "Haiku": 2])
        #expect(grown.shades["Opus"] == ["claude-opus-4-8": 0, "claude-opus-5": 1])
        #expect(grown.shades["Haiku"] == ["claude-haiku-4-5": 0])
    }

    @Test("gaps in stored slots fill before the range extends, on both levels")
    func gapFilling() {
        let ledger = ModelColorLedger(
            hues: ["Fable": 0, "Haiku": 2],
            shades: ["Opus": ["a": 0, "b": 2]])
        let grown = ledger.assigning([("claude-sonnet-5", "Sonnet"), ("c", "Opus")])
        #expect(grown.hues["Sonnet"] == 1)
        #expect(grown.shades["Opus"]?["c"] == 1)
    }

    @Test("re-assigning the same models changes nothing")
    func idempotent() {
        let models: [(String, String)] = [
            ("claude-fable-5", "Fable"), ("claude-opus-5", "Opus"),
        ]
        let first = ModelColorLedger().assigning(models)
        #expect(first.assigning(models.reversed()) == first)
    }

    @Test("grow persists under the provider-scoped key and round-trips")
    func persistenceRoundTrip() throws {
        let suite = "test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let grown = ModelColorLedger.grow(
            [("claude-fable-5", "Fable"), ("claude-opus-5", "Opus")],
            defaults: defaults, providerID: "claude")
        #expect(defaults.dictionary(forKey: "claude.modelColorLedger") != nil)
        #expect(ModelColorLedger.load(from: defaults, providerID: "claude") == grown)
        // Another provider's ledger is a separate reservation book.
        #expect(ModelColorLedger.load(from: defaults, providerID: "codex") == ModelColorLedger())
        // Growing with nothing new writes nothing new.
        #expect(
            ModelColorLedger.grow(
                [("claude-opus-5", "Opus")], defaults: defaults, providerID: "claude")
                == grown)
    }
}
