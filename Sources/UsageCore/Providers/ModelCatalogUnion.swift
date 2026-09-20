import Foundation

/// One catalog spanning every metered harness (v0.101.0). Up to 0.100.x
/// exactly one provider was active, so `ModelNames.catalog` could BE that
/// provider's catalog; with Claude and Codex metered side by side a grid can
/// hold both vendors' ids at once, and a name must come from the vendor whose
/// grammar the id belongs to — "gpt-5.2-codex" read through Claude's grammar
/// is its own raw id.
///
/// Dispatch is by `ModelCatalog.claims`, in the catalogs' order with the
/// BUNDLED provider first: every answer a Claude-only Mac ever got is the
/// answer it still gets, which is what keeps the persisted, family-keyed
/// `ModelColorLedger` from re-keying (pinned by ModelCatalogUnionTests).
/// An id nobody claims falls back to the first catalog, exactly as it
/// resolved when that catalog was the only one installed.
extension ModelCatalog {
    /// Family ranks are per vendor and collide across them (Claude's Opus and
    /// Codex's GPT are both 1), so each catalog's ranks are offset into their
    /// own band: families group by vendor in the catalogs' order, and the
    /// first catalog's own ranks are untouched.
    static let rankStride = 10

    /// Nothing → the vendor-neutral fallback; one → itself, unchanged.
    public static func union(_ catalogs: [ModelCatalog]) -> ModelCatalog {
        guard let first = catalogs.first else { return .generic }
        guard catalogs.count > 1 else { return first }
        let stride = rankStride
        let unclaimedBase = catalogs.count * stride
        return ModelCatalog(
            displayName: { id in Self.owner(of: id, in: catalogs, else: first).displayName(id) },
            familyName: { id in Self.owner(of: id, in: catalogs, else: first).familyName(id) },
            familyRank: { family in
                guard let index = catalogs.firstIndex(where: { $0.claimsFamily(family) }) else {
                    // A family no vendor names sorts after every band, and
                    // ties there break alphabetically at the call site.
                    return unclaimedBase + first.familyRank(family)
                }
                return index * stride + catalogs[index].familyRank(family)
            },
            claims: { id in catalogs.contains { $0.claims(id) } },
            claimsFamily: { family in catalogs.contains { $0.claimsFamily(family) } })
    }

    /// Every harness this build can meter, bundled provider first.
    public static func union(of providers: [any UsageProvider]) -> ModelCatalog {
        union(providers.map(\.modelCatalog))
    }

    private static func owner(
        of id: String, in catalogs: [ModelCatalog], else fallback: ModelCatalog
    ) -> ModelCatalog {
        catalogs.first { $0.claims(id) } ?? fallback
    }
}
