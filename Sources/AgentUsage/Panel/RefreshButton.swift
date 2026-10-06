import SwiftUI
import UsageCore

/// Refresh now, wearing the hour's API pressure: tinted while there is
/// room, orange near the budget, red past it — where a click explains why
/// instead of spending the request.
struct RefreshButton: View {
    let store: UsageStore
    /// Owned by the host so a focus change can drop it.
    @Binding var showBlocked: Bool

    var body: some View {
        Button {
            // A red button is soft-disabled: the click surfaces WHY
            // instead of spending a request that risks the lockout the
            // color warns about. Hover already tells; click insists.
            if !store.isLocalProvider, store.apiBudget(now: Date()).fraction >= 1 {
                showBlocked = true
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
        .popover(isPresented: $showBlocked, arrowEdge: .bottom) {
            Text(refreshHelp)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 220)
                .padding(10)
        }
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
