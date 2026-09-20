import AppKit
import SwiftUI
import UsageCore

/// The `--snapshot <dir>` hatch: renders the surfaces a live popover can't be
/// caught on (any real click dismisses the panel, and a user at the machine is
/// always clicking) headlessly to PNGs, then quits. Split out of
/// `ClaudeUsageApp.swift` at the house rule when harness cases landed.
///
/// The `statusitem-*.png` set is the renderer's regression test: fixed models,
/// pinned clock, both grounds, `cmp`-ed against the previous release's files,
/// with the hit-rect sidecar beside them. New cases are APPENDED — the gate
/// compares the old sidecar as a PREFIX of the new one.
@MainActor
extension AppDelegate {
    static func writeSnapshots(registry: ProviderRegistry, to directory: URL) {
        let store = registry.focusedStore
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writeStatusItemSnapshots(to: directory)
        func write(_ renderer: ImageRenderer<some View>, _ name: String) {
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { return }
            try? png.write(to: directory.appending(path: name))
        }
        // The Notifications section on its own: ImageRenderer leaves a
        // ScrollView's content blank, so the panel can't be rendered whole.
        if let notices = registry.pendingNotices, !notices.items.isEmpty {
            let section = NoticesSection(
                card: notices, style: store.style, onDismiss: { _ in }, onDismissAll: {},
                canOpen: { store.provider.noticeDestination(for: $0) != nil }, onOpen: { _ in })
            write(ImageRenderer(content: section.padding(14).frame(width: 360)), "notices.png")
        }
        // The account strip, both selector forms — the panel can't be
        // rendered whole (ImageRenderer leaves a ScrollView's content
        // blank), and with `--fake-profiles` this is the only way to see
        // the multi-account panel head on a one-account Mac.
        if registry.shownProfiles.count > 1 {
            for form in [PanelAccountForm.stripRows, .chips] {
                let strip = AccountStrip(
                    registry: registry, form: form, onSetForm: { _ in }, onFocus: { _ in })
                write(
                    ImageRenderer(content: strip.padding(14).frame(width: 360)),
                    form == .chips ? "strip-chips.png" : "strip.png")
            }
        }
        // The harness surfaces (0.101.0): the strip with its headings, the
        // Harnesses card, and the rates grouped per harness. Rendered whether
        // or not this Mac has two accounts — the strip draws whenever more
        // than one row shows, which several harnesses alone produce.
        write(
            ImageRenderer(content: HarnessesCard(registry: registry)
                .padding(14).frame(width: 520)
                .background(Color(nsColor: .windowBackgroundColor))),
            "harnesses-card.png")
        write(
            ImageRenderer(content: CostRatesCard(registry: registry)
                .padding(14).frame(width: 560)
                .background(Color(nsColor: .windowBackgroundColor))),
            "rates-by-harness.png")
        // The Menu bar card's live preview and one account's form picker —
        // the preview is an NSView (drawn by itself: ImageRenderer would
        // show a placeholder), the picker plain SwiftUI.
        let prefs = MenuBarPreferences.current()
        let preview = MenuBarPreviewView()
        preview.items = StatusItemRenderer.itemModels(
            for: MenuBarModelBuilder.model(registry: registry, prefs: prefs))
        preview.canDrag = registry.barProfiles.count > 1
        if let rep = preview.snapshot() {
            try? rep.representation(using: .png, properties: [:])?
                .write(to: directory.appending(path: "menubar-preview.png"))
        }
        let picker = MenuBarFormPicker(
            cell: MenuBarModelBuilder.sampleCell(for: registry.focusedProfile, registry: registry),
            selection: prefs.form(for: registry.focusedProfile), onSelect: { _ in },
            style: store.style)
        write(ImageRenderer(content: picker.padding(14).background(Color(nsColor: .windowBackgroundColor))), "form-picker.png")
        // Settings → Menu bar's per-account rows, one per enrolled account
        // of EVERY harness: each must name its own harness and account.
        let rows = VStack(alignment: .leading, spacing: 12) {
            ForEach(registry.profiles.filter(\.isEnrolled), id: \.key) { profile in
                AccountInBarRow(registry: registry, profile: profile, uniform: true)
            }
        }
        write(
            ImageRenderer(content: rows.frame(width: 460, alignment: .leading).padding(14)
                .background(Color(nsColor: .windowBackgroundColor))),
            "accounts-in-bar.png")
        // Settings → Accounts: a card per metered harness, a one-home
        // harness's single account included.
        let cards = VStack(alignment: .leading, spacing: 16) {
            ForEach(registry.accountHarnesses, id: \.id) { harness in
                AccountsCard(registry: registry, harnessID: harness.id)
            }
        }
        write(
            ImageRenderer(content: cards.frame(width: 560, alignment: .leading).padding(14)
                .background(Color(nsColor: .windowBackgroundColor))),
            "accounts-cards.png")
        // The "Runs out" element (0.98.0) placed after the meters, three
        // ways: as the preview ghosts it on a quiet day, as the "as if"
        // switch dresses it, and the palette tile with its condition.
        let arranged = [MenuBarElement.meters, .runsOut(.earliest)]
        for (name, simulate) in [("menubar-preview-ghost.png", false), ("menubar-preview-forecast.png", true)] {
            let staged = MenuBarPreviewView()
            staged.items = StatusItemRenderer.itemModels(
                for: MenuBarModelBuilder.model(
                    registry: registry, prefs: prefs, elements: (nil, arranged),
                    simulate: simulate, ghosts: true))
            if let rep = staged.snapshot() {
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: directory.appending(path: name))
            }
        }
        let palette = MenuBarElementPalette(
            registry: registry, profile: registry.focusedProfile, elements: arranged, onChange: { _ in })
        write(
            ImageRenderer(content: palette.padding(14).frame(width: 520).background(Color(nsColor: .windowBackgroundColor))),
            "element-palette.png")
        // The weekly meter's card, lit at the first pending reset notice
        // exactly as a click on that notice would open it.
        if let meters = store.state.snapshot?.meters,
           let meter = meters.first(where: { $0.rank == 1 }) ?? meters.first {
            let reset = store.notices?.items.first { $0.kind == "reset" }?.occurredAt
            let card = MeterHistoryView(
                meter: meter, samples: store.samples, timeline: store.tokenTimeline,
                pricing: store.pricing, prediction: store.predictions[meter.label],
                overshoot: store.forecastOvershoots[meter.label],
                outcomes: store.windowOutcomes, agentName: store.provider.agentName,
                providerID: store.provider.id, style: store.style, highlightReset: reset,
                outages: store.outages)
            write(ImageRenderer(content: card), "meter.png")
        }
        // Every OTHER shown account's longest limit, one card each (0.101.0):
        // a harness that isn't focused had no picture at all, which is how a
        // renamed Codex meter lost its percent line unseen.
        for profile in registry.shownProfiles where profile.key != registry.focusedID {
            guard let other = registry.store(for: profile.key),
                  let meters = other.state.snapshot?.meters,
                  let meter = meters.first(where: { $0.rank == 1 }) ?? meters.first
            else { continue }
            let card = MeterHistoryView(
                meter: meter, samples: other.samples, timeline: other.tokenTimeline,
                pricing: other.pricing, prediction: other.predictions[meter.label],
                overshoot: other.forecastOvershoots[meter.label],
                outcomes: other.windowOutcomes, agentName: other.provider.agentName,
                providerID: other.profile.scopeKey, style: other.style, outages: other.outages)
            write(ImageRenderer(content: card), "meter-\(profile.key).png")
        }
        // The menu bar's hover card while an incident is open: the session
        // meter's card under the banner, at its NATURAL size — no frame, the
        // same measure the hover popover's `.preferredContentSize` sizing
        // takes, so text that widens the card shows as a wide PNG. Needs an
        // open incident: the live one, or `--fake-status major`.
        if let incident = store.serviceStatus, incident.hasIncident,
           let meters = store.state.snapshot?.meters,
           let meter = meters.first(where: { $0.rank == 0 }) ?? meters.first {
            let card = MeterHistoryView(
                meter: meter, samples: store.samples, timeline: store.tokenTimeline,
                pricing: store.pricing, prediction: store.predictions[meter.label],
                overshoot: store.forecastOvershoots[meter.label],
                outcomes: store.windowOutcomes, agentName: store.provider.agentName,
                providerID: store.profile.scopeKey, style: store.style, outages: store.outages)
            write(ImageRenderer(content: HoverPopoverContent(card: incident, history: card)), "hover.png")
        }
        // The weekly meter's week-span audit chart — the other face of the
        // outage floor. This span rather than today's drill because a
        // resolved outage sits in the past week where it's visible, while
        // anything dated "today" may still be in the future at render time.
        if let meters = store.state.snapshot?.meters,
           let meter = meters.first(where: { $0.rank == 1 }) ?? meters.first,
           let window = meter.limitWindow {
            let now = Date()
            // A trailing window rather than a calendar week: it always holds
            // the fake's resolved outage (three days back) whatever weekday
            // the render lands on, and reaches a few hours past now so the
            // live now rule shows too.
            let span = DateInterval(
                start: now.addingTimeInterval(-5 * 86400), end: now.addingTimeInterval(6 * 3600))
            let chart = AuditWindowChart(
                model: AuditWindow.build(
                    domain: span, meterLabel: meter.label, window: window,
                    samples: store.samples, sessions: store.sessions,
                    outcomes: store.windowOutcomes, outages: store.outages, now: now),
                domain: span, window: window, style: store.style,
                timeline: store.tokenTimeline, plotHeight: 114)
            write(ImageRenderer(content: chart.padding(14).frame(width: 360)), "audit.png")
        }
    }

    /// The menu bar item over FIXED models — one PNG per dressing the
    /// renderer knows (plain digits, the ramp dot, the badge, stale, an
    /// incident capsule with the notice dot, no data) at 2× over a dark
    /// ground. Synthetic on purpose: a render of the live digits would
    /// differ between two runs on data alone, and these exist to be
    /// `cmp`-ed across renderer changes — the single-cell bar must stay
    /// byte-identical when the multi-account cells land.
    static func writeStatusItemSnapshots(to directory: URL) {
        func segment(_ tag: String, _ percent: Int, _ level: DisplayLevel, _ severity: Double?) -> MenuBarSegment {
            MenuBarSegment(tag: tag, percent: percent, level: level, severity: severity)
        }
        let clean = [
            segment("S", 42, .normal, 0), segment("W", 80, .warning, 0.55), segment("F", 25, .normal, nil),
        ]
        let alarmed = [
            segment("S", 97, .critical, 0.9), segment("W", 80, .warning, 0.55), segment("F", 25, .normal, nil),
        ]
        let cases: [(String, StatusItemRenderer.Model)] = [
            ("clean", .init(segments: clean, stale: false, glyph: "✳︎")),
            ("badge", .init(segments: alarmed, stale: false, glyph: "✳︎")),
            ("stale", .init(segments: clean, stale: true, glyph: "✳︎")),
            ("incident", .init(segments: clean, stale: false, glyph: "✳︎", incident: .major, indicator: true)),
            ("empty", .init(segments: nil, stale: true, glyph: "✳︎")),
        ]
        // Two accounts, one per style: work quiet across all three meters,
        // personal with its weekly meter under watch and NO scoped meter
        // (the absent bar). Distinct numbers so a style's cells can be told
        // apart by eye; `clean`/`alarmed` above stay as they are, since the
        // single-cell PNGs are `cmp`-ed against the pre-0.96 baseline.
        let work = StatusItemRenderer.Cell(
            profileID: "default", monogram: "W",
            segments: [
                segment("S", 15, .normal, 0), segment("W", 19, .normal, 0),
                segment("F", 25, .normal, 0),
            ],
            stale: false, focused: true)
        let personal = StatusItemRenderer.Cell(
            profileID: "c982130e", monogram: "P",
            segments: [segment("S", 42, .normal, 0), segment("W", 80, .warning, 0.55)],
            stale: false, focused: false)
        let alarmedCell = StatusItemRenderer.Cell(
            profileID: "c982130e", monogram: "P", segments: alarmed, stale: false, focused: false)
        func dressed(_ cell: StatusItemRenderer.Cell, _ form: MenuBarForm, own: Bool = false) -> StatusItemRenderer.Cell {
            var copy = cell
            copy.form = form
            copy.ownItem = own
            return copy
        }
        var everyCase = cases
        // Every form on both cells with focus not expanded, then the
        // default arrangement (bars, focus expanded) and a mixed one.
        for form in MenuBarForm.allCases {
            everyCase.append((
                "form-\(form.rawValue)",
                StatusItemRenderer.Model(
                    glyph: "✳︎", cells: [dressed(work, form), dressed(personal, form)],
                    expandsFocus: false)))
        }
        everyCase.append((
            "expanded-focus", StatusItemRenderer.Model(glyph: "✳︎", cells: [work, personal])))
        everyCase.append((
            "mixed",
            StatusItemRenderer.Model(
                glyph: "✳︎", cells: [dressed(work, .digits), dressed(personal, .rings)],
                expandsFocus: false)))
        everyCase.append((
            "cells-badge",
            StatusItemRenderer.Model(glyph: "✳︎", cells: [work, alarmedCell], expandsFocus: false)))
        everyCase.append((
            "cells-stale",
            StatusItemRenderer.Model(glyph: "✳︎", cells: [
                StatusItemRenderer.Cell(
                    profileID: "default", monogram: "W", segments: clean, stale: true, focused: true),
                StatusItemRenderer.Cell(
                    profileID: "c982130e", monogram: "P", segments: nil, stale: true, focused: false),
            ], expandsFocus: false)))
        // The runs-out element (0.98.0): a crossing half an hour out, the
        // scoped meter days out, a spent session counting to its reset —
        // after the meters, before them, and every limit at once. The
        // clock is pinned so the PNGs are `cmp`-able.
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let crossing = [
            MenuBarSegment(
                tag: "S", percent: 82, level: .critical, severity: 1,
                exhaustsAt: clock.addingTimeInterval(31 * 60), resetsAt: clock.addingTimeInterval(2 * 3600)),
            segment("W", 80, .warning, 0.55),
            MenuBarSegment(
                tag: "F", percent: 61, level: .normal, severity: 1,
                exhaustsAt: clock.addingTimeInterval(2 * 86400 + 3 * 3600), resetsAt: clock.addingTimeInterval(5 * 86400)),
        ]
        let spent = [
            MenuBarSegment(
                tag: "S", percent: 100, level: .critical, severity: 1,
                exhaustsAt: clock.addingTimeInterval(-600), resetsAt: clock.addingTimeInterval(2 * 3600 + 10 * 60)),
            segment("W", 80, .warning, 0.55), segment("F", 25, .normal, nil),
        ]
        for (name, segments, elements) in [
            ("runsout", crossing, [MenuBarElement.meters, .runsOut(.earliest)]),
            ("runsout-before", crossing, [.runsOut(.earliest), .meters]),
            ("runsout-each", crossing, [.meters, .runsOut(.each)]),
            ("runsout-spent", spent, [.meters, .runsOut(.earliest)]),
            ("runsout-quiet", clean, [.meters, .runsOut(.earliest)]),
        ] {
            everyCase.append((name, StatusItemRenderer.Model(
                segments: segments, stale: false, glyph: "✳︎", elements: elements, now: clock)))
        }
        // The preview's ghost for a quiet element — the bar itself never
        // draws one, so a fixed case is the one way to see it.
        var ghosted = StatusItemRenderer.Model(
            segments: clean, stale: false, glyph: "✳︎", elements: [.meters, .runsOut(.earliest)], now: clock)
        ghosted.ghosts = true
        everyCase.append(("runsout-ghost", ghosted))
        everyCase.append((
            "runsout-cells",
            StatusItemRenderer.Model(
                glyph: "✳︎",
                cells: [
                    work,
                    StatusItemRenderer.Cell(
                        profileID: "c982130e", monogram: "P", segments: crossing, stale: false,
                        focused: false, form: .bars, elements: [.meters, .runsOut(.earliest)]),
                ],
                expandsFocus: true, now: clock)))
        everyCase.append((
            "cells-incident",
            StatusItemRenderer.Model(
                glyph: "✳︎", incident: .major, indicator: true, cells: [work, personal],
                expandsFocus: false)))
        // An account in its own item draws apart from the shared one —
        // render each item the way the controller will.
        let split = StatusItemRenderer.Model(
            glyph: "✳︎", incident: .major, indicator: true,
            cells: [work, dressed(personal, .rings, own: true)])
        for item in StatusItemRenderer.itemModels(for: split) {
            everyCase.append(("item-\(item.profileID ?? "shared")", item.model))
        }
        // SEVERAL HARNESSES (0.101.0), appended last on purpose: the gate
        // compares the previous release's sidecar as a PREFIX of this one, so
        // a new case may never be interleaved with the cases above.
        //
        // Real vendors' marks and accents, so what these pin is what the bar
        // wears: Claude's ✳︎ terracotta, Codex's ⬡ green, Gemini's ✦ blue.
        let providers = HarnessResolution.standardProviders()
        func harness(
            _ id: String, _ cells: [StatusItemRenderer.Cell],
            incident: ServiceStatusCard.Indicator? = nil, indicator: Bool = false
        ) -> StatusItemRenderer.Model.Group {
            let provider = providers.first { $0.id == id } ?? providers[0]
            let style = HarnessStyle(provider)
            return StatusItemRenderer.Model.Group(
                harnessID: id, glyph: style.glyph, accent: style.accent,
                incident: incident, indicator: indicator, cells: cells)
        }
        func cell(
            _ profile: String, _ monogram: String, _ segments: [MenuBarSegment]?,
            focused: Bool = false, stale: Bool = false, form: MenuBarForm = .standard,
            own: Bool = false
        ) -> StatusItemRenderer.Cell {
            StatusItemRenderer.Cell(
                profileID: profile, monogram: monogram, segments: segments, stale: stale,
                focused: focused, form: form, ownItem: own)
        }
        let codexSegments = [
            segment("S", 35, .normal, 0), segment("W", 12, .normal, 0),
        ]
        let geminiSegments = [segment("D", 64, .warning, 0.55)]
        // Two harnesses, one account each — the shape this Mac actually has.
        // The focused harness's only cell expands to today's digits; the
        // other wears its letter, so the bar reads vendor, then account.
        let twoHarnesses = StatusItemRenderer.Model(groups: [
            harness("claude", [cell("default", "A", clean, focused: true)]),
            harness("codex", [cell("codex", "C", codexSegments)]),
        ])
        everyCase.append(("harnesses", twoHarnesses))
        // Three, the third in its own form — and a hidden harness is simply
        // absent: hiding stops the DISPLAY, never the metering, so there is
        // no greyed-out block to draw.
        everyCase.append((
            "harnesses-three",
            StatusItemRenderer.Model(groups: [
                harness("claude", [cell("default", "A", clean, focused: true)]),
                harness("codex", [cell("codex", "C", codexSegments)]),
                harness("gemini", [cell("gemini", "G", geminiSegments, form: .rings)]),
            ])))
        // Two accounts of one harness beside another harness's one: the
        // account gap inside a block is narrower than the gap between blocks.
        everyCase.append((
            "harnesses-accounts",
            StatusItemRenderer.Model(
                groups: [
                    harness("claude", [work, personal]),
                    harness("codex", [cell("codex", "C", codexSegments)]),
                ],
                expandsFocus: false)))
        // Each vendor's own alarms on its own mark: Claude under an incident
        // with a pending notice, Codex quiet beside it. One harness's outage
        // must never badge another's.
        everyCase.append((
            "harnesses-incident",
            StatusItemRenderer.Model(groups: [
                harness(
                    "claude", [cell("default", "A", clean, focused: true)],
                    incident: .major, indicator: true),
                harness("codex", [cell("codex", "C", codexSegments)]),
            ])))
        // A stale harness greys its own mark while the other stays live.
        everyCase.append((
            "harnesses-stale",
            StatusItemRenderer.Model(groups: [
                harness("claude", [cell("default", "A", clean, focused: true)]),
                harness("codex", [cell("codex", "C", nil, stale: true)]),
            ])))
        // A harness's account in an item of its own: the shared item keeps
        // the other vendors, and the alarm is filed once.
        let splitHarnesses = StatusItemRenderer.Model(groups: [
            harness(
                "claude", [cell("default", "A", clean, focused: true)],
                incident: .major, indicator: true),
            harness("codex", [cell("codex", "C", codexSegments, form: .rings, own: true)]),
        ])
        for item in StatusItemRenderer.itemModels(for: splitHarnesses) {
            everyCase.append(("harnesses-item-\(item.profileID ?? "shared")", item.model))
        }

        let height = NSStatusBar.system.thickness
        // Every case on both grounds (0.100.1): the dark bar's PNGs keep
        // their names and their bytes, and `statusitem-light-*` is the same
        // model in the bright bar's ink over a bright wallpaper's cream.
        let grounds: [(StatusItemRenderer.Ground, String, NSColor)] = [
            (.dark, "", NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)),
            (.light, "light-", NSColor(srgbRed: 0.93, green: 0.89, blue: 0.80, alpha: 1)),
        ]
        // The hit rectangles beside the pixels: a sidecar naming which
        // account each x-range belongs to, so a layout regression shows as
        // a diff rather than as a hover landing on the wrong card.
        var sidecar: [String] = []
        for (name, model) in everyCase {
            let bar = StatusItemRenderer.image(for: model, height: height)
            sidecar.append("\(name)  width \(Int(bar.size.width.rounded()))")
            for rect in StatusItemRenderer.cellRects(for: model, height: height) {
                // A mark's region reads "(glyph)" while one harness is on the
                // bar — the spelling every pinned sidecar since 0.96 carries,
                // and the gate compares the old file as a PREFIX of this one.
                // With several, it names its harness, or two marks would be
                // indistinguishable rows.
                let name = rect.profileID
                    ?? (model.groups.count > 1 ? "(glyph:\(rect.harnessID))" : "(glyph)")
                sidecar.append(String(
                    format: "  %-10@ x %6.1f … %6.1f", name, rect.rect.minX, rect.rect.maxX))
            }
            let padded = NSSize(width: ceil(bar.size.width) + 16, height: height + 8)
            for (ground, prefix, fill) in grounds {
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(padded.width * 2), pixelsHigh: Int(padded.height * 2),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                else { continue }
                rep.size = padded
                let inked = StatusItemRenderer.image(for: model, height: height, ground: ground)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                fill.setFill()
                NSRect(origin: .zero, size: padded).fill()
                inked.draw(in: NSRect(x: 8, y: 4, width: bar.size.width, height: height))
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: directory.appending(path: "statusitem-\(prefix)\(name).png"))
            }
        }
        try? sidecar.joined(separator: "\n").appending("\n")
            .write(to: directory.appending(path: "statusitem-cells.txt"), atomically: true, encoding: .utf8)
    }
}
