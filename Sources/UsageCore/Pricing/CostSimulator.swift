import Foundation

/// A back-of-the-envelope model of what one Claude Code session does to the
/// four token counters — the engine behind the settings playground.
///
/// The model: a session is `steps` API requests (every tool call is one).
/// Request 1 writes the starting context (system prompt, CLAUDE.md, tool
/// definitions) to the prompt cache. Each later request reads everything
/// written so far from cache, writes the `growthPerStep` tokens that are new
/// since the previous request (the last reply plus fresh tool results),
/// sends `freshPerStep` tokens past the last cache breakpoint, and generates
/// `outputPerStep` tokens (visible text plus thinking — both bill as output).
///
/// Closed forms (n = steps, C = startingContext, g = growthPerStep):
///   writes = C + (n−1)·g
///   reads  = (n−1)·C + g·(n−1)(n−2)/2   ← grows with n²: the whole point
///   final context = C + n·g
public enum CostSimulator {
    public struct Session: Sendable, Equatable {
        /// Tokens in place before the first request: system prompt,
        /// CLAUDE.md, memory, tool definitions.
        public var startingContext: Int
        /// API requests in the session — every tool call is one.
        public var steps: Int
        /// Context added per request: tool results plus the model's reply.
        public var growthPerStep: Int
        /// Generated per request — visible text and extended thinking alike.
        public var outputPerStep: Int
        /// Tokens past the last cache breakpoint each request — single
        /// digits to low tens in real transcripts.
        public var freshPerStep: Int
        /// Subscription sessions cache with the 1-hour TTL; API keys default
        /// to 5 minutes. The write rates differ (2× vs 1.25× input).
        public var oneHourTTL: Bool

        public init(
            startingContext: Int, steps: Int, growthPerStep: Int, outputPerStep: Int,
            freshPerStep: Int = 12, oneHourTTL: Bool = true
        ) {
            self.startingContext = startingContext
            self.steps = steps
            self.growthPerStep = growthPerStep
            self.outputPerStep = outputPerStep
            self.freshPerStep = freshPerStep
            self.oneHourTTL = oneHourTTL
        }
    }

    public struct Outcome: Sendable, Equatable {
        public let tally: TokenTally
        public let cost: Double
        /// The same session with caching off: every request re-sends the
        /// entire conversation at the full input rate.
        public let uncachedCost: Double
        public let finalContext: Int
    }

    public static func simulate(_ session: Session, rates: ModelRates) -> Outcome {
        let n = max(1, session.steps)
        let context = max(0, session.startingContext)
        let growth = max(0, session.growthPerStep)
        let fresh = max(0, session.freshPerStep)
        let output = max(0, session.outputPerStep)

        let writes = context + (n - 1) * growth
        let reads = (n - 1) * context + growth * (n - 1) * (n - 2) / 2
        let tally = TokenTally(
            input: n * fresh,
            output: n * output,
            cacheCreation: writes,
            cacheRead: reads,
            cacheCreation1h: session.oneHourTTL ? writes : 0)

        // Counterfactual: request i re-sends the conversation so far —
        // C + (i−1)·g — as fresh input. Σ = n·C + g·n(n−1)/2.
        let uncachedPrompt = n * context + growth * n * (n - 1) / 2 + n * fresh
        let uncachedCost = Double(uncachedPrompt) * rates.input
            + Double(tally.output) * rates.output

        return Outcome(
            tally: tally,
            cost: rates.dollars(for: tally),
            uncachedCost: uncachedCost,
            finalContext: context + n * growth)
    }
}
