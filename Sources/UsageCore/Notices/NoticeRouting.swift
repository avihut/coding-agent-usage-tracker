import Foundation

/// How a notice is named once several harnesses are metered at once
/// (v0.101.0). Every harness keeps its OWN ledger — one `notices.json` per
/// provider, as before — and two ledgers can legitimately hold the same id:
/// a vendor reset is named by the minute it happened in. So the digest names
/// another harness's notice `<provider>:<id>`, and a dismissal splits that
/// name again to land in exactly one ledger.
///
/// The bundled default harness's ids stay bare, so a Mac metering only that
/// one publishes and dismisses exactly the ids it always did. Ledger ids
/// themselves never contain a colon (`reset|…`, `outage|…`, `profile|…`).
public enum NoticeRouting {
    public static func qualify(_ id: String, providerID: String) -> String {
        providerID == HarnessResolution.bundledProviderID ? id : "\(providerID):\(id)"
    }

    /// The harness a notice id belongs to, and its id inside that ledger.
    /// Anything unprefixed is the bundled harness's — which is what an older
    /// face, and every id written before this version, sends.
    public static func split(_ qualified: String) -> (providerID: String, id: String) {
        if let colon = qualified.firstIndex(of: ":") {
            let prefix = String(qualified[..<colon])
            if !prefix.isEmpty, !prefix.contains("|"),
               prefix != HarnessResolution.bundledProviderID {
                return (prefix, String(qualified[qualified.index(after: colon)...]))
            }
        }
        return (HarnessResolution.bundledProviderID, qualified)
    }
}
