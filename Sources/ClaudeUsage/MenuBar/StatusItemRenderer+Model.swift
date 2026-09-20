import AppKit
import UsageCore

/// What the bar shows, as a value: one `Group` per HARNESS (its mark, its
/// accent, its vendor-level alarms) and one `Cell` per account inside it,
/// plus the two factories that build it — from one account's display state,
/// or from the digest's own cells.
///
/// Split from `StatusItemRenderer.swift` at the house rule when harness
/// groups landed (0.101.0). The one-harness readings (`glyph`, `cells`,
/// `incident`, `indicator`) are forwards to the first group, which is why
/// every pre-0.101 caller, every snapshot case and the Settings preview kept
/// working untouched.
///
/// Everything here is `Equatable` over VALUES — no `NSColor` — because the
/// controller skips a redraw when the model compares equal to what it drew,
/// and a freshly-built dynamic color never compares equal.
extension StatusItemRenderer {
    struct Model: Equatable {
        /// One HARNESS's block (0.101.0): its own mark, its own accent, its
        /// own vendor-level alarms, and its accounts' cells. A bar metering
        /// one harness holds exactly one group and takes the same code path
        /// it always took, which is what keeps every pinned pixel.
        struct Group: Equatable {
            let harnessID: String
            /// The vendor's mark ahead of this block's cells.
            let glyph: String
            /// The brand accent that tints the mark. Kept as `RGBColor`, not
            /// `NSColor`: the controller skips a redraw when two models
            /// compare equal, and a freshly-built dynamic color never does.
            var accent: UsageCore.RGBColor = HarnessStyle.bundled.accent
            /// THIS vendor's health, when an incident is running: its glyph
            /// rides a capsule in this color instead of standing alone. Nil
            /// whenever the service is fine, unknown, or under maintenance —
            /// the menu bar alarms for incidents only (decision D2).
            var incident: ServiceStatusCard.Indicator?
            /// One of this harness's notices is pending with no menu bar
            /// surface of its own: a white dot at its glyph's corner, no
            /// count (the panel counts). An active outage alone lights
            /// nothing — the capsule already says it — and the digest decides
            /// that (`NoticesCard.indicator`), so the TUI's header dot and
            /// this one can't disagree.
            var indicator = false
            let cells: [Cell]

            /// Every cell stale, or none at all: the mark greys too.
            var stale: Bool { cells.allSatisfy(\.stale) }

            func replacingCells(_ cells: [Cell]) -> Group {
                Group(
                    harnessID: harnessID, glyph: glyph, accent: accent, incident: incident,
                    indicator: indicator, cells: cells)
            }

            /// Its alarms stripped — for the second item that carries the
            /// same harness, since one incident repeated per item would read
            /// as several outages.
            var quieted: Group {
                Group(
                    harnessID: harnessID, glyph: glyph, accent: accent, incident: nil,
                    indicator: false, cells: cells)
            }
        }

        /// The harnesses on the bar, in the roster's order.
        let groups: [Group]
        /// The focused cell draws as today's digits whatever its form.
        let expandsFocus: Bool
        /// The clock a countdown is phrased against, FLOORED TO THE MINUTE
        /// (0.98.0): the text changes once a minute, so the model — which
        /// the controller compares to skip a redraw — changes once a minute
        /// too, on the tick that redraws it.
        var now: Date = Model.minute(Date())
        /// Preview only: an element that would compose nothing right now
        /// (a runs-out element while every forecast is clean) draws as a
        /// dashed placeholder, so a drop never looks like it failed. The
        /// bar itself NEVER sets this.
        var ghosts = false

        init(
            groups: [Group], expandsFocus: Bool = true, now: Date = Model.minute(Date()),
            ghosts: Bool = false
        ) {
            self.groups = groups
            self.expandsFocus = expandsFocus
            self.now = Model.minute(now)
            self.ghosts = ghosts
        }

        /// The one-harness shape — every caller that meters one vendor builds
        /// this, and it composes exactly what it always did.
        init(
            glyph: String, accent: UsageCore.RGBColor = HarnessStyle.bundled.accent,
            incident: ServiceStatusCard.Indicator? = nil, indicator: Bool = false,
            cells: [Cell], expandsFocus: Bool = true, now: Date = Model.minute(Date()),
            ghosts: Bool = false,
            harnessID: String = HarnessResolution.bundledProviderID
        ) {
            self.init(
                groups: [Group(
                    harnessID: harnessID, glyph: glyph, accent: accent, incident: incident,
                    indicator: indicator, cells: cells)],
                expandsFocus: expandsFocus, now: now, ghosts: ghosts)
        }

