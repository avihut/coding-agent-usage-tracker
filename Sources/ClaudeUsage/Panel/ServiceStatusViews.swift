import SwiftUI
import UsageCore

/// The status feature's shared vocabulary: how an indicator becomes a color,
/// and how a duration becomes the phrase every surface repeats. One place,
/// because the footer dot, the menu bar badge, the panel banner and the hover
/// popover must never disagree about what "major" looks like.
enum ServiceStatusStyle {
    static func color(for indicator: ServiceStatusCard.Indicator) -> Color {
        switch indicator {
        case .none: .green
        case .minor: .yellow
        case .major: .orange
        case .critical: .red
        case .maintenance: .blue
        // Grey and hollow: not knowing is not an alarm (decision D3).
        case .unknown: .secondary
        }
    }

    /// "monitoring" → "Monitoring".
    static func phaseLabel(_ phase: String) -> String {
        phase.prefix(1).uppercased() + phase.dropFirst()
    }

    /// The one-line summary the popover header and the CLI both speak.
    static func headline(_ card: ServiceStatusCard) -> String {
        if let incident = card.activeIncident { return incident.name }
        if card.indicatorValue == .unknown { return "Status unavailable" }
        if !card.descriptionText.isEmpty { return card.descriptionText }
        return card.indicatorValue == .none ? "All Systems Operational" : "Service disrupted"
    }
}

/// The footer's indicator (surface S1) — when nothing is wrong, this dot is
/// the feature's entire visible footprint.
struct ServiceStatusDot: View {
    let indicator: ServiceStatusCard.Indicator
    var diameter: CGFloat = 10

