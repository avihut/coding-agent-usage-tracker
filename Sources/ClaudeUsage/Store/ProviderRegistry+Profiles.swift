import AppKit
import Foundation
import UsageCore

/// The registry's account-editing half: enrolling a home, removing one,
/// dismissing a discovery, the per-account switches Settings shows, and the
/// discovery pass behind the "Found" rows. Split from `ProviderRegistry` at
/// the house rule (a file past ~600 lines splits at a whole-type seam) when
/// harnesses landed — the type above owns the role, the faces and focus;
/// this half owns the edits.
///
/// Every verb here names an account by its flat `ProfileKey` and resolves it
/// to the (harness, storage id) pair its record is stored under: several
/// harnesses' standard accounts are all called `default` on disk.
@MainActor
extension ProviderRegistry {

    func enroll(home: URL, providerID: String, nickname: String? = nil) {
        let provider = providers.first { $0.id == providerID } ?? providers[0]
        guard provider.supportsMultipleHomes, let standard = provider.homeDirectory else { return }
        let id = ProfileID.forHome(home, standard: standard)
        var stored = ProfileStore.load(from: .standard)
        if let index = stored.firstIndex(where: { $0.id == id && $0.providerID == provider.id }) {
            // A dismissed discovery, adopted after all.
            let old = stored[index]
            stored[index] = Profile(
                id: id, providerID: provider.id, home: home, nickname: nickname ?? old.nickname,
                monogram: old.monogram, enabled: true, showInMenuBar: true, order: old.order,
                addedAt: Date(), ignoredIdentityKey: nil)
        } else {
            let order = (stored.filter { $0.providerID == provider.id }.map(\.order).max() ?? 0) + 1
            stored.append(Profile(
                id: id, providerID: provider.id, home: home, nickname: nickname, order: order,
                addedAt: Date()))
        }
        ProfileStore.save(stored, to: .standard)
        profilesChanged()
    }

    /// The record a face names — faces speak in flat keys, records are
    /// (harness, storage id) pairs.
    func record(for key: String) -> Profile? { profiles.first { $0.key == key } }

