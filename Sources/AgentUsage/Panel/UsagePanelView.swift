import SwiftUI
import UsageCore

struct UsagePanelView: View {
    /// The one thing handed in (0.96.0): the panel shows whichever account
    /// is focused and re-renders when that changes — the status item builds
    /// it once per process.
    var registry: ProviderRegistry
    /// Wired by StatusItemController: closes the panel, opens the window —
    /// optionally landed on one card (an account-found notice's
    /// click-through goes straight to Accounts).
    let onOpenSettings: (SettingsLanding?) -> Void
    /// Same shape for the Sessions window.
    let onOpenSessions: () -> Void
    /// The shortlist's click-through: opens the Sessions window landed on
    /// the clicked session.
    let onOpenSession: (String) -> Void
    /// Opens the main window.
    let onOpenMainWindow: () -> Void
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
    /// Where the activity section is navigated to (paged window or drilled
    /// day); the Sessions strip below follows it.
    @State private var activityFocus: DateInterval?
    /// Where the status popover is anchored, if it's up — the footer dot or
    /// the incident banner. One popover, two attachment points, so the two
    /// entry points can never both present at once.
    @State private var statusAnchor: StatusAnchor?
    /// A reset notice's click-through: the meter card it opened and the
    /// moment to light there. Cleared when that popover closes, so a later
    /// row hover opens the same meter's card with nothing lit.
    @State private var litReset: (meter: String, at: Date)?
    /// Pointer inside the status popover or its dot; either keeps it open.
    @State private var hoveringStatus = false
    @State private var hoveringStatusDot = false
    /// A release the user chose not to hear about again — quiets the chip
    /// and menu item for exactly that version; the next one speaks.
    @AppStorage("updateSkippedVersion") private var skippedUpdateVersion = ""

    /// How several accounts are presented (decision D6). Absent from the
    /// panel entirely while one account shows.
    @AppStorage(PanelAccountForm.key) private var accountFormRaw = PanelAccountForm.standard.rawValue

    /// The status popover's two entry points (surfaces S1 and S4).
    enum StatusAnchor: String, Identifiable {
        case footer, banner
        var id: String { rawValue }
    }

    /// The focused account's face — every existing call site reads it.
    private var store: UsageStore { registry.focusedStore }

    private var accountForm: PanelAccountForm {
        PanelAccountForm(rawValue: accountFormRaw) ?? .standard
    }

    /// Meters listed per account, so the strip's selector steps aside.
    private var isStacked: Bool {
        accountForm == .stacked && registry.shownProfiles.count > 1
    }

    /// One row's identity in `openMeter` / `hoveredMeter` / the frame
    /// preferences. The focused-account forms keep the bare meter id — the
    /// pre-0.96 spelling — so nothing about a one-account panel changes.
    private func meterKey(_ meterID: String, profileID: String?) -> String {
        guard let profileID else { return meterID }
        return "\(profileID)|\(meterID)"
    }

