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
    /// `elements` likewise stands in for one account's element list while
    /// a drag on the preview is in flight (nil id = every cell, the
    /// uniform arrangement). `simulate` (preview only) dresses every cell
    /// as if its session limit were about to run out, so the person can
    /// see the conditional element they placed; `ghosts` (preview only)
    /// draws an element with nothing to say as a placeholder.
    static func model(
        registry: ProviderRegistry, prefs: MenuBarPreferences.Values, order: [String]? = nil,
        elements draft: (id: String?, elements: [MenuBarElement])? = nil,
        simulate: Bool = false, ghosts: Bool = false, now: Date = Date()
    ) -> StatusItemRenderer.Model {
        var model = build(registry: registry, prefs: prefs, order: order, draft: draft, now: now)
        if simulate { model = simulatingCrossing(model) }
        model.ghosts = ghosts
        return model
    }

    private static func elements(
        for profile: Profile?, prefs: MenuBarPreferences.Values,
        draft: (id: String?, elements: [MenuBarElement])?
    ) -> [MenuBarElement] {
        if let draft, draft.id == nil || draft.id == profile?.id { return draft.elements }
        return prefs.elements(for: profile)
    }

    private static func build(
        registry: ProviderRegistry, prefs: MenuBarPreferences.Values, order: [String]?,
        draft: (id: String?, elements: [MenuBarElement])?, now: Date
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
                form: prefs.form(for: registry.focusedProfile),
                expandsFocus: prefs.expandsFocus,
                elements: elements(for: registry.focusedProfile, prefs: prefs, draft: draft),
                now: now)
        }
        var styles: [String: StatusItemRenderer.CellStyle] = [:]
        for profile in registry.profiles {
            styles[profile.id] = StatusItemRenderer.CellStyle(
                form: prefs.form(for: profile), ownItem: profile.ownMenuBarItem,
                elements: elements(for: profile, prefs: prefs, draft: draft))
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
            glyph: store.provider.menuBarGlyph, expandsFocus: prefs.expandsFocus,
            serviceStatus: store.serviceStatus, notices: store.notices, now: now)
    }

    /// The same bar with every account's session limit forecast to run out
    /// in half an hour — the Settings "as if" switch, the only way to see
    /// a conditional element on a quiet day. Synthetic numbers on purpose
    /// (82%, the ramp's top): a live reading would differ between two
    /// looks on data alone.
    static func simulatingCrossing(_ model: StatusItemRenderer.Model) -> StatusItemRenderer.Model {
        let now = model.now
        let cells = model.cells.map { cell -> StatusItemRenderer.Cell in
            var segments = cell.segments ?? [
                MenuBarSegment(tag: "S", percent: nil, level: .normal),
                MenuBarSegment(tag: "W", percent: nil, level: .normal),
                MenuBarSegment(tag: "M", percent: nil, level: .normal),
            ]
            if segments.isEmpty { segments = [MenuBarSegment(tag: "S", percent: nil, level: .normal)] }
            let session = segments[0]
            segments[0] = MenuBarSegment(
                tag: session.tag, percent: 82, level: .critical, severity: 1,
                exhaustsAt: now.addingTimeInterval(31 * 60),
                resetsAt: now.addingTimeInterval(2 * 3600 + 10 * 60))
            return StatusItemRenderer.Cell(
                profileID: cell.profileID, monogram: cell.monogram, segments: segments,
                stale: false, focused: cell.focused, form: cell.form, ownItem: cell.ownItem,
                elements: cell.elements)
        }
        return StatusItemRenderer.Model(
            glyph: model.glyph, incident: model.incident, indicator: model.indicator,
            cells: cells, expandsFocus: model.expandsFocus, now: now, ghosts: model.ghosts)
    }

    /// The palette's picture of the "Runs out" element on its own: the
    /// account's session tag, half an hour from the limit.
    static func runsOutSample(for profile: Profile?, registry: ProviderRegistry, scope: RunsOutScope) -> StatusItemRenderer.Cell {
        let live = sampleCell(for: profile, registry: registry)
        let simulated = simulatingCrossing(StatusItemRenderer.Model(glyph: "", cells: [live]))
        var cell = simulated.cells[0]
        cell = StatusItemRenderer.Cell(
            profileID: cell.profileID, monogram: "", segments: cell.segments, stale: false,
            focused: false, form: cell.form, ownItem: false, elements: [.runsOut(scope)])
        return cell
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