    /// Removes the record; `deletingData` also removes THIS APP's scoped
    /// directories for the profile — never anything inside the home.
    func remove(id key: String, deletingData: Bool) {
        guard let record = record(for: key), !record.isDefault else { return }
        var stored = ProfileStore.load(from: .standard)
        stored.removeAll { $0.id == record.id && $0.providerID == record.providerID }
        ProfileStore.save(stored, to: .standard)
        if deletingData {
            for directory in [
                StorageScope.supportDirectory(
                    bundleID: bundleID, providerID: record.providerID, profileID: record.id),
                StorageScope.cachesDirectory(
                    bundleID: bundleID, providerID: record.providerID, profileID: record.id),
            ] {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        profilesChanged()
    }

    /// "Not now" on a discovered home: remembered as a record carrying the
    /// sign-in it holds TODAY, so the offer stays silent until that
    /// changes — never a permanent silence (D2).
    func dismissDiscovered(_ home: DiscoveredHome, providerID: String) {
        var stored = ProfileStore.load(from: .standard)
        stored.removeAll { $0.id == home.profileID && $0.providerID == providerID }
        stored.append(Profile(
            id: home.profileID, providerID: providerID, home: home.home, enabled: false,
            addedAt: Date(), ignoredIdentityKey: home.identity?.key ?? ""))
        ProfileStore.save(stored, to: .standard)
        discoveredByHarness[providerID]?.removeAll { $0.profileID == home.profileID }
        profilesChanged()
    }

    func setProfileEnabled(id: String, enabled: Bool) {
        edit(id) { $0.enabled = enabled }
    }

    func setShowInMenuBar(id: String, shown: Bool) {
        edit(id) { $0.showInMenuBar = shown }
    }

    func setMenuBarForm(id: String, form: MenuBarForm) {
        edit(id) { $0.menuBarForm = form }
    }

    /// The account's own element list (0.98.0) — what its cell holds when
    /// the bar draws each account its own way.
    func setMenuBarElements(id: String, elements: [MenuBarElement]) {
        edit(id) { $0.menuBarElements = MenuBarLayout.normalized(elements) }
    }

    func setOwnMenuBarItem(id: String, own: Bool) {
        edit(id) { $0.ownMenuBarItem = own }
    }

    /// The bar's (and the strip's) order: `ids` in the order wanted; any
    /// enrolled profile not named keeps its place after them.
    func reorder(_ ids: [String]) {
        let rest = profiles.filter { $0.isEnrolled && !ids.contains($0.key) }.map(\.key)
        let order = ids + rest
        editAll { profile in
            if let index = order.firstIndex(of: profile.key) { profile.order = index }
        }
    }

    func rename(id: String, nickname: String?) {
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        edit(id) { $0.nickname = (trimmed?.isEmpty ?? true) ? nil : trimmed }
    }

    private func edit(_ key: String, _ body: (inout Profile) -> Void) {
        guard let record = record(for: key) else { return }
        var stored = ProfileStore.load(from: .standard)
        if let index = stored.firstIndex(where: {
            $0.id == record.id && $0.providerID == record.providerID
        }) {
            body(&stored[index])
        } else {
            var copy = record
            body(&copy)
            stored.append(copy)
        }
        ProfileStore.save(stored, to: .standard)
        profilesChanged()
    }

    /// One edit over every enrolled record of every harness — an implicit
    /// default gets a stored record the moment it differs.
    private func editAll(_ body: (inout Profile) -> Void) {
        var stored = ProfileStore.load(from: .standard)
        for record in profiles where record.isEnrolled {
            if let index = stored.firstIndex(where: {
                $0.id == record.id && $0.providerID == record.providerID
            }) {
                body(&stored[index])
            } else {
                var copy = record
                body(&copy)
                stored.append(copy)
            }
        }
        ProfileStore.save(stored, to: .standard)
        profilesChanged()
    }

    /// Re-reads the store, tells the host (or the daemon), and rebuilds
    /// the faces.
    private func profilesChanged() {
        loadProfiles()
        switch role {
        case .hosting(let host): host.reloadProfiles()
        case .client(let feed): feed.send(.profilesChanged)
        }
        syncStores()
        onProfilesChange?()
    }

    /// Homes found beside one harness's standard one — the Settings card's
    /// "Found" rows.
    func discoveredHomes(ofHarness providerID: String) -> [DiscoveredHome] {
        discoveredByHarness[providerID] ?? []
    }

    /// Looks for homes beside each harness's standard one (read-only). A
    /// hosting process already has the host's lists.
    func discover() {
        if case .hosting(let host) = role {
            discoveredByHarness = host.discoveredByHarness
            return
        }
        let candidates = providers.filter(\.supportsMultipleHomes)
        let known = profiles
        let bundleID = bundleID
        Task.detached(priority: .utility) { [weak self] in
            var found: [String: [DiscoveredHome]] = [:]
            for provider in candidates {
                let homes = ProfileDiscovery.discover(
                    provider: provider, known: known, bundleID: bundleID, now: Date())
                if !homes.isEmpty { found[provider.id] = homes }
            }
            await MainActor.run { [weak self] in self?.discoveredByHarness = found }
        }
    }

    /// The `--fake-profiles` hatch: a synthetic profile with a fixed face,
    /// so the strip, the cells, and the Settings rows can be verified on a
    /// one-account machine.
    func installFakeProfile(_ profile: Profile, store: UsageStore) {
        profiles.removeAll { $0.key == profile.key }
        profiles.append(profile)
        stores[profile.key] = store
        syncFacts()
        onProfilesChange?()
    }

    /// Every metered harness's records. The roster is the host's own rule —
    /// present harnesses, their stored accounts, the hidden ones still
    /// metered — reused here so a client-mode face lists exactly what the
    /// daemon meters.
}
