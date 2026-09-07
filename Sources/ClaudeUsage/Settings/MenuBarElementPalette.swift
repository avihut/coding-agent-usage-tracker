import AppKit
import SwiftUI
import UsageCore

/// What can be added to the bar (0.98.0, user-directed): a tile per
/// element, pictured with the account's own numbers, dragged onto the
/// preview or clicked into place. The one element so far is "Runs out",
/// and its condition is said right here, beside the tile — an element
/// that draws nothing on a quiet day has to announce that where it is
/// placed, or a drop looks like it failed.
struct MenuBarElementPalette: View {
    let registry: ProviderRegistry
    /// The account the tile is pictured with (nil = the focused one).
    let profile: Profile?
    /// The arrangement being edited — bar-wide or one account's.
    let elements: [MenuBarElement]
    let onChange: ([MenuBarElement]) -> Void

    private var scope: RunsOutScope? { MenuBarLayout.runsOutScope(in: elements) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RunsOutTile(
                cell: MenuBarModelBuilder.runsOutSample(
                    for: profile, registry: registry, scope: scope ?? .earliest),
                placed: scope != nil,
                onAdd: { onChange(MenuBarLayout.settingRunsOut(.earliest, in: elements)) })
                .fixedSize()
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Runs out")
                        .font(.callout.weight(.semibold))
                    if scope != nil {
                        Text("In the bar")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }
                Text(
                    "The expected time until a limit is reached. Appears only while a limit is"
                        + " forecast to run out before it resets — or, once one is spent, counts"
                        + " down to its reset. On a quiet day it draws nothing at all.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let scope {
                    HStack(spacing: 10) {
                        Picker("Shows", selection: Binding(
                            get: { scope },
                            set: { onChange(MenuBarLayout.settingRunsOut($0, in: elements)) })
                        ) {
                            ForEach(RunsOutScope.allCases) { candidate in
                                Text(candidate.title).tag(candidate)
                            }
                        }
                        .fixedSize()
                        .help(scope.caption)
                        Button("Remove") { onChange(MenuBarLayout.removingRunsOut(from: elements)) }
                            .help("Or drag it off the preview")
                    }
                    .controlSize(.small)
                } else {
                    Text("Drag it onto the preview, or click the tile to add it after the meters.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// The tile: the element drawn as it would look with the session limit
/// half an hour out, on a swatch of bar. Drags as the element's token;
/// a click adds it in the default place.
private struct RunsOutTile: View {
    let cell: StatusItemRenderer.Cell
    let placed: Bool
    let onAdd: () -> Void

    @State private var hovering = false

    private var thumbnail: NSImage {
        StatusItemRenderer.elementImage(
            MenuBarLayout.runsOutScope(in: cell.elements).map { .runsOut($0) } ?? .runsOut(.earliest),
            in: cell, height: NSStatusBar.system.thickness)
    }

    var body: some View {
        // Not `.disabled` once placed — that dims the picture, and the
        // tile still has to drag; the click just has nothing left to add.
        Button(action: { if !placed { onAdd() } }) {
            VStack(spacing: 4) {
                MenuBarSwatch(image: thumbnail, selected: placed, hovering: hovering)
                Text(placed ? "Added" : "Add")
                    .font(.caption2.weight(placed ? .semibold : .regular))
                    .foregroundStyle(placed ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerStyle(placed ? .grabIdle : .link)
        .onDrag { MenuBarElementDrag.itemProvider(for: .runsOut(.earliest)) }
        .help("Runs out — drag onto the preview")
        .accessibilityLabel("Runs out")
    }
}
