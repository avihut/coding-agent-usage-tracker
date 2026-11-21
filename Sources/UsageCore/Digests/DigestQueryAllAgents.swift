import Foundation

/// `--all-agents` (2026-11-21): the consumption nouns answer for every
/// account "all" counts (`ConsumptionMembership`) instead of one — the
/// digest's `allAgents` section, projected onto the top level so each noun
/// runs the code it always ran. Limits are never summed, so the flag
/// belongs to the consumption nouns alone.
extension DigestQuery {
    static let allAgentsNouns: Set<String> = ["activity", "cost", "models", "model"]

    /// The view an `--all-agents` run reads. It names no account, so naming
    /// one as well is a contradiction (19), and the home variable an agent's
    /// status line runs under selects nothing here. With no section in the
    /// digest the membership rule decides why: one account (or none) means
    /// that account's own section IS the total; several mean the writer
    /// predates the section (20) — never a silent one-account answer.
    static func allAgentsView(parsed: ParsedArgs, digest: LiveState) -> Outcome<ProfileView> {
        if parsed.flags["account"] != nil || parsed.flags["provider"] != nil {
            return .failure(badQuery(
                "--all-agents counts every account — drop --account/--provider, or drop --all-agents"))
        }
        let view: LiveState
        if let all = digest.allAgents {
            // Every member still scanning: there is no total yet — never
            // answered as a total of zero.
            guard let projected = digest.viewingAllAgents(all) else {
                return .failure(noMatch(
                    "no all-agents total yet — \(scanningNames(all, digest: digest)) still scanning"))
            }
            view = projected
        } else {
            let members = ConsumptionMembership.members(of: digest)
            guard members.count <= 1 else {
                return .failure(noMatch(
                    "this digest carries no all-agents total — it was written before the section existed"))
            }
            guard !members.isEmpty else {
                return .failure(noMatch(
                    "no account is counted in all agents — each is disabled, asleep or hidden"))
            }
            view = members.first.flatMap { member in
                digest.profiles == nil ? nil : digest.viewing(profile: member.account)
            } ?? digest
        }
        return .success(ProfileView(
            id: "all", digest: view, projected: true, providerID: view.engine.providerID,
            accountID: Profile.defaultID))
    }

    /// A partial total says so in every register: a note on stderr (raw and
    /// JSON stdout never change for a script), and " · partial" on a human
    /// summary line — `cost`'s amount included, as " · stale" already rides
    /// it — never on a field value or a table.
    static func markingPartial(
        _ output: QueryOutput, noun: String, parsed: ParsedArgs, digest: LiveState, json: Bool,
        raw: Bool
    ) -> QueryOutput {
        guard let all = digest.allAgents, all.partial, output.exitCode == exitOK else { return output }
        let note = "partial — \(scanningNames(all, digest: digest)) still scanning, left out of the total"
        let summary = parsed.flags["fields"] == nil && (
            noun == "cost" || (["activity", "model"].contains(noun) && parsed.positionals.count <= 1))
        let stdout = !json && !raw && summary && !output.stdout.isEmpty
            ? "\(output.stdout) · partial" : output.stdout
        return QueryOutput(
            stdout: stdout, note: [output.note, note].compactMap { $0 }.joined(separator: "\n"),
            exitCode: output.exitCode)
    }

    /// The agents a total is waiting on, by name, each once.
    static func scanningNames(_ all: AllAgentsState, digest: LiveState) -> String {
        let names = all.members.filter { $0.stateValue == .scanning }.map { member in
            digest.harnesses?.first { $0.id == member.providerID }?.agentName ?? member.providerID
        }
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }.joined(separator: ", ")
    }

    /// What a human table calls an agent: its harness's short name, else its id.
    static func agentShortName(_ id: String, digest: LiveState?) -> String {
        guard let harness = digest?.harnesses?.first(where: { $0.id == id }) else { return id }
        return harness.shortName
    }
}

extension LiveState {
    /// The all-agents section projected onto the top level — activity and
    /// today's models replaced, everything else (engine, freshness, vendor
    /// cards) the writer's own, so `--max-age` still judges the file. Nil
    /// while the section has no total (no member counted yet).
    public func viewingAllAgents(_ all: AllAgentsState) -> LiveState? {
        guard let models = all.models, let activity = all.activity else { return nil }
        return LiveState(
            schemaVersion: schemaVersion, sessionsCap: sessionsCap, engine: engine, meters: meters,
            menuBar: menuBar, models: models, activity: activity, sessions: sessions,
            serviceStatus: serviceStatus, appUpdate: appUpdate, accountPresence: accountPresence,
            notices: notices, outages: outages, focusedProfile: focusedProfile, profiles: profiles,
            menuBarCells: menuBarCells, harnesses: harnesses, pinnedProfile: pinnedProfile,
            allAgents: all)
    }
}
