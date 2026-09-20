import Foundation

/// What the harness half of the focus rule knows about one harness: whether
/// the person shows it, how many DAYS it was used over the activity window,
/// its newest write, and its accounts as `FocusRule` sees them (ids are
/// `ProfileKey`s).
public struct HarnessFocusCandidate: Sendable, Equatable {
    public let id: String
    public let shown: Bool
    /// Distinct local days with a session write inside
    /// `ProfileActivity.window`, across this harness's eligible accounts.
    public let activeDays: Int
    public let lastActivity: Date?
    public let accounts: [FocusCandidate]

    public init(
        id: String, shown: Bool, activeDays: Int, lastActivity: Date?, accounts: [FocusCandidate]
    ) {
        self.id = id
        self.shown = shown
        self.activeDays = activeDays
        self.lastActivity = lastActivity
        self.accounts = accounts
    }
}

/// Focus with several harnesses metered at once (v0.101.0): the person's pin
/// wins while it is eligible; otherwise the SHOWN harness used on the most
/// days over the trailing fortnight, the harness already focused keeping a
/// tie, then the newest write, then the build's standard order — and inside
/// that harness, the account `FocusRule` picks, unchanged.
///
/// DAYS, not files, decide between harnesses: file volume doesn't compare
/// across vendors (one agent writes a transcript per subagent, another one
/// rollout per session), while "I worked with it on nine of the last
/// fourteen days" means the same thing for every one of them. Inside a
/// harness the files DO compare, so the account rule keeps counting them.
///
/// One harness reduces to `FocusRule.focused` exactly — which is what keeps
/// a single-harness Mac's focus behaviour byte-for-byte what it was.
public enum HarnessFocusRule {
    public static func focused(
        _ harnesses: [HarnessFocusCandidate], pin: String?, current: String?
    ) -> String? {
        let eligible = harnesses.filter { $0.shown && $0.accounts.contains(where: \.eligible) }
        if let pin,
           eligible.contains(where: { $0.accounts.contains { $0.id == pin && $0.eligible } }) {
            return pin
        }
        let holder = harnesses.first { harness in
            harness.accounts.contains { $0.id == current }
        }?.id
        let order = Dictionary(
            uniqueKeysWithValues: harnesses.enumerated().map { ($0.element.id, $0.offset) })
        let winner = eligible.sorted { a, b in
            if a.activeDays != b.activeDays { return a.activeDays > b.activeDays }
            if (a.id == holder) != (b.id == holder) { return a.id == holder }
            let aWrite = a.lastActivity ?? .distantPast
            let bWrite = b.lastActivity ?? .distantPast
            if aWrite != bWrite { return aWrite > bWrite }
            return (order[a.id] ?? .max) < (order[b.id] ?? .max)
        }.first
        return winner.flatMap { FocusRule.focused($0.accounts, pin: nil) }
    }
}