    /// Which account and meter a key names.
    private func meterKeyParts(_ key: String) -> (profileID: String, meterID: String) {
        guard let separator = key.firstIndex(of: "|") else { return (registry.focusedID, key) }
        return (String(key[key.startIndex..<separator]), String(key[key.index(after: separator)...]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    AccountStrip(
                        registry: registry, form: accountForm,
                        onSetForm: { accountFormRaw = $0.rawValue },
                        onFocus: { registry.focus($0) },
                        onAuto: { registry.pin(nil) })
                        // Two fingers across the strip step through the
                        // accounts — the heatmap pager's gesture and its
                        // sign convention (fingers left = the next one).
                        // Attached here, not inside the strip: an
                        // NSViewRepresentable in that view would render as
                        // a placeholder in every headless snapshot.
                        .background(HorizontalSwipeCatcher(
                            enabled: registry.shownProfiles.count > 1 && accountForm != .stacked
                        ) { direction in
                            if let next = AccountStrip.step(
                                direction, in: registry.shownProfiles, focusedID: registry.focusedID)
                            {
                                registry.focus(next)
                            }
                        })
                    NoticesBand(
                        registry: registry, store: store,
                        onOpenMeterHistory: openMeterHistory,
                        onOpenAccounts: { onOpenSettings(.accounts) })
                    serviceStatusSection
                    AccountErrorBlock(store: store)
                    content
                    AccountStatusLine(store: store)
                    Divider()
                    HeatmapView(
                        activity: store.activity, pricing: store.pricing,
                        weeklyProfile: store.weeklyProfile,
                        agentName: store.provider.agentName,
                        style: store.style,
                        focus: $activityFocus,
                        samples: store.samples,
                        timeline: store.tokenTimeline,
                        sessions: store.sessions,
                        windowOutcomes: store.windowOutcomes,
                        outages: store.outages,
                        onOpenOutage: openOutage,
                        sessionAuditMeter: store.auditMeter(rank: 0),
                        weeklyAuditMeter: store.auditMeter(rank: 1))
                    SessionsShortlistSection(
                        store: store, activityFocus: activityFocus,
                        onOpenSessions: onOpenSessions, onOpenSession: onOpenSession)
                }
                // Switching accounts crossfades everything below the strip
                // (the drill idiom) — a fresh subtree, so nothing of the
                // previous account's chart or hover state lingers.
                .id(isStacked ? "stacked" : registry.focusedID)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.16), value: registry.focusedID)
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
) { selection in
            let owner = registry.store(for: selection.profileID) ?? store
            MeterHistoryView(
                meter: selection.meter, samples: owner.samples,
                timeline: owner.tokenTimeline, pricing: owner.pricing,
                prediction: owner.predictions[selection.meter.label],
                overshoot: owner.forecastOvershoots[selection.meter.label],
                outcomes: owner.windowOutcomes,
                agentName: owner.provider.agentName,
                // Per ACCOUNT, not per provider: two accounts' popovers
                // remember their own span and frame (identical to the old
                // key for the default profile, so nothing resets).
                providerID: owner.profile.scopeKey,
                // Explicit, not an environment: this popover is hoisted onto
                // the panel's wrapper, outside the section whose card it is.
                style: owner.style,
                accountTitle: accountTitle(for: owner),
                highlightReset: litReset?.meter == selection.key ? litReset?.at : nil,
                outages: owner.outages,
                onOpenOutage: openOutage)
                .onHover { inside in
                    hoveringPopover = inside
                    if !inside { scheduleHideIfLeft() }
                }
        }
        .popover(item: $statusAnchor, attachmentAnchor: statusAttachment, arrowEdge: .bottom) { _ in
            if let card = store.serviceStatus {
                ServiceStatusPopover(card: card)
                    // Hover-pinned (surface S2): the pointer resting anywhere
                    // inside keeps it up, so a user can read an incident
                    // without racing a dismissal.
                    .onHover { inside in
                        hoveringStatus = inside
                        if !inside { scheduleStatusHideIfLeft() }
                    }
            }
        }
        .onAppear { store.scanActivity() }
        // The panel's own state names rows and moments of ONE account;
        // none of it survives a switch (`.id` resets the subtree, not the
        // state declared here).
        .onChange(of: registry.focusedID) { _, _ in
            openMeter = nil
            hoveredMeter = nil
            statusAnchor = nil
            litReset = nil
            activityFocus = nil
            meterFrames = [:]
            showRefreshBlocked = false
            hoveringPopover = false
            hoveringStatus = false
            hoveringStatusDot = false
            store.scanActivity()
        }
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
    private var openSelection: Binding<MeterSelection?> {
        Binding(
            get: {
                guard let openMeter else { return nil }
                let parts = meterKeyParts(openMeter)
                guard let owner = registry.store(for: parts.profileID) ?? registry.store(for: registry.focusedID),
                      let meter = owner.state.snapshot?.meters.first(where: { $0.id == parts.meterID })
                else { return nil }
                return MeterSelection(key: openMeter, profileID: parts.profileID, meter: meter)
            },
            set: { selection in
                // Two popovers hosted on one view race each other exactly as
                // the per-row modifiers did (see this view's opening note) —
                // presenting one while the other is up loses, and SwiftUI
                // writes the failure back through the binding. They are
                // mutually exclusive here so the second one always wins.
                if selection != nil { statusAnchor = nil }
                if selection == nil { litReset = nil }
                openMeter = selection?.key
            })
    }

    /// Which account's meter the shared popover is showing. Keyed by the
    /// row key, so the stacked form's two "Session (5h)" rows are distinct
    /// items and switching between them re-presents rather than no-ops.
    struct MeterSelection: Identifiable, Equatable {
        let key: String
        let profileID: String
        let meter: Meter
        var id: String { key }
    }

    private var openAnchor: PopoverAttachmentAnchor {
        if let openMeter, let frame = meterFrames[openMeter] {
            return .rect(.rect(frame))
        }
        return .rect(.bounds)
    }

    /// Whose card the popover is — shown only once more than one account
    /// shows, so a one-account popover is unchanged.
    private func accountTitle(for owner: UsageStore) -> MeterHistoryView.AccountTitle? {
        guard registry.shownProfiles.count > 1 else { return nil }
        return MeterHistoryView.AccountTitle(
            monogram: registry.monogram(for: owner.profile),
            label: registry.label(for: owner.profile))
    }

    /// The leave grace: close only once the cursor has settled on neither a
    /// meter row nor the popover — travelling between them never drops it.
    private func scheduleHideIfLeft() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            if hoveredMeter == nil && !hoveringPopover { openMeter = nil }
        }
    }

    /// The status popover hangs off whichever surface opened it: the footer
    /// dot's measured frame, or the banner (panel bounds — it spans the top).
    private var statusAttachment: PopoverAttachmentAnchor {
        if statusAnchor == .footer, let frame = meterFrames[Self.statusDotFrameKey] {
            return .rect(.rect(frame))
        }
        return .rect(.bounds)
    }

    /// Frame key for the footer dot, parked in the same preference dictionary
    /// the meter rows use — one measurement channel for the whole panel.
    static let statusDotFrameKey = "service-status-dot"

    /// The status popover's own leave grace, mirroring the meter popover's:
    /// travelling from the dot into the popover must never drop it (S2).
    private func scheduleStatusHideIfLeft() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            if !hoveringStatus && !hoveringStatusDot { statusAnchor = nil }
        }
    }

    /// A reset notice's click-through: the meter card that saw it, lit at
    /// the moment. The card hangs off the meter the notice names, falling
    /// back to the weekly meter; an event the vendor emptied every meter
    /// for is the weekly story either way.
    private func openMeterHistory(label: String?, at: Date) {
        guard let meters = store.state.snapshot?.meters else { return }
        let meter = meters.first { $0.label == label }
            ?? meters.first { $0.rank == 1 }
            ?? meters.first { $0.rank > 0 }
            ?? meters.first
        guard let meter else { return }
        statusAnchor = nil
        litReset = (meter.id, at)
        openMeter = meter.id
    }

    /// A click on an outage nub in any chart: the incident's report, where
    /// the provider says one exists — the same rule the notice row follows.
    private func openOutage(_ span: OutageSpan) {
        guard let url = store.provider.outageDestination(url: span.url) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Whether a pending notice already carries the running incident — then
    /// the incident banner stays out (the notice row owns that surface, as
    /// it owns the menu bar capsule).
    private var incidentShownAsNotice: Bool {
        store.notices?.items.contains { $0.ownsMenuBarSurface } ?? false
    }

    private func toggleStatusFromBanner() {
        openMeter = nil
        statusAnchor = statusAnchor == .banner ? nil : .banner
    }

    /// The incident section (surface S4) — absent entirely when healthy, so
    /// a green day costs the panel no space at all. Maintenance stays out by
    /// design (decision D2): the footer dot carries it. Yields to the
    /// Notifications section's ongoing row when one exists.
    @ViewBuilder private var serviceStatusSection: some View {
        if let card = store.serviceStatus, card.hasIncident, !incidentShownAsNotice {
            ServiceStatusBanner(card: card, onTap: toggleStatusFromBanner)
        }
    }

    /// The footer's dot (surface S1) plus its click target. Present whenever
    /// a card exists; nil card renders nothing, because absent is not healthy.
    @ViewBuilder private var serviceStatusControl: some View {
        if let card = store.serviceStatus {
            Button {
                openMeter = nil
                statusAnchor = statusAnchor == .footer ? nil : .footer
            } label: {
                ServiceStatusDot(indicator: card.indicatorValue)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { inside in
                hoveringStatusDot = inside
                if !inside { scheduleStatusHideIfLeft() }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MeterFramePreference.self,
                        value: [
                            Self.statusDotFrameKey:
                                proxy.frame(in: .named(Self.panelSpace))
                        ])
                }
            )
            .help(ServiceStatusStyle.headline(card))
        }
    }

    @ViewBuilder private var content: some View {
        if isStacked {
            ForEach(registry.shownProfiles, id: \.key) { profile in
                if let owner = registry.store(for: profile.key) {
                    accountHeader(profile, focused: profile.key == registry.focusedID)
                    meterList(owner, profileID: profile.key)
                }
            }
        } else {
            meterList(store, profileID: nil)
        }
    }

    /// The stacked form's per-account heading: whose meters follow.
    private func accountHeader(_ profile: Profile, focused: Bool) -> some View {
        HStack(spacing: 6) {
            // The strip's own rule: a lone account wears its agent's mark
            // and name, one of several its letter and label.
            if registry.isLoneInHarness(profile) {
                HarnessTile(
                    style: HarnessStyle(registry.provider(for: profile)), focused: focused, size: 15)
            } else {
                MonogramTile(monogram: registry.monogram(for: profile), focused: focused, size: 15)
            }
            AccountRowTitle(registry: registry, profile: profile, focused: true)
                .opacity(focused ? 1 : 0.7)
            Spacer()
        }
        .contentShape(Rectangle())
        .pointerStyle(.link)
        .onTapGesture { registry.focus(profile.key) }
    }

    @ViewBuilder private func meterList(_ owner: UsageStore, profileID: String?) -> some View {
        switch owner.state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.callout).foregroundStyle(.secondary)
            }
        case .live(let snapshot), .cached(let snapshot, _):
            ForEach(snapshot.meters) { meter in
                MeterRow(
                    meter: meter,
                    stale: owner.state.isStale,
                    prediction: owner.predictions[meter.label],
                    overshoot: owner.forecastOvershoots[meter.label],
                    key: meterKey(meter.id, profileID: profileID),
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
                Text(AppIdentity.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("v\(AppIdentity.version)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                UpdateChip(store: store, onOpenSettings: { onOpenSettings(nil) })
            }
            Spacer()
            RefreshButton(store: store, showBlocked: $showRefreshBlocked)

            Button(action: onOpenMainWindow) {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.borderless)
            .help("Open the \(AppIdentity.displayName) window (⌘0)")

            if let usageSettings = store.provider.links.usageSettings {
                Link(destination: usageSettings) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Open \(usageSettings.host() ?? store.provider.serviceName) usage settings")
            }

            serviceStatusControl

            Menu {
                Picker("Refresh when active", selection: SettingsBindings.interval(store)) {
                    ForEach(
                        SettingsBindings.menuIntervalChoices(current: store.activeInterval),
                        id: \.self
                    ) { seconds in
                        Text(UsageFormatting.duration(seconds)).tag(seconds)
                    }
                }
                // No Metering picker since 0.101.0: every detected harness is
                // metered at once, and whether one is DISPLAYED is a switch in
                // Settings → General, not a choice of which to read.
                Toggle("Launch at login", isOn: SettingsBindings.launchAtLogin())
                Divider()
                if let update = UpdateChip.visibleUpdate(store, skipped: skippedUpdateVersion) {
                    if store.canSelfInstall(update) {
                        Button("Update to \(update.latestVersion)…") {
                            AppUpdater.shared.resetFailure()
                            AppUpdater.shared.install(update)
                        }
                        .disabled(AppUpdater.shared.isBusy)
                    } else {
                        // A checkout build can't swap itself, and a
                        // source-only release has nothing to swap in; the
                        // Settings card carries the how.
                        Button("Version \(update.latestVersion) available…") {
                            onOpenSettings(nil)
                        }
                    }
                }
                Button("Open \(AppIdentity.displayName) Window") { onOpenMainWindow() }
                    .keyboardShortcut("0", modifiers: .command)
                if store.providesSessions {
                    Button("Sessions…") { onOpenSessions() }
                        .keyboardShortcut("1", modifiers: .command)
                }
                Button("Settings…") { onOpenSettings(nil) }
                    .keyboardShortcut(",", modifiers: .command)
                Button("Quit \(AppIdentity.displayName)") { NSApp.terminate(nil) }
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

}

/// Rows report their frames (in UsagePanelView.panelSpace) so the shared
/// popover can anchor to whichever row is open.
struct MeterFramePreference: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
