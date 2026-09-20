import Foundation

/// One account's name across every harness (multi-harness metering,
/// v0.101.0). Each harness's standard home is profile `default`, so once
/// several harnesses are metered at once a bare profile id no longer names
/// one account. The KEY is what the host, the digest, the control socket,
/// the focus pin and every face use instead:
///
/// - the bundled default provider's accounts keep their bare ids
///   (`default`, `ab12cd34`), so a Mac that meters only that harness keeps
///   every id it ever published, pinned, or selected on a command line;
/// - every other provider's accounts take their storage scope prefix
///   (`codex`, `gemini`, `codex.ab12cd34`) — unique already, and already
///   what their defaults keys hang off.
///
/// No two accounts share a key: derived profile ids are eight hex digits
/// and the standard id is `default`, while every other key begins with a
/// provider id, which is neither (pinned by ProfileKeyTests).
///
/// A key is never a path component. Storage stays keyed by (provider,
/// profile id) — `Profile.id` — so no harness's files move.
public enum ProfileKey {
    public static func make(providerID: String, profileID: String) -> String {
        providerID == HarnessResolution.bundledProviderID
            ? profileID
            : StorageScope.scopePrefix(providerID: providerID, profileID: profileID)
    }
}

extension Profile {
    /// This account's name across every harness (`ProfileKey`).
    public var key: String { ProfileKey.make(providerID: providerID, profileID: id) }
}
