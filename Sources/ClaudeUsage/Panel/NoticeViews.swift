import SwiftUI
import UsageCore

/// The notifications vocabulary shared by the panel's section and any other
/// face that lists notices: how a card's kind and state become a color.
enum NoticeStyle {
    /// The row's rail. The vendor's own acts (a reset) wear the provider
    /// accent; a running incident wears its severity; an ended one goes
    /// grey — the severity is over, so the color is too.
    static func tint(for card: NoticeCard) -> Color {
        switch Notice.Kind(rawValue: card.kind) {
        case .reset:
            return ProviderStyle.accentColor
        case .outage:
            guard card.ongoing, let severity = card.severity else { return .secondary }
            return ServiceStatusStyle.color(for: ServiceStatusCard.Indicator.parse(severity))
        case nil:
            return .secondary
        }
    }
}

/// The panel's Notifications section: pending notices above the meters,
/// absent entirely when nothing is pending. Every word comes pre-phrased
/// from the digest; this view decides only layout and the affordances —
/// × on hover for dismissable rows, none for an ongoing one, and "Dismiss
/// all" once two or more rows can go.
struct NoticesSection: View {
    let card: NoticesCard
    let onDismiss: (String) -> Void
    let onDismissAll: () -> Void
    /// Whether the provider has somewhere for this notice to lead — decides
    /// the row's link affordance; the destination itself is the owner's.
    let canOpen: (NoticeCard) -> Bool
    /// A click on the row: the incident's report, or the meter card lit at
    /// the reset — wherever the provider says (`noticeDestination`).
    let onOpen: (NoticeCard) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Notifications")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if card.items.filter(\.dismissable).count >= 2 {
                    Button("Dismiss all", action: onDismissAll)
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .pointerStyle(.link)
                        .help("Dismiss every notification that can be dismissed")
                }
            }
            ForEach(card.items) { item in
                NoticeRow(
                    card: item,
                    onDismiss: item.dismissable ? { onDismiss(item.id) } : nil,
                    onTap: canOpen(item) ? { onOpen(item) } : nil)
                    // A dismissed row leaves visibly (user-directed): it
                    // recedes and fades while the rows below close up.
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .scale(scale: 0.94, anchor: .trailing).combined(with: .opacity)))
            }
        }
        // Keyed on the row set, not on a click: a client-mode dismissal
        // lands with the next digest, and must animate just the same.
        .animation(.easeOut(duration: 0.22), value: card.items.map(\.id))
    }
}

/// One notice: color rail, title (with the impact for outages), detail,
/// time line, component chips, and the × that appears on hover when the
/// row can be dismissed.
struct NoticeRow: View {
    let card: NoticeCard
    let onDismiss: (() -> Void)?
    let onTap: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        let tint = NoticeStyle.tint(for: card)
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(card.title)
                        .font(.caption.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let severity = card.severity {
                        Text("· \(severity)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail = card.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                whenLine
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if !card.components.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(card.components.prefix(4), id: \.self) { name in
                            Text(name)
                                .font(.system(size: 9))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .opacity(hovering ? 1 : 0)
                .help("Dismiss")
                .accessibilityLabel("Dismiss notification")
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(tint.opacity(hovering ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onTap?() }
        .pointerStyle(onTap == nil ? .default : .link)
        .help(onTap == nil ? "" : "Open")
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// The time line. Ongoing notices get a running clock — the digest
    /// republishes only at landing points, and "Ongoing · 30 min" must not
    /// sit frozen while the panel is open (the banner ticks the same way).
    @ViewBuilder private var whenLine: some View {
        if card.ongoing {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(
                    "Ongoing · "
                        + UsageFormatting.duration(
                            max(0, context.date.timeIntervalSince(card.occurredAt))))
            }
        } else {
            Text(card.when)
        }
    }
}
