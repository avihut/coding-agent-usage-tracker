import Foundation

/// Per-day cost aggregation for the activity charts' cost dimension —
/// prebuilt alongside `HeatmapLayout` so switching the chart to cost never
/// prices models inside a render pass.
public struct CostIndex: Sendable, Equatable {
    /// Estimated cost per local-midnight day; days worth nothing (no models,
    /// or none priced) are absent.
    public let byDay: [Date: Double]
    /// The costliest day — the intensity denominator; 1 when nothing priced.
    public let maxByDay: Double
    public let total: Double
    /// Each model's costliest single day, for the model-filtered ramp.
    public let modelMax: [String: Double]

    public static let empty = CostIndex(byDay: [:], maxByDay: 1, total: 0, modelMax: [:])

    public init(
        byDay: [Date: Double], maxByDay: Double, total: Double, modelMax: [String: Double]
    ) {
        self.byDay = byDay
        self.maxByDay = maxByDay
        self.total = total
        self.modelMax = modelMax
    }

    public static func build(days: [Date: DailyActivity], pricing: PricingTable) -> CostIndex {
        var byDay: [Date: Double] = [:]
        var modelMax: [String: Double] = [:]
        for (day, entry) in days {
            var dayTotal = 0.0
            for (model, tally) in entry.models {
                guard let rates = pricing.rates(for: model) else { continue }
                let dollars = rates.dollars(for: tally)
                guard dollars > 0 else { continue }
                dayTotal += dollars
                modelMax[model] = max(modelMax[model] ?? 0, dollars)
            }
            if dayTotal > 0 { byDay[day] = dayTotal }
        }
        return CostIndex(
            byDay: byDay,
            maxByDay: byDay.values.max() ?? 1,
            total: byDay.values.reduce(0, +),
            modelMax: modelMax)
    }
}
