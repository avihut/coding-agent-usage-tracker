import ServiceManagement
import SwiftUI
import UsageCore

/// Bindings shared by the panel's ⋯ menu and the settings window — two
/// surfaces, one behavior.
enum SettingsBindings {
    /// The ⋯ menu's quick paces. No 1-minute option: sustained sub-3-minute
    /// polling trips the endpoint's rate limiter (anthropics/claude-code#31637).
    static let intervalPresets: [Double] = [180, 300, 900]

    /// A slider-chosen in-between pace joins the menu list as an extra
    /// entry, so the picker never shows an empty selection.
    static func menuIntervalChoices(current: Double) -> [Double] {
        intervalPresets.contains(current)
            ? intervalPresets
            : (intervalPresets + [current]).sorted()
    }

    @MainActor
    static func interval(_ store: UsageStore) -> Binding<Double> {
        Binding(
            get: { store.activeInterval },
            set: { store.setActiveInterval($0) }
        )
    }

    /// Registration happens only when the user flips this toggle (spec §10).
    @MainActor
    static func launchAtLogin() -> Binding<Bool> {
        Binding(
            get: { LoginItemState.shared.enabled },
            set: { enabled in
                if enabled {
                    try? SMAppService.mainApp.register()
                } else {
                    try? SMAppService.mainApp.unregister()
                }
                // Read back rather than trust the flip — registration can
                // land as .requiresApproval or fail quietly.
                LoginItemState.shared.refresh()
            }
        )
    }

    /// The background engine's off-switch. Off is sticky: it removes the
    /// agent AND disarms auto-install, so no entry point quietly brings it
    /// back; on re-arms and converges immediately. (The running app keeps
    /// rendering either way — it re-hosts the engine embedded within
    /// minutes of the daemon disappearing.)
    @MainActor
    static func backgroundDaemon() -> Binding<Bool> {
        Binding(
            get: { DaemonItemState.shared.installed },
            set: { enabled in
                LaunchAgentInstaller.setAutoInstall(enabled, defaults: .standard)
                if enabled {
                    let embedded = Bundle.main.bundleURL
                        .appending(path: "Contents/MacOS/usaged")
                    let binary = FileManager.default.fileExists(atPath: embedded.path)
                        ? embedded : nil
                    LaunchAgentInstaller.ensure(binary: binary, defaults: .standard)
                } else {
                    LaunchAgentInstaller.uninstall()
                }
                DaemonItemState.shared.refresh()
            }
        )
    }
}

/// Observable mirror of the launch-agent registration, for the same
/// reason LoginItemState exists: a Binding computed off the filesystem
/// never invalidates SwiftUI on its own.
@MainActor @Observable
final class DaemonItemState {
    static let shared = DaemonItemState()
    private(set) var installed = LaunchAgentInstaller.isInstalled()

    func refresh() {
        installed = LaunchAgentInstaller.isInstalled()
    }
}

/// Observable mirror of the login-item registration. SMAppService posts no
/// change notifications, and a Binding computed straight off it never
/// invalidates SwiftUI — the ⋯ menu's pre-built NSMenu kept rendering its
/// first read, so the checkmark never appeared. Only the mirror is new;
/// registration still happens exclusively on the user's flip.
@MainActor @Observable
final class LoginItemState {
    static let shared = LoginItemState()
    private(set) var enabled = SMAppService.mainApp.status == .enabled

