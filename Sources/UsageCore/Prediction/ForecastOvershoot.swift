import Foundation

/// How far past its limit a window is forecast to land, and what buying that
/// much extra usage would cost at API list prices.
///
/// Anthropic sells extra usage at those rates, so once the forecast says a
/// window will be exceeded the actionable number is dollars — "how much more
/// would I have to buy" — with the percent over beside it. Everything here is
/// a list-price counterfactual, exactly like every other cost in this app:
/// a subscription plan bills nothing per token, so every surface phrases
/// these figures with "≈"/"~".
///
/// HONESTY: absent is never zero. A window whose tokens this Mac never saw
/// (no transcripts, a freshly-installed cache, usage spent on the web) gets
/// `tokens == nil`, and a window whose models carry no rate gets
/// `cost == nil` — never 0 tokens, never $0. The caption then carries the
/// percent alone.
public struct ForecastOvershoot: Codable, Sendable, Equatable {
    /// Percentage POINTS over the limit at the window's reset — the
    /// unclamped projection minus 100, always > 0. `estimate` returns nil
    /// rather than a zero or negative overshoot: a forecast that lands
    /// inside the limit has nothing to sell.
    public let percent: Double
    /// Tokens that overshoot is worth, converted through what this window's
    /// own tokens bought. Nil when the window has no attributable token
    /// data to measure the conversion on — absent, never 0.
    public let tokens: Int?
    /// USD those tokens would cost at API list prices. Nil when `tokens` is
    /// nil or no model in the window carries a rate — absent, never $0.
    public let cost: Double?

    public init(percent: Double, tokens: Int?, cost: Double?) {
        self.percent = percent
        self.tokens = tokens
        self.cost = cost
    }

    /// The overshoot for one meter's live window, or nil when there is none
    /// to state: the forecast stays inside the limit, the window has already
    /// reset, or the meter's window shape is unknown (guessing one would put
    /// dollars on a span nobody measured).
    ///
    /// TWO CONVERSIONS, both measured on the window itself rather than
    /// assumed:
    ///
    /// 1. PERCENT → TOKENS through `ModelCurves.windowPercentPerToken` — the
    ///    percent this window has GAINED (entering at zero, drops excluded,
    ///    so a vendor grant inside it counts what was bought before AND
    ///    after) over the tokens spent in it. That is the popover chart's
    ///    own Y-axis conversion, so the dollars quoted here and the curves
    ///    drawn there price a token identically.
    /// 2. TOKENS → DOLLARS through the window's own priced model mix: the
    ///    dollars those rows cost (via `ModelRates.dollarBreakdown`, the one
    ///    costing source) over their tokens. An UNPRICED model's tokens are
    ///    excluded from the denominator but not from the token conversion,
    ///    so the priced mix is extrapolated across them — the alternative is
    ///    silence about a window that is mostly priced.
    ///
    /// A scoped meter (`scopedModelName`) counts only its own model's
    /// tokens, on both sides, the way every other scoped surface does.
    public static func estimate(
        prediction: UsagePrediction, meter: Meter, samples: [UsageSample],
        timeline: [TokenSlot], pricing: PricingTable, now: Date
    ) -> ForecastOvershoot? {
        guard let projected = prediction.projectedUnclamped, projected > 100 else { return nil }
        guard let reset = meter.resetsAt, reset > now else { return nil }
        guard let window = meter.limitWindow else { return nil }

        let percent = projected - 100
        let start = reset.addingTimeInterval(-window)
        let all = WindowTokens.breakdown(timeline: timeline, from: start, to: now)
        let rows = meter.scopedModelName.map { WindowTokens.scoped(all, name: $0) } ?? all
        let spent = WindowTokens.total(rows).total
        let percents = samples
            .sorted { $0.t < $1.t }
            .filter { $0.t >= start && $0.t <= now }
            .compactMap { $0.percents[meter.label] }

        guard
            let percentPerToken = ModelCurves.windowPercentPerToken(
                percents: percents, tokens: spent),
            percentPerToken > 0
        else { return ForecastOvershoot(percent: percent, tokens: nil, cost: nil) }

        let tokens = Int((percent / percentPerToken).rounded())

        var pricedTokens = 0
        var pricedDollars = 0.0
        for row in rows {
            guard let rates = pricing.rates(for: row.model) else { continue }
            pricedTokens += row.tally.total
            pricedDollars += rates.dollars(for: row.tally)
        }
        let cost = pricedTokens > 0
            ? Double(tokens) * (pricedDollars / Double(pricedTokens))
            : nil
        return ForecastOvershoot(percent: percent, tokens: tokens, cost: cost)
    }
}