        static func minute(_ date: Date) -> Date {
            Date(timeIntervalSinceReferenceDate: floor(date.timeIntervalSinceReferenceDate / 60) * 60)
        }

        /// The one-account shape — today's model, unchanged for every
        /// caller that meters one thing. A form other than the standard
        /// one, or focus not expanded, is the person's own choice for
        /// their one account and draws as such.
        init(
            segments: [MenuBarSegment]?, stale: Bool, glyph: String,
            accent: UsageCore.RGBColor = HarnessStyle.bundled.accent,
            incident: ServiceStatusCard.Indicator? = nil, indicator: Bool = false,
            form: MenuBarForm = .standard, expandsFocus: Bool = true,
            elements: [MenuBarElement] = MenuBarLayout.standard, now: Date = Model.minute(Date())
        ) {
            self.init(
                glyph: glyph, accent: accent, incident: incident, indicator: indicator,
                cells: [Cell(
                    profileID: Profile.defaultID, monogram: "", segments: segments, stale: stale,
                    focused: true, form: form, elements: elements)],
                expandsFocus: expandsFocus, now: now)
        }

        // The one-harness readings every pre-0.101 caller and test still
        // uses, forwarded to the first group so nothing had to be rewritten
        // for the groups to land.
        var glyph: String { groups.first?.glyph ?? "" }
        var accent: UsageCore.RGBColor { groups.first?.accent ?? HarnessStyle.bundled.accent }
        var incident: ServiceStatusCard.Indicator? { groups.first?.incident }
        var indicator: Bool { groups.first?.indicator ?? false }
        /// Every harness's cells in bar order.
        var cells: [Cell] { groups.flatMap(\.cells) }
        /// The first cell's triple — the one-account reading.
        var segments: [MenuBarSegment]? { cells.first?.segments }
        /// Every cell stale (or no cell at all): the glyphs grey too.
        var stale: Bool { cells.allSatisfy(\.stale) }

        func replacingGroups(_ groups: [Group]) -> Model {
            Model(groups: groups, expandsFocus: expandsFocus, now: now, ghosts: ghosts)
        }
    }

    static func model(
        for state: DisplayState, predictions: [String: UsagePrediction] = [:],
        glyph: String = "✳︎", accent: UsageCore.RGBColor = HarnessStyle.bundled.accent,
        serviceStatus: ServiceStatusCard? = nil,
        notices: NoticesCard? = nil, form: MenuBarForm = .standard, expandsFocus: Bool = true,
        elements: [MenuBarElement] = MenuBarLayout.standard, now: Date = Date()
    ) -> Model {
        // Which impacts are loud enough to badge is decision D2, and it lives
        // on the card so the TUI's rungs and this badge can't drift apart.
        let alarming = serviceStatus?.alarmingImpact
        let indicator = notices?.indicator ?? false
        guard let snapshot = state.snapshot else {
            return Model(
                segments: nil, stale: true, glyph: glyph, accent: accent, incident: alarming,
                indicator: indicator, form: form, expandsFocus: expandsFocus,
                elements: elements, now: now)
        }
        return Model(
            segments: UsageFormatting.menuBarSegments(
                from: snapshot.meters, predictions: predictions),
            stale: state.isStale,
            glyph: glyph,
            accent: accent,
            incident: alarming,
            indicator: indicator,
            form: form,
            expandsFocus: expandsFocus,
            elements: elements,
            now: now
        )
    }

    /// The several-accounts shape, from the digest's own cells (the WRITER
    /// decides which accounts show and with which digits — so the app's
    /// bar and the TUI's header can't disagree) in the order given, dressed
    /// by each account's own style (the app's record, not the digest's).
    static func model(
        cells: [MenuBarCell], focusedID: String?, styles: [String: CellStyle], glyph: String,
        accent: UsageCore.RGBColor = HarnessStyle.bundled.accent,
        expandsFocus: Bool, serviceStatus: ServiceStatusCard? = nil, notices: NoticesCard? = nil,
        now: Date = Date()
    ) -> Model {
        Model(
            glyph: glyph, accent: accent, incident: serviceStatus?.alarmingImpact,
            indicator: notices?.indicator ?? false,
            cells: cells.map { cell in
                let style = styles[cell.profile] ?? CellStyle()
                return Cell(
                    profileID: cell.profile, monogram: cell.monogram,
                    segments: cell.segments.isEmpty ? nil : cell.segments.map(MenuBarSegment.init),
                    stale: cell.stale, focused: cell.profile == focusedID,
                    form: style.form, ownItem: style.ownItem, elements: style.elements)
            },
            expandsFocus: expandsFocus, now: now)
    }
}