    func refresh() {
        enabled = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - General

/// One provider-declared numeric preference (UsageProvider.preferences),
/// written straight through to its UserDefaults key; the change nudges a
/// manual refresh so a derived meter re-reads the assumption instantly.
private struct ProviderPreferenceRow: View {
    let preference: ProviderPreference
    let onChange: () -> Void
    @State private var value: Int

    init(preference: ProviderPreference, onChange: @escaping () -> Void) {
        self.preference = preference
        self.onChange = onChange
        let stored = UserDefaults.standard.integer(forKey: preference.key)
        _value = State(initialValue: stored > 0 ? stored : preference.defaultValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(preference.title)
                Spacer()
                Text("\(value)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Stepper("", value: valueBinding, in: preference.range, step: preference.step)
                    .labelsHidden()
            }
            note(preference.note)
        }
    }

    private var valueBinding: Binding<Int> {
        Binding(
            get: { value },
            set: { newValue in
                value = newValue
                UserDefaults.standard.set(newValue, forKey: preference.key)
                onChange()
            })
    }
}

struct GeneralSettingsPane: View {
    var store: UsageStore
    var registry: ProviderRegistry
    /// Idle tolerance for the popover activity strips.
    @AppStorage(ActivityGrace.storageKey)
    private var graceSeconds = ActivityGrace.defaultSeconds
    /// Claude Code's own transcript retention, mirrored from — and
    /// written back to — ~/.claude/settings.json.
    // Placeholder until onAppear mirrors the agent's own stored value.
    @State private var retentionDays = 30
    @State private var retentionWriteFailed = false
    /// What the transcripts weigh on disk, measured once per appearance
    /// off the main thread.
    @State private var diskUsage: TranscriptDiskUsage?
    /// The percent cutoffs behind DisplayLevel, seeded from defaults on
    /// appearance; edits write through and re-classify the live snapshot.
    @State private var warningPercent = Thresholds.standard.warningPercent
    @State private var criticalPercent = Thresholds.standard.criticalPercent

    private var meteringSelection: Binding<String> {
        Binding(
            get: { registry.selection },
            set: { registry.select($0) })
    }

    private func harnessName(_ id: String) -> String {
        registry.presentChoices.first { $0.id == id }?.name ?? id
    }

    private func signalText(_ signal: HarnessSignal) -> String {
        if signal.recentFiles > 0 {
            return "\(signal.recentFiles) session files in the last 14 days"
        }
        if let newest = signal.newestActivity {
            return "quiet — last active \(newest.formatted(date: .abbreviated, time: .omitted))"
        }
        return "no sessions found"
    }

    var body: some View {
        SettingsPaneScroll {
            SettingsCard("Metering") {
                HStack(alignment: .firstTextBaseline) {
                    Text("Harness")
                    Spacer()
                    Picker("Harness", selection: meteringSelection) {
                        Text(registry.automaticLabel).tag(ProviderRegistry.automatic)
                        ForEach(registry.presentChoices) { choice in
                            Text(choice.name).tag(choice.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                ForEach(registry.signals.filter(\.present), id: \.id) { signal in
                    infoRow(harnessName(signal.id), signalText(signal))
                }
                note("Automatic follows whichever agent actually ran on this Mac recently — scored on session files, since background daemons touch state files long after real use stops. One harness is metered at a time; switching re-reads everything from the other harness's own data.")
            }
            if !store.provider.preferences.isEmpty {
                SettingsCard(store.provider.agentName) {
                    ForEach(store.provider.preferences) { preference in
                        ProviderPreferenceRow(preference: preference) {
                            store.refresh(.manual)
                        }
                    }
                }
            }
            SettingsCard("Refresh") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Refresh when active")
                        Spacer()
                        Text(UsageFormatting.duration(store.activeInterval))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    MarkedSlider(
                        seconds: SettingsBindings.interval(store),
                        marks: RefreshIntervalScale.marks,
                        position: RefreshIntervalScale.position(of:),
                        value: RefreshIntervalScale.value(at:))
                }
                note("The pace while the agent is in use — the slider snaps to the marked stops, or lands anywhere between. Quiet stretches slow polling down on their own (to one poll per hour, or your chosen pace when that's slower) and fresh activity snaps it back. Nothing polls faster than once per 3 minutes — the usage endpoint rate-limits harder polling.")
            }
            SettingsCard("Thresholds") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Warning at")
                        Spacer()
                        Text("\(warningPercent)%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                    Slider(value: warningBinding, in: 30...95, step: 5)
                        .controlSize(.small)
                    HStack(alignment: .firstTextBaseline) {
                        Text("Error at")
                        Spacer()
                        Text("\(criticalPercent)%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.red)
                    }
                    Slider(value: criticalBinding, in: 35...100, step: 5)
                        .controlSize(.small)
                }
                note("Where the percent scale itself turns worrying: meters and the menu bar wear the warning color from the first cutoff and the error color from the second. The exhaustion forecast colors on its own yellow→red ramp and isn't affected. The two keep at least 5% apart.")
            }
            SettingsCard("Activity") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Session grace period")
                        Spacer()
                        Text(graceSeconds == 0 ? "Off" : UsageFormatting.duration(graceSeconds))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    MarkedSlider(
                        seconds: $graceSeconds,
                        marks: ActivityGraceScale.marks,
                        position: ActivityGraceScale.position(of:),
                        value: ActivityGraceScale.value(at:),
                        label: { $0 == 0 ? "off" : UsageFormatting.duration($0) })
                }
                note("The activity strips under the popover charts bridge idle gaps shorter than this — the agent waiting while you read or type a reply still counts as the same working session. Slide to off to mark only the moments it was producing tokens.")
            }
            if let agentSettings = store.provider.agentSettings {
                SettingsCard(store.provider.agentName) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Transcript retention")
                            Spacer()
                            Picker("Transcript retention", selection: retentionBinding) {
                                ForEach(retentionChoices, id: \.self) { days in
                                    Text(retentionLabel(days)).tag(days)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        if retentionWriteFailed {
                            Text("Couldn't update \(agentSettings.displayPath) — its current content didn't parse, so it was left untouched.")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                        if let diskUsage {
                            Divider()
                            infoRow(
                                "On disk now",
                                "\(Self.byteText(diskUsage.bytes)) · \(diskUsage.days) days of transcripts")
                            infoRow(
                                "Projected at \(retentionLabel(retentionDays))",
                                "≈ \(Self.byteText(diskUsage.projectedBytes(forDays: retentionDays)))")
                        }
                    }
                    note("How long \(store.provider.agentName) keeps local transcripts (its \(agentSettings.retentionKeyName) setting — this control reads and writes \(agentSettings.displayPath) directly, the app's one write there). The heatmap and per-model history come from those transcripts, so longer retention keeps more history — and more disk: the projection scales what today's holdings weigh per day to the chosen window. Takes effect when \(store.provider.agentName) next runs.")
                }
            }
            SettingsCard("Startup") {
                Toggle("Launch at login", isOn: SettingsBindings.launchAtLogin())
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Divider()
                Toggle("Background metering engine", isOn: SettingsBindings.backgroundDaemon())
                    .toggleStyle(.switch)
                    .controlSize(.small)
                if store.isDigestClient {
                    infoRow("Engine", "running as the background agent")
                }
                note("Runs the engine as a launch agent (com.avihu.usaged), so the meters, the terminal dashboard, and the tmux status line keep updating with the app closed. It installs itself when missing; off is sticky — the agent is removed and stays away until this is turned back on.")
            }
            SettingsCard("About") {
                infoRow("Version", "v\(AppIdentity.version)")
                Divider()
                infoRow(
                    "Network destinations",
                    (store.provider.networkDestinations + ["raw.githubusercontent.com"])
                        .joined(separator: " · "))
                // Declared on its own line, not folded into the list above:
                // the status feed is deliberately outside
                // `networkDestinations` so a zero-network provider keeps its
                // local-provider semantics (spec §10, amendment 2026-08-19).
                if let statusFeed = store.provider.statusFeed {
                    Divider()
                    infoRow("Status feed", statusFeed.host)
                }
                note(
                    (store.isLocalProvider
                        ? "Everything comes from this Mac's local \(store.provider.agentName) session files, read-only — including the limit percentages \(store.provider.agentName) itself records. Nothing is fetched from \(store.provider.serviceName). No analytics, no telemetry."
                        : "Usage comes from \(store.provider.serviceName)'s own usage endpoint; activity and tokens from this Mac's local \(store.provider.agentName) transcripts, read-only. No analytics, no telemetry.")
                        + (store.provider.statusFeed == nil
                            ? ""
                            : " The status feed is \(store.provider.serviceName)'s public status page, read with a plain request carrying no sign-in, no cookies, and nothing about you."))
            }
        }
        .onAppear {
            LoginItemState.shared.refresh()
            DaemonItemState.shared.refresh()
            let thresholds = UsageStore.currentThresholds()
            warningPercent = thresholds.warningPercent
            criticalPercent = thresholds.criticalPercent
            if let agentSettings = store.provider.agentSettings {
                retentionDays = agentSettings.readRetentionDays()
                    ?? agentSettings.defaultRetentionDays
            }
            if let source = store.localActivity {
                Task.detached(priority: .utility) {
                    let usage = source.diskUsage(now: Date())
                    await MainActor.run { diskUsage = usage }
                }
            }
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static func byteText(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    /// Both sliders write through and keep a 5-point gap by pushing the
    /// other cutoff along rather than colliding with it.
    private var warningBinding: Binding<Double> {
        Binding(
            get: { Double(warningPercent) },
            set: { newValue in
                warningPercent = Int(newValue.rounded())
                criticalPercent = max(criticalPercent, warningPercent + 5)
                persistThresholds()
            })
    }

    private var criticalBinding: Binding<Double> {
        Binding(
            get: { Double(criticalPercent) },
            set: { newValue in
                criticalPercent = Int(newValue.rounded())
                warningPercent = min(warningPercent, criticalPercent - 5)
                persistThresholds()
            })
    }

    private func persistThresholds() {
        UserDefaults.standard.set(warningPercent, forKey: UsageStore.warningThresholdKey)
        UserDefaults.standard.set(criticalPercent, forKey: UsageStore.criticalThresholdKey)
        store.thresholdsChanged()
    }

    /// Selection writes straight through to the agent's settings file —
    /// binding-set, not onChange, so the onAppear mirror never triggers a
    /// write.
    private var retentionBinding: Binding<Int> {
        Binding(
            get: { retentionDays },
            set: { days in
                retentionDays = days
                retentionWriteFailed =
                    !(store.provider.agentSettings?.writeRetentionDays(days) ?? false)
            })
    }

    /// The stock ladder, plus whatever custom value the file already
    /// holds so the picker never misrepresents it.
    private var retentionChoices: [Int] {
        let standard = [30, 60, 90, 180, 365, 730]
        return standard.contains(retentionDays)
            ? standard : (standard + [retentionDays]).sorted()
    }

    private func retentionLabel(_ days: Int) -> String {
        switch days {
        case 365: return "1 year"
        case 730: return "2 years"
        default: return "\(days) days"
        }
    }
}

// MARK: - Marked slider

/// A native slider over a marked scale's track — the refresh pace and the
/// activity grace period both draw through this, wired to their own scale's
/// position/value math. Mark labels sit at their true track positions
/// (compensating for the knob's end insets so labels line up with where the
/// thumb actually stops).
private struct MarkedSlider: View {
    @Binding var seconds: Double
    let marks: [Double]
    let position: (Double) -> Double
    let value: (Double) -> Double
    var label: (Double) -> String = { UsageFormatting.duration($0) }

    /// Half the NSSlider knob: the track is inset this much per side.
    private static let thumbInset: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            Slider(value: positionBinding, in: 0...1)
            // Notches: taller at the magnetic stops; each span between stops
            // subdivided evenly so the minor ticks keep one steady rhythm
            // across the whole track (they're ruler marks, not values).
            Canvas { context, size in
                let usable = size.width - 2 * Self.thumbInset
                let majors = marks.map(position)
                let targetStep = 0.0375
                for (p0, p1) in zip(majors, majors.dropFirst()) {
                    let count = max(1, Int(((p1 - p0) / targetStep).rounded()))
                    for i in 1..<count {
                        let p = p0 + (p1 - p0) * Double(i) / Double(count)
                        let x = Self.thumbInset + p * usable
                        context.fill(
                            Path(CGRect(x: x - 0.5, y: 2, width: 1, height: 4)),
                            with: .color(.primary.opacity(0.18)))
                    }
                }
                for p in majors {
                    let x = Self.thumbInset + p * usable
                    context.fill(
                        Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: 7)),
                        with: .color(.primary.opacity(0.38)))
                }
            }
            .frame(height: 8)
            GeometryReader { geo in
                let usable = geo.size.width - 2 * Self.thumbInset
                ForEach(marks, id: \.self) { mark in
                    let x = Self.thumbInset + position(mark) * usable
                    Text(label(mark))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .position(x: min(max(x, 16), geo.size.width - 14), y: 7)
                }
            }
            .frame(height: 14)
        }
    }

    /// The slider drags in normalized track space; the binding round-trips
    /// through the scale so the thumb visibly snaps onto a mark.
    private var positionBinding: Binding<Double> {
        Binding(
            get: { position(seconds) },
            set: { seconds = value($0) }
        )
    }
}
