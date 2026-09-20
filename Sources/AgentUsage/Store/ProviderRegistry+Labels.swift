import Foundation
import UsageCore

/// What an account is CALLED on each face — one rule per kind of surface, so
/// no two of them name the same account differently. Split out of
/// ProviderRegistry.swift when that file passed the ~600-line rule.
extension ProviderRegistry {
    /// What a face calls a profile: the digest's word when it has one,
    /// else the record's own.
    func label(for profile: Profile) -> String {
        section(for: profile.key)?.label ?? ProfileFacts.label(profile: profile, identity: nil)
    }

    /// True while accounts of more than one harness are enrolled — when a
    /// bare account label stops saying whose account it is.
    var spansHarnesses: Bool {
        Set(profiles.filter(\.isEnrolled).map(\.providerID)).count > 1
    }

    /// The agent an account belongs to, for a row that lists accounts of
    /// several harnesses flat; nil when the label already IS the agent's
    /// name (a harness with no sign-in to show) or only one harness is here.
    func harnessCaption(for profile: Profile) -> String? {
        guard spansHarnesses else { return nil }
        let agent = provider(for: profile).agentName
        return label(for: profile) == agent ? nil : agent
    }

    /// True for the only shown account of its harness: the row that wears
    /// the vendor's mark instead of a letter.
    func isLoneInHarness(_ profile: Profile) -> Bool {
        shownProfiles.filter { $0.providerID == profile.providerID }.count == 1
    }

    /// How a row names an account — ONE rule for every harness (0.101.0,
    /// user-reported: Claude's row read a sign-in while Codex's read
    /// "Codex", as if they were different kinds of thing). A lone account is
    /// titled by its AGENT, with the sign-in beside it when one is known;
    /// under a harness heading the agent is already said, so the account's
    /// own label leads. Codex and Gemini have no sign-in to show because
    /// their credential files are never read (spec §10), not because they
    /// are a different entity.
    func rowTitle(for profile: Profile) -> (title: String, detail: String?) {
        let label = label(for: profile)
        guard isLoneInHarness(profile) else { return (label, nil) }
        let agent = provider(for: profile).agentName
        return (agent, label == agent ? nil : label)
    }

    /// "work@example.com · Claude Code" — for a menu or picker, where a row
    /// can't carry the harness's mark beside the label.
    func qualifiedLabel(for profile: Profile) -> String {
        [label(for: profile), harnessCaption(for: profile)].compactMap { $0 }.joined(separator: " · ")
    }

    func monogram(for profile: Profile) -> String {
        section(for: profile.key)?.monogram
            ?? ProfileFacts.monogram(profile: profile, label: label(for: profile))
    }
}
