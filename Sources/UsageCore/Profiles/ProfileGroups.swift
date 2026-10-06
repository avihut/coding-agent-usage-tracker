import Foundation

/// Accounts grouped by the harness they belong to — the panel's account
/// strip and the main window's sidebar list them this way, one heading per
/// harness with several accounts.
public enum ProfileGroups {
    /// One group per harness, in the order its first account appears in
    /// `profiles` (the roster's order — the bar's left to right), each
    /// group's accounts in their own order. A harness with no account in
    /// `profiles` has no group.
    public static func byHarness(_ profiles: [Profile]) -> [(providerID: String, profiles: [Profile])] {
        var order: [String] = []
        var members: [String: [Profile]] = [:]
        for profile in profiles {
            if members[profile.providerID] == nil { order.append(profile.providerID) }
            members[profile.providerID, default: []].append(profile)
        }
        return order.map { ($0, members[$0] ?? []) }
    }

    /// The only account of its harness in `profiles`: its row wears the
    /// harness's mark and agent name, with no heading above it.
    public static func isLone(_ profile: Profile, in profiles: [Profile]) -> Bool {
        profiles.count { $0.providerID == profile.providerID } == 1
    }
}
