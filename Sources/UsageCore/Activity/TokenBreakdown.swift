import Foundation

/// Token counts by class, as Claude Code's transcripts report them. The four
/// classes are disjoint; `input` is only the fresh, uncached prompt slice.
public struct TokenTally: Codable, Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheCreation: Int
    public var cacheRead: Int
    /// The slice of `cacheCreation` written with the 1-hour TTL — billed at a
    /// higher rate than the 5-minute default, so costing tracks it separately.
    public var cacheCreation1h: Int

    public init(
        input: Int = 0, output: Int = 0, cacheCreation: Int = 0, cacheRead: Int = 0,
        cacheCreation1h: Int = 0
    ) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.cacheCreation1h = cacheCreation1h
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try container.decodeIfPresent(Int.self, forKey: .input) ?? 0
        output = try container.decodeIfPresent(Int.self, forKey: .output) ?? 0
        cacheCreation = try container.decodeIfPresent(Int.self, forKey: .cacheCreation) ?? 0
        cacheRead = try container.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        cacheCreation1h = try container.decodeIfPresent(Int.self, forKey: .cacheCreation1h) ?? 0
    }

    /// Everything the model read: fresh input plus both cache classes.
    public var inputSide: Int { input + cacheCreation + cacheRead }
    /// Input the model had to process anew — fresh prompt plus cache writes.
    /// The complement of `cacheRead` within `inputSide`: agentic harnesses
    /// re-send the whole conversation every request, so cache reads dwarf
    /// this, and displaying them as "input" misreads as typed prompt volume.
    public var uncachedInput: Int { input + cacheCreation }
    public var total: Int { inputSide + output }

    /// Share of the input side served from cache — the discounted part.
    /// Nil when there was no input side to take a share of.
    public var cachedShare: Double? {
        inputSide > 0 ? Double(cacheRead) / Double(inputSide) : nil
    }

    public mutating func add(_ other: TokenTally) {
        input += other.input
        output += other.output
        cacheCreation += other.cacheCreation
        cacheRead += other.cacheRead
        cacheCreation1h += other.cacheCreation1h
    }
}

/// One minute of one model's transcript usage. Minute granularity keeps the
/// cache small while bounding window-edge attribution error to under a minute.
public struct TokenSlot: Codable, Sendable, Equatable {
    /// Floored to the minute.
    public let t: Date
    /// Raw API model id, e.g. "claude-fable-5"; "unknown" when absent.
    public let model: String
    public var tally: TokenTally

    public init(t: Date, model: String, tally: TokenTally) {
        self.t = t
        self.model = model
        self.tally = tally
    }
}

/// One model's summed usage inside a limit window.
public struct ModelTokenUsage: Sendable, Equatable, Identifiable {
    public let model: String
    public let tally: TokenTally

    public var id: String { model }
    public var displayName: String { ModelNames.display(model) }

    public init(model: String, tally: TokenTally) {
        self.model = model
        self.tally = tally
    }
}

/// Pure slicing of the transcript timeline into per-model window sums.
public enum WindowTokens {
    /// Usage per model over `from...to`, heaviest model first.
    public static func breakdown(timeline: [TokenSlot], from: Date, to: Date) -> [ModelTokenUsage] {
        var byModel: [String: TokenTally] = [:]
        for slot in timeline where slot.t >= from && slot.t <= to {
            var tally = byModel[slot.model] ?? TokenTally()
            tally.add(slot.tally)
            byModel[slot.model] = tally
        }
        return rows(from: byModel)
    }

    /// A models map as ordered display rows, heaviest model first.
    public static func rows(from byModel: [String: TokenTally]) -> [ModelTokenUsage] {
        byModel
            .map { ModelTokenUsage(model: $0.key, tally: $0.value) }
            .sorted {
                $0.tally.total != $1.tally.total
                    ? $0.tally.total > $1.tally.total
                    : $0.model < $1.model
            }
    }

    /// Rows whose model id matches a scoped limit's display name ("Fable" →
    /// "claude-fable-5"). Empty when nothing matches — a scoped meter must
    /// never show other models' usage as its own.
    public static func scoped(_ breakdown: [ModelTokenUsage], name: String) -> [ModelTokenUsage] {
        let needle = name.lowercased()
        guard !needle.isEmpty else { return breakdown }
        return breakdown.filter { $0.model.lowercased().contains(needle) }
    }

    public static func total(_ breakdown: [ModelTokenUsage]) -> TokenTally {
        breakdown.reduce(into: TokenTally()) { $0.add($1.tally) }
    }
}

/// Friendly names for raw model ids — a facade over the active provider's
/// `ModelCatalog`, because display names are read from dozens of call sites
/// (grids, charts, pickers) where threading a provider through would drown
/// the code in plumbing.
public enum ModelNames {
    /// The active provider's catalog. Defaults to the provider this build
    /// bundles (Claude) so names read right even before wiring. The app
    /// writes this only on the main actor and only while re-binding the
    /// active provider — at launch and inside a registry switch, both
    /// before any dependent UI (re)builds — so every render observes one
    /// settled value, which is what makes the unsafe opt-out honest.
    nonisolated(unsafe) public static var catalog: ModelCatalog = .claude

    public static func display(_ id: String) -> String {
        catalog.displayName(id)
    }

    /// "claude-opus-4-8" → "Opus". Also the model-color ledger's family key.
    public static func family(_ id: String) -> String {
        catalog.familyName(id)
    }

    /// Capability-tier position of a family name; smaller sorts first.
    public static func familyRank(_ family: String) -> Int {
        catalog.familyRank(family)
    }
}
