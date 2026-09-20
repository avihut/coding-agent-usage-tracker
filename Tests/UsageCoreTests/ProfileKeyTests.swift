import Foundation
import Testing

@testable import UsageCore

/// The flat name every metered account answers to once several harnesses run
/// side by side — and the collision argument behind it, since each harness's
/// standard home is `default`.
@Suite("Profile keys")
struct ProfileKeyTests {
    private let added = Date(timeIntervalSince1970: 1_757_000_000)

    @Test("the bundled harness keeps bare ids; every other harness qualifies")
    func keys() {
        let bundled = HarnessResolution.bundledProviderID
        #expect(ProfileKey.make(providerID: bundled, profileID: "default") == "default")
        #expect(ProfileKey.make(providerID: bundled, profileID: "c982130e") == "c982130e")
        #expect(ProfileKey.make(providerID: "codex", profileID: "default") == "codex")
        #expect(ProfileKey.make(providerID: "codex", profileID: "ab12cd34") == "codex.ab12cd34")
        #expect(ProfileKey.make(providerID: "gemini", profileID: "default") == "gemini")

        let personal = Profile(
            id: "c982130e", providerID: bundled, home: URL(filePath: "/x/.claude-personal"),
            addedAt: added)
        #expect(personal.key == "c982130e")
        #expect(Profile(id: "default", providerID: "codex", home: nil, addedAt: added).key == "codex")
        // The key is never the storage id: files stay where they are.
        #expect(Profile(id: "default", providerID: "codex", home: nil, addedAt: added).id == "default")
    }

    /// The whole reason keys can be flat: no derived account id can be
    /// mistaken for a harness, so `codex` and `codex.<id>` can never collide
    /// with the bundled harness's own ids.
    @Test("no harness id can be a derived account id, and keys are unique")
    func noCollisions() {
        let providers = HarnessResolution.standardProviders()
        for provider in providers {
            #expect(provider.id != StorageScope.defaultProfileID)
            let looksDerived = provider.id.count == 8
                && provider.id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
            #expect(!looksDerived)
            #expect(!provider.id.contains("."))
        }
        var seen: Set<String> = []
        for provider in providers {
            for id in [StorageScope.defaultProfileID, "ab12cd34", "c982130e"] {
                let key = ProfileKey.make(providerID: provider.id, profileID: id)
                #expect(!seen.contains(key))
                seen.insert(key)
            }
        }
        #expect(seen.count == providers.count * 3)
    }

    /// A home-less harness's one account would read "default" in every UI
    /// string; its agent's name is what it is called instead.
    @Test("a home-less account is labelled by its agent, not by its id")
    func labels() {
        let codex = Profile(id: "default", providerID: "codex", home: nil, addedAt: added)
        #expect(ProfileFacts.label(profile: codex, identity: nil, fallback: "Codex") == "Codex")
        #expect(ProfileFacts.monogram(
            profile: codex,
            label: ProfileFacts.label(profile: codex, identity: nil, fallback: "Codex")) == "C")
        // Nothing passed: the pre-harness behaviour, the id.
        #expect(ProfileFacts.label(profile: codex, identity: nil) == "default")
        // A home still names the account, fallback or not.
        let claude = Profile(
            id: "default", providerID: HarnessResolution.bundledProviderID,
            home: URL(filePath: "/x/.claude"), addedAt: added)
        #expect(ProfileFacts.label(profile: claude, identity: nil, fallback: "Claude Code") == "claude")
    }
}
