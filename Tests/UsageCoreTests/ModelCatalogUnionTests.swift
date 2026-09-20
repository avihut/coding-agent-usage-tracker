import Foundation
import Testing

@testable import UsageCore

/// The union catalog (v0.101.0). Its ONE load-bearing property is that a
/// Claude id keeps answering exactly what it answered when Claude's catalog
/// was the only one installed: family names key the persisted, provider-scoped
/// `ModelColorLedger`, so a shifted family name would re-key it and shuffle
/// every chart's colors on the update.
@Suite struct ModelCatalogUnionTests {
    private let providers = HarnessResolution.standardProviders()
    private var union: ModelCatalog { ModelCatalog.union(of: providers) }

    @Test func bundledProviderIsFirst() {
        // The tie-break order the union's compatibility rests on.
        #expect(providers.first?.id == HarnessResolution.bundledProviderID)
        #expect(providers.first?.id == "claude")
    }

    @Test func everyBundledRateIDAnswersExactlyAsClaudeAlone() {
        let claude = ModelCatalog.claude
        let union = union
        var checked = 0
        for id in PricingTable.bundled.rates.keys {
            #expect(union.displayName(id) == claude.displayName(id), "display \(id)")
            #expect(union.familyName(id) == claude.familyName(id), "family \(id)")
            checked += 1
        }
        // The bundled floor is the corpus every install has already ledgered.
        #expect(checked > 10)
    }

    @Test func claudeIDsAndFamiliesAreUnchanged() {
        let claude = ModelCatalog.claude
        let union = union
        for id in [
            "claude-fable-5", "claude-opus-5", "claude-haiku-4-5-20251001",
            "claude-3-5-sonnet-20241022", "claude-2", "unknown",
        ] {
            #expect(union.displayName(id) == claude.displayName(id), "display \(id)")
            #expect(union.familyName(id) == claude.familyName(id), "family \(id)")
        }
        // Claude's own bands keep their exact numbers — the first catalog's
        // offset is zero — so the rates list orders as it always has.
        for family in ["Fable", "Mythos", "Opus", "Sonnet", "Haiku", "Other"] {
            #expect(union.familyRank(family) == claude.familyRank(family), "rank \(family)")
        }
        #expect(union.familyRank("Fable") < union.familyRank("Opus"))
        #expect(union.familyRank("Sonnet") < union.familyRank("Haiku"))
    }

    @Test func foreignIDsReadInTheirOwnVendorsGrammar() {
        let union = union
        #expect(union.displayName("gpt-5.2-codex") == ModelCatalog.codex.displayName("gpt-5.2-codex"))
        #expect(union.familyName("gpt-5.2-codex") == "Codex")
        #expect(union.familyName("gpt-5.2") == "GPT")
        #expect(union.displayName("gemini-3-pro-20260115") == "Gemini 3 Pro")
        #expect(union.familyName("gemini-3-pro-20260115") == "Gemini Pro")
        #expect(union.familyName("o3-mini") == "GPT" || union.familyName("o3-mini") == "O3")
    }

    @Test func everyVendorsFamiliesSortInTheirOwnBand() {
        let union = union
        // Within a vendor the vendor's own ladder holds…
        #expect(union.familyRank("Codex") < union.familyRank("GPT"))
        #expect(union.familyRank("Gemini Pro") < union.familyRank("Gemini Flash"))
        // …and the bands follow the harnesses' standard order, so a rates
        // list spanning harnesses reads Claude, then Codex, then Gemini.
        #expect(union.familyRank("Haiku") < union.familyRank("Codex"))
        #expect(union.familyRank("GPT") < union.familyRank("Gemini Pro"))
    }

    @Test func aFamilyNobodyNamesSortsLast() {
        let union = union
        #expect(union.familyRank("SomethingElse") > union.familyRank("Gemini Nano"))
        // Unknowns tie with each other, so the call site's alphabetical
        // fallback still decides between them.
        #expect(union.familyRank("SomethingElse") == union.familyRank("AnotherThing"))
    }

    @Test func oneCatalogIsItselfAndNoneIsGeneric() {
        let single = ModelCatalog.union([.claude])
        #expect(single.displayName("claude-opus-5") == "Opus 5")
        #expect(single.familyRank("SomethingElse") == ModelCatalog.claude.familyRank("SomethingElse"))
        #expect(ModelCatalog.union([]).displayName("whatever-1") == "whatever-1")
    }

    @Test func aCatalogAnsweringAloneStillClaimsEverything() {
        // The default in `init` — a catalog that declares nothing keeps
        // answering every id, which is what every pre-0.101 catalog did.
        let bare = ModelCatalog(
            displayName: { "d-\($0)" }, familyName: { "f-\($0)" }, familyRank: { _ in 7 })
        #expect(bare.claims("anything"))
        #expect(bare.claimsFamily("anything"))
        #expect(ModelCatalog.union([bare, .claude]).displayName("claude-opus-5") == "d-claude-opus-5")
    }
}
