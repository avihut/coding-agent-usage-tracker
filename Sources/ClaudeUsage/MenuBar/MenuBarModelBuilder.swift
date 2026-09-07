import Foundation
import UsageCore

/// The ONE answer to "what does the bar show right now": the status item
/// draws this model and the Settings preview draws the same one, so the
/// preview can never differ from the bar (0.97.0, user-directed — a
/// preview that reacts to every change, the iStat Menus way).
@MainActor
enum MenuBarModelBuilder {
    /// `order` is a draft order of profile ids — the preview's drag in
    /// progress — that stands in for the records' own until it lands.
    static func model(
        registry: ProviderRegistry, expandsFocus: Bool, order: [String]? = nil
    ) -> StatusItemRenderer.Model {
        let store = registry.focusedStore
        let cells = registry.menuBarCells
        // One account (or a writer that meters one): today's model straight
        // off the focused store — a one-account Mac keeps its exact
        // pre-0.96 data path, not just its pixels — in that account's own
        // form. Its letter would label nothing, so it has none.
        guard cells.count > 1 else {
            return StatusItemRenderer.model(
                for: store.state, predictions: store.predictions,
                glyph: store.provider.menuBarGlyph,
                serviceStatus: store.serviceStatus, notices: store.notices,
                form: registry.focusedProfile?.menuBarForm ?? .standard,
                expandsFocus: expandsFocus)
        }
        var styles: [String: StatusItemRenderer.CellStyle] = [:]
        for profile in registry.profiles {
            styles[profile.id] = StatusItemRenderer.CellStyle(
                form: profile.menuBarForm, ownItem: profile.ownMenuBarItem)
        }
        // The app's own order, applied here rather than waited for from the
        // digest, so a reorder shows the instant it is made.
        let ranks = Dictionary(
            (order ?? registry.barProfiles.map(\.id)).enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first })
        let ordered = cells.enumerated().sorted { a, b in
            let ra = ranks[a.element.profile] ?? Int.max
            let rb = ranks[b.element.profile] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        return StatusItemRenderer.model(
            cells: ordered, focusedID: registry.focusedID, styles: styles,
            glyph: store.provider.menuBarGlyph, expandsFocus: expandsFocus,
            serviceStatus: store.serviceStatus, notices: store.notices)
    }

    /// One account's cell with its live numbers, for the form thumbnails:
    /// the digest's cell when the writer published one, else the face's
    /// own reading. The letter shows only when the bar would show it.
    static func sampleCell(for profile: Profile?, registry: ProviderRegistry) -> StatusItemRenderer.Cell {
        let id = profile?.id ?? Profile.defaultID
        let monogram = registry.barProfiles.count > 1
            ? profile.map { registry.monogram(for: $0) } ?? "" : ""
        if let cell = registry.menuBarCells.first(where: { $0.profile == id }) {
            return StatusItemRenderer.Cell(
                profileID: id, monogram: monogram,
                segments: cell.segments.isEmpty ? nil : cell.segments.map(MenuBarSegment.init),
                stale: cell.stale, focused: false)
        }
        let store = registry.store(for: id) ?? registry.focusedStore
        let segments = store.state.snapshot.map {
            UsageFormatting.menuBarSegments(from: $0.meters, predictions: store.predictions)
        }
        return StatusItemRenderer.Cell(
            profileID: id, monogram: monogram, segments: segments,
            stale: store.state.snapshot == nil || store.state.isStale, focused: false)
    }
}