    var body: some View {
        Group {
            if indicator == .unknown {
                // Hollow: a ring says "no reading", where a filled dot would
                // claim one.
                Circle()
                    .strokeBorder(ServiceStatusStyle.color(for: indicator), lineWidth: 1.5)
            } else {
                Circle()
                    .fill(ServiceStatusStyle.color(for: indicator))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// The incident summary (surfaces S4 and S5): color rail, name, phase, how
/// long it has been going, the latest message, and which components it
/// touches. One view, two hosts — the panel's top section and the menu bar's
/// hover popover — so the copy can never drift between them.
struct ServiceStatusBanner: View {
    let card: ServiceStatusCard
    /// The hover popover's tighter form: no component chips, one message line.
    var compact = false
    /// Set by the panel so clicking the banner opens the full popover (D5).
    var onTap: (() -> Void)?

    var body: some View {
        if let incident = card.activeIncident {
            let tint = ServiceStatusStyle.color(for: incident.impactValue)
            HStack(alignment: .top, spacing: 8) {
                // The rail carries the color, so the text beneath stays at
                // full legibility instead of being tinted into a warning.
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(incident.name)
                        .font(.caption.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(ServiceStatusStyle.phaseLabel(incident.phase).uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(tint)
                        // The clock keeps running while the panel sits open;
                        // a static string would quietly go stale on screen.
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(
                                "\(incident.impact) · going "
                                    + UsageFormatting.duration(
                                        incident.duration(now: context.date)))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    if let message = incident.lastMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(compact ? 2 : 3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !compact, !incident.componentNames.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(incident.componentNames.prefix(4), id: \.self) { name in
                                Text(name)
                                    .font(.system(size: 9))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(
                                        .quaternary, in: RoundedRectangle(cornerRadius: 3))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
            .help(
                onTap == nil
                    ? "\(card.pageName) status" : "Open the \(card.pageName) status summary")
        }
    }
}

/// The status page, mirrored (surface S2). Everything here comes from the
/// digest's card — it renders offline, and says how old it is rather than
/// pretending to be current.
struct ServiceStatusPopover: View {
    let card: ServiceStatusCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !card.incidents.isEmpty {
                Divider()
                ForEach(card.incidents) { incident in
                    incidentBlock(incident)
                }
            }
            if !card.maintenances.isEmpty {
                Divider()
                maintenanceBlock
            }
            if !card.components.isEmpty {
                Divider()
                componentList
            }
            if !card.recentlyResolved.isEmpty {
                Divider()
                resolvedBlock
            }
            Divider()
            footer
        }
        .frame(width: 300)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            ServiceStatusDot(indicator: card.indicatorValue, diameter: 12)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(ServiceStatusStyle.headline(card))
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if card.indicatorValue == .unknown {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(unreachableText(now: context.date))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if card.hasIncident, !card.descriptionText.isEmpty {
                    Text(card.descriptionText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    /// A feed we couldn't reach says exactly that, with the age of the last
    /// real reading — never an invented all-clear (decision D3).
    private func unreachableText(now: Date) -> String {
        guard let okAt = card.okAt else {
            return "Couldn't reach the \(card.pageName) status page."
        }
        let age = UsageFormatting.duration(max(0, now.timeIntervalSince(okAt)))
        return "Couldn't reach the status page · last read \(age) ago"
    }

    private func incidentBlock(_ incident: StatusIncident) -> some View {
        let tint = ServiceStatusStyle.color(for: incident.impactValue)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(ServiceStatusStyle.phaseLabel(incident.phase).uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(
                        "\(incident.impact) · "
                            + UsageFormatting.duration(incident.duration(now: context.date)))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let url = incident.url.flatMap(URL.init(string:)) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption2)
                    }
                    .help("Open this incident on the status page")
                }
            }
            if let message = incident.lastMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let updated = incident.lastUpdateAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(
                        "Updated "
                            + UsageFormatting.duration(
                                max(0, context.date.timeIntervalSince(updated))) + " ago")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var componentList: some View {
        VStack(spacing: 0) {
            ForEach(card.components) { component in
                HStack(spacing: 6) {
                    Text(component.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(component.displayStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Circle()
                        .fill(componentColor(component))
                        .frame(width: 6, height: 6)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 4)
    }

    /// Component states use the page's own vocabulary, so the mapping stays
    /// here rather than in the shared indicator ladder.
    private func componentColor(_ component: StatusComponent) -> Color {
        switch component.status {
        case "operational": .green
        case "degraded_performance": .yellow
        case "partial_outage": .orange
        case "major_outage": .red
        case "under_maintenance": .blue
        default: .secondary
        }
    }

    private var maintenanceBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(card.maintenances) { window in
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(.blue).frame(width: 6, height: 6).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(window.name)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(maintenanceCaption(window))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func maintenanceCaption(_ window: StatusMaintenance) -> String {
        let phase = ServiceStatusStyle.phaseLabel(
            window.phase.replacingOccurrences(of: "_", with: " "))
        guard let start = window.windowStart else { return phase }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "\(phase) · \(formatter.string(from: start))"
    }

    /// The quiet all-clear (decision D4): the loud surfaces have already gone
    /// dark, but for an hour the popover still explains what just happened.
    private var resolvedBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(card.recentlyResolved) { incident in
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(.green).frame(width: 6, height: 6).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Resolved — \(incident.name)")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        if let resolved = incident.resolvedAt {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text(
                                    UsageFormatting.duration(
                                        max(0, context.date.timeIntervalSince(resolved)))
                                        + " ago")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            // Ticking, not stamped once: the popover is hover-pinned and can
            // sit open for minutes, and a frozen "checked 4s ago" would be
            // the one line here that lies.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(checkedText(now: context.date))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let url = URL(string: card.pageURL) {
                Link(destination: url) {
                    HStack(spacing: 2) {
                        Text(url.host() ?? card.pageURL)
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 9))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func checkedText(now: Date) -> String {
        let age = max(0, now.timeIntervalSince(card.checkedAt))
        let phrase = "Checked \(UsageFormatting.duration(age)) ago"
        return card.stale ? phrase + " · stale" : phrase
    }
}
