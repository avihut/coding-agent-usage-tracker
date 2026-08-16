import SwiftUI
import UsageCore

struct UsagePanelView: View {
    var store: UsageStore
    /// Drives the ⋯ menu's Metering picker; the panel itself is rebuilt by
    /// the status item whenever the active provider changes.
    var registry: ProviderRegistry
    /// Wired by StatusItemController: closes the panel, opens the window.
    let onOpenSettings: () -> Void
    /// Same shape for the Sessions window.
    let onOpenSessions: () -> Void
    /// The shortlist's click-through: opens the Sessions window landed on
    /// the clicked session.
    let onOpenSession: (String) -> Void
    /// Coordinate space the row-frame preferences are measured in — the same
    /// view the shared popover attaches to, so its anchor rects line up.
    static let panelSpace = "usage-panel"

    /// The one meter (by id) whose popover is up. A single popover(item:)
    /// hosted here presents it: per-row popover modifiers raced each other
    /// on switches — dismissing A while presenting B — and when the new
    /// presentation lost, SwiftUI wrote false back through the binding and
    /// nothing stayed open.
    @State private var openMeter: String?
    /// The meter (by id) the cursor is currently over, if any.
    @State private var hoveredMeter: String?
    @State private var hoveringPopover = false
    @State private var meterFrames: [String: CGRect] = [:]
    /// Clicking the red (budget-spent) reload button opens its explanation
    /// instead of refreshing.
    @State private var showRefreshBlocked = false
    /// The shortlist row under the cursor, if any.
    @State private var hoveredSession: String?
    /// Where the activity section is navigated to (paged window or drilled
    /// day); the Sessions strip below follows it.
    @State private var activityFocus: DateInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    errorBlock
                    content
                    statusRow
                    Divider()
                    HeatmapView(
                        activity: store.activity, pricing: store.pricing,
                        weeklyProfile: store.weeklyProfile,
                        agentName: store.provider.agentName,
                        focus: $activityFocus,
                        samples: store.samples,
                        timeline: store.tokenTimeline,
                        sessions: store.sessions,
                        windowOutcomes: store.windowOutcomes,
                        sessionAuditMeter: auditMeter(rank: 0),
                        weeklyAuditMeter: auditMeter(rank: 1))
                    sessionsSection
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            // Content that fits must feel static — no rubber-band stretch
            // on a panel that has nothing to scroll.
            .scrollBounceBehavior(.basedOnSize)
            // The footer lives OUTSIDE the scroll: the version and its
            // buttons stay put at any scroll position.
            footer
        }
        // Wide enough that the breakdown grid never truncates model names.
        .frame(width: 360)
        // On a tall enough screen the ScrollView's ideal height IS the
        // content height, so nothing changes; past the cap the popover
        // stops growing and the content scrolls instead of clipping.
        .frame(maxHeight: maxPanelHeight)
        // On the wrapper, outside the scrolled content: anchor rects stay
        // in visible coordinates, so the meter popover points at the row
        // where it currently sits on screen.
        .coordinateSpace(name: Self.panelSpace)
        .onPreferenceChange(MeterFramePreference.self) { meterFrames = $0 }
        .popover(
            item: openSelection, attachmentAnchor: openAnchor, arrowEdge: .trailing
        ) { meter in
            MeterHistoryView(
                meter: meter, samples: store.samples,
                timeline: store.tokenTimeline, pricing: store.pricing,
                prediction: store.predictions[meter.label],
                agentName: store.provider.agentName,
                providerID: store.provider.id)
                .onHover { inside in
                    hoveringPopover = inside
                    if !inside { scheduleHideIfLeft() }
                }
        }
        .onAppear { store.scanActivity() }
        // Re-sync the login-item mirror between panel sessions: the user
        // can flip registration in Settings or System Settings while the
        // panel sits closed-but-alive (onAppear won't fire again).
        .onReceive(NotificationCenter.default.publisher(for: .panelDidClose)) { _ in
            LoginItemState.shared.refresh()
        }
    }

    /// The tallest the panel may grow on the screen it's on, with a little
    /// air; beyond it the content scrolls. Screens the panel has always fit
    /// on never hit the cap.
    private var maxPanelHeight: CGFloat {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return 900 }
        return screen.visibleFrame.height - 24
    }

    /// The shared popover's item. Resolving through the live snapshot keeps
    /// the content current across refreshes (Meter.id is positional and
    /// stable), and a meter vanishing from the API dismisses cleanly.
    private var openSelection: Binding<Meter?> {
        Binding(
            get: {
                guard let openMeter else { return nil }
                return store.state.snapshot?.meters.first { $0.id == openMeter }
            },
            set: { openMeter = $0?.id })
    }

    private var openAnchor: PopoverAttachmentAnchor {
        if let openMeter, let frame = meterFrames[openMeter] {
            return .rect(.rect(frame))
        }
        return .rect(.bounds)
    }

    /// The leave grace: close only once the cursor has settled on neither a
    /// meter row nor the popover — travelling between them never drops it.
    private func scheduleHideIfLeft() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            if hoveredMeter == nil && !hoveringPopover { openMeter = nil }
        }
    }

    /// Failures lead the panel: with no title row above them anymore, an
    /// error and its hint are the first thing the eye lands on.
    @ViewBuilder private var errorBlock: some View {
        if let error = store.state.error {
            VStack(alignment: .leading, spacing: 2) {
                Text(error.shortText(agent: store.provider.agentName))
                    .font(.caption)
                    .foregroundStyle(store.state.snapshot == nil ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                if let hint = error.hint(agent: store.provider.agentName) {
                    Text(hint).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Pipeline state right under the meters it describes — fetch time,
    /// next-poll countdown, budget gauge — with the plan label flushed to
    /// the opposite end of the same line.
    @ViewBuilder private var statusRow: some View {
        if store.state.snapshot != nil || store.nextRefreshAt != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    statusLine(now: context.date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let plan = store.state.snapshot?.plan?.displayLabel {
                    // A working link dressed as a plain caption: Link's tint
                    // shouted over the header, so the hand cursor and help
                    // tag carry the affordance instead of color. Providers
                    // without an upgrade page get the caption, no link.
                    if let upgrade = store.provider.links.planUpgrade {
                        Button {
                            NSWorkspace.shared.open(upgrade)
                        } label: {
                            Text(plan)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                        .help("Choose your plan on \(upgrade.host() ?? store.provider.serviceName)")
                    } else {
                        Text(plan)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch store.state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.callout).foregroundStyle(.secondary)
            }
        case .live(let snapshot), .cached(let snapshot, _):
            ForEach(snapshot.meters) { meter in
                MeterRow(
                    meter: meter,
                    stale: store.state.isStale,
                    prediction: store.predictions[meter.label],
                    openMeter: $openMeter,
                    hoveredMeter: $hoveredMeter,
                    onLeave: scheduleHideIfLeft)
            }
            if snapshot.meters.isEmpty {
                Text("No limits reported").font(.callout).foregroundStyle(.secondary)
            }
            if let spend = snapshot.spendLine {
                Divider()
                HStack {
                    Text("Credits").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(spend.formatted).font(.caption.monospacedDigit())
                }
            }
        case .unavailable:
            EmptyView() // the error block up top already shows the error + hint
        }
    }

    /// Pinned below the scroll area (v0.56.0): its divider runs full-bleed
    /// as the bar's structural edge, and the row carries its own padding —
    /// the scrolled content's 14pt inset no longer wraps it.
    @ViewBuilder private var footer: some View {
        Divider()
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Claude Usage")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("v\(AppIdentity.version)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                // A red button is soft-disabled: the click surfaces WHY
                // instead of spending a request that risks the lockout the
                // color warns about. Hover already tells; click insists.
                if !store.isLocalProvider, store.apiBudget(now: Date()).fraction >= 1 {
                    showRefreshBlocked = true
                } else {
                    store.refresh(.manual)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(refreshPressureStyle)
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .help(refreshHelp)
            .popover(isPresented: $showRefreshBlocked, arrowEdge: .bottom) {
                Text(refreshHelp)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 220)
                    .padding(10)
            }

            if let usageSettings = store.provider.links.usageSettings {
                Link(destination: usageSettings) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Open \(usageSettings.host() ?? store.provider.serviceName) usage settings")
            }

            Menu {
                Picker("Refresh when active", selection: SettingsBindings.interval(store)) {
                    ForEach(
                        SettingsBindings.menuIntervalChoices(current: store.activeInterval),
                        id: \.self
                    ) { seconds in
                        Text(UsageFormatting.duration(seconds)).tag(seconds)
                    }
                }
                // Hidden while only one harness exists on this machine —
                // a picker with a single real row is noise.
                if registry.presentChoices.count > 1 {
                    Picker("Metering", selection: meteringSelection) {
                        Text(registry.automaticLabel).tag(ProviderRegistry.automatic)
                        ForEach(registry.presentChoices) { choice in
                            Text(choice.name).tag(choice.id)
                        }
                    }
                }
                Toggle("Launch at login", isOn: SettingsBindings.launchAtLogin())
                Divider()
                if store.providesSessions {
                    Button("Sessions…") { onOpenSessions() }
                        .keyboardShortcut("1", modifiers: .command)
                }
                Button("Settings…") { onOpenSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Button("Quit Claude Usage") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            // .button + borderless renders the bare icon; the default menu
            // style wraps it in a bordered pull-down pill.
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var meteringSelection: Binding<String> {
        Binding(
            get: { registry.selection },
            set: { registry.select($0) })
    }

    /// The last few interactive sessions, one quiet line each — a shortcut
    /// into the Sessions browser. Background runs stay out of the strip;
    /// "Show more" covers them and anything past the cap. While the activity
    /// section is navigated (paged window or drilled day) the strip follows
    /// it, labels the span, and states emptiness rather than vanishing.
    @ViewBuilder private var sessionsSection: some View {
        let shortlist = SessionShortlist.build(store.sessions, in: activityFocus)
        if store.providesSessions,
           !shortlist.rows.isEmpty || shortlist.hasMore || activityFocus != nil {
            let colors = shortlistColors
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Sessions")
                        .font(.caption.bold())
                    if let focus = activityFocus {
                        Spacer(minLength: 8)
                        Text(Self.focusLabel(focus))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 2)
                if shortlist.rows.isEmpty {
                    Text("No sessions in this period")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                }
                ForEach(shortlist.rows) { session in
                    shortlistRow(session, colors: colors)
                }
                if shortlist.hasMore {
                    Button {
                        onOpenSessions()
                    } label: {
                        Text("Show more…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                }
            }
        }
    }

    /// The meter the audit surfaces read at this rank (0 session, 1 weekly):
    /// its label keys the samples/ledger; a meter without a known window
    /// length can't place cliffs, so it offers no audit.
    private func auditMeter(rank: Int) -> AuditMeterInfo? {
        guard let meter = store.state.snapshot?.meters.first(where: { $0.rank == rank }),
              let window = meter.limitWindow
        else { return nil }
        return AuditMeterInfo(label: meter.label, window: window)
    }

    /// "Aug 5" for a drilled day, "Jul 27 – Aug 2" for a paged window — the
    /// heatmap's own range vocabulary.
    private static func focusLabel(_ interval: DateInterval) -> String {
        let calendar = Calendar.current
        let firstDay = calendar.startOfDay(for: interval.start)
        // The interval is half-open; its last DAY sits just before the end.
        let lastDay = calendar.startOfDay(for: interval.end.addingTimeInterval(-1))
        if firstDay == lastDay { return focusFormatter.string(from: firstDay) }
        return "\(focusFormatter.string(from: firstDay)) – \(focusFormatter.string(from: lastDay))"
    }

    private static let focusFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    /// The same palette input as the sessions window — the union over every
    /// session's models — so a model's dot color matches across surfaces.
    private var shortlistColors: [String: Color] {
        var models: Set<String> = []
        for session in store.sessions { models.formUnion(session.models.keys) }
        return ModelPalette.assignment(for: models.sorted())
    }

    /// One shortlist entry: the sidebar's full session card, wrapped in the
    /// panel's hover/click chrome.
    private func shortlistRow(_ session: SessionSummary, colors: [String: Color]) -> some View {
        SessionRow(
            session: session,
            cost: SessionsView.cost(of: session, pricing: store.pricing),
            colors: colors)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(hoveredSession == session.id ? 0.07 : 0)))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    hoveredSession = session.id
                } else if hoveredSession == session.id {
                    hoveredSession = nil
                }
            }
            .pointerStyle(.link)
            .onTapGesture { onOpenSession(session.id) }
    }

    private func statusLine(now: Date) -> Text {
        var parts: [Text] = []
        if let fetchedAt = store.state.snapshot?.fetchedAt {
            // Day-aware: a local provider's data is only as fresh as the
            // agent's last session, and a bare clock time would lie about
            // a days-old stamp.
            let stamp = UsageFormatting.updatedStamp(fetchedAt, now: now)
            // The stale badge lives here now that there's no header for it.
            parts.append(
                store.state.isStale
                    ? Text("cached \(stamp)").foregroundStyle(.orange)
                    : Text("Updated \(stamp)"))
        }
        if let next = store.nextRefreshAt {
            parts.append(Text(UsageFormatting.countdownText(to: next, now: now)))
        }
        // Why "next in 20m" instead of 5: quiet decayed the cadence. Activity
        // (or usage moving) snaps it back — worth a word of transparency.
        let pace = store.paceMultiplier(now: now)
        if pace > 1 { parts.append(Text("idle ×\(pace)")) }
        // Surface the API budget only once it's half spent — quiet otherwise.
        // Local providers have no budget: nothing is requested from anyone.
        if !store.isLocalProvider {
            let budget = store.apiBudget(now: now)
            if budget.fraction >= 0.5 { parts.append(Text("API \(budget.used)/\(budget.ceiling)h")) }
        }
        guard var line = parts.first else { return Text("") }
        for part in parts.dropFirst() { line = line + Text(" · ") + part }
        return line
    }

    /// Orange once the hour's requests reach 80% of the estimated budget,
    /// red at or past it — the warning lives on the button that spends it.
    private var refreshPressureStyle: AnyShapeStyle {
        guard !store.isLocalProvider else { return AnyShapeStyle(.tint) }
        let fraction = store.apiBudget(now: Date()).fraction
        if fraction >= 1 { return AnyShapeStyle(.red) }
        if fraction >= 0.8 { return AnyShapeStyle(.orange) }
        return AnyShapeStyle(.tint)
    }

    /// Tiered with `refreshPressureStyle` — whatever color the button
    /// wears, hovering it says why.
    private var refreshHelp: String {
        if store.isLocalProvider {
            return "Refresh now — re-reads \(store.provider.agentName)'s local session files"
        }
        let budget = store.apiBudget(now: Date())
        if budget.fraction >= 1 {
            return "This hour's ~\(budget.ceiling)-request API budget is spent"
                + " (\(budget.used) used) — refreshing now risks a rate-limit"
                + " lockout. The gauge clears as requests age out of the hour."
        }
        if budget.fraction >= 0.8 {
            return "Refresh now — \(budget.used) of ~\(budget.ceiling) hourly"
                + " API requests used; nearing the budget, another poll may"
                + " trip the rate limit"
        }
        return "Refresh now (at most once per 3 minutes)"
    }

}

/// Rows report their frames (in UsagePanelView.panelSpace) so the shared
/// popover can anchor to whichever row is open.
struct MeterFramePreference: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
