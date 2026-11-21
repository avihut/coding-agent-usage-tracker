import Foundation
import Testing

@testable import UsageCore

/// The all-agents consumption total the digest carries for the TUI and the
/// CLI — who it counts, how it sums, and that it agrees with the panel's
/// own reading (`ConsumptionOutline`) and with the per-account sections.
@Suite("All-agents digest")
struct AllAgentsDigestTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let now = ISO8601DateFormatter().date(from: "2026-11-21T15:00:00Z")!

    private func day(_ offset: Int) -> Date {
        utc.startOfDay(for: now).addingTimeInterval(Double(offset) * 86400)
    }

    private func profile(
        _ id: String, _ providerID: String, enabled: Bool = true, showInMenuBar: Bool = true,
        dismissed: Bool = false
    ) -> Profile {
        Profile(
            id: id, providerID: providerID, home: nil, enabled: enabled, showInMenuBar: showInMenuBar,
            addedAt: now, ignoredIdentityKey: dismissed ? "x" : nil)
    }

    /// A landed scan: `models` per day offset, one slot per entry at 10:00.
    private func scan(
        _ entries: [(offset: Int, model: String, tokens: Int)], prompts: Int = 0,
        pricing: PricingTable = PricingTable(rates: [:], fetchedAt: .distantPast, source: .bundled)
    ) -> SectionConsumption {
        var byDay: [Date: DailyActivity] = [:]
        var timeline: [TokenSlot] = []
        for entry in entries {
            let tally = TokenTally(input: entry.tokens, output: 0, cacheCreation: 0, cacheRead: 0)
            var daily = byDay[day(entry.offset)]
                ?? DailyActivity(day: day(entry.offset), tokens: 0, messages: 0, prompts: prompts)
            daily.tokens += entry.tokens
            daily.models[entry.model, default: TokenTally()].add(tally)
            byDay[day(entry.offset)] = daily
            timeline.append(TokenSlot(t: day(entry.offset).addingTimeInterval(36000), model: entry.model, tally: tally))
        }
        return SectionConsumption(
            days: byDay.values.sorted { $0.day < $1.day }, timeline: timeline, pricing: pricing)
    }

    private func section(
        _ profile: Profile, dormant: Bool = false, _ consumption: SectionConsumption?
    ) -> ProfileSection {
        ProfileSection(
            profile: profile, label: profile.key, monogram: "X", dormant: dormant,
            lastActivityAt: nil, homeDisplayPath: nil, state: nil, consumption: consumption)
    }

    private let rates = ModelRates(input: 1e-6, output: 1e-6, cacheWrite: 1e-6, cacheRead: 1e-6)

    private var claudePricing: PricingTable {
        PricingTable(rates: ["opus": rates, "sonnet": rates], fetchedAt: now, source: .live)
    }

    // MARK: - Membership

    @Test("all is enrolled, enabled, awake accounts of shown harnesses — the bar is not part of it")
    func membership() {
        let candidates = [
            ConsumptionMembership.Candidate(key: "default", providerID: "claude", enrolled: true, enabled: true, dormant: false),
            ConsumptionMembership.Candidate(key: "claude.b", providerID: "claude", enrolled: true, enabled: false, dormant: false),
            ConsumptionMembership.Candidate(key: "claude.c", providerID: "claude", enrolled: true, enabled: true, dormant: true),
            ConsumptionMembership.Candidate(key: "claude.d", providerID: "claude", enrolled: false, enabled: true, dormant: false),
            ConsumptionMembership.Candidate(key: "codex", providerID: "codex", enrolled: true, enabled: true, dormant: false),
            ConsumptionMembership.Candidate(key: "gemini", providerID: "gemini", enrolled: true, enabled: true, dormant: false),
        ]
        #expect(ConsumptionMembership.members(candidates, shown: ["claude", "codex"]).map(\.account)
            == ["default", "codex"])
        // No roster = a one-harness writer: every harness is shown.
        #expect(ConsumptionMembership.members(candidates, shown: nil).map(\.account)
            == ["default", "codex", "gemini"])
    }

    @Test("the count label says how many agents are in the sums")
    func countLabel() {
        #expect(ConsumptionMembership.countLabel([("claude", true), ("codex", true)]) == "2 agents")
        #expect(ConsumptionMembership.countLabel([("claude", true), ("codex", true), ("gemini", false)])
            == "2 of 3 agents")
        #expect(ConsumptionMembership.countLabel([("claude", true), ("claude", true)]) == "2 accounts")
        // An agent counts once ANY of its accounts is in the sums.
        #expect(ConsumptionMembership.countLabel([("claude", true), ("claude", false), ("codex", true)])
            == "2 agents")
    }

    // MARK: - The section

    @Test("one account in all publishes no section: its own is the total")
    func oneMember() {
        let harnesses = [HarnessSection(provider: ClaudeProvider()), HarnessSection(provider: CodexProvider(), shown: false)]
        let sections = [
            section(profile("default", "claude"), scan([(0, "opus", 10)])),
            section(profile("default", "codex"), scan([(0, "gpt-5", 10)])),
        ]
        #expect(AllAgentsDigest.build(harnesses: harnesses, sections: sections, now: now, calendar: utc) == nil)
    }

    @Test("dormant, disabled and hidden accounts stay out; the bar doesn't matter")
    func whoIsIn() throws {
        let harnesses = [
            HarnessSection(provider: ClaudeProvider()), HarnessSection(provider: CodexProvider()),
            HarnessSection(provider: GeminiProvider(), shown: false),
        ]
        let sections = [
            section(profile("default", "claude", showInMenuBar: false), scan([(0, "opus", 100)])),
            section(profile("b", "claude"), dormant: true, scan([(0, "opus", 1000)])),
            section(profile("c", "claude", enabled: false), scan([(0, "opus", 1000)])),
            section(profile("default", "codex"), scan([(0, "gpt-5", 10)])),
            section(profile("default", "gemini"), scan([(0, "gemini-3-pro", 1000)])),
        ]
        let all = try #require(AllAgentsDigest.build(harnesses: harnesses, sections: sections, now: now, calendar: utc))
        #expect(all.members.map(\.profile) == ["default", "codex"])
        #expect(all.activity?.todayTokens == 110)
    }

    @Test("a member still scanning is named and left out — never summed as zero")
    func scanning() throws {
        let harnesses = [HarnessSection(provider: ClaudeProvider()), HarnessSection(provider: CodexProvider())]
        let sections = [
            section(profile("default", "claude"), scan([(0, "opus", 100)], pricing: claudePricing)),
            section(profile("default", "codex"), nil),
        ]
        let all = try #require(AllAgentsDigest.build(harnesses: harnesses, sections: sections, now: now, calendar: utc))
        #expect(all.members.map(\.state) == ["counted", "scanning"])
        #expect(all.partial)
        #expect(all.countLabel == "1 of 2 agents")
        #expect(all.activity?.todayTokens == 100)
        #expect(all.models?.map(\.agent) == ["claude"])
    }

    @Test("an agent with no tokens is named, and neither its prompts nor its days count")
    func noTokens() throws {
        let harnesses = [HarnessSection(provider: ClaudeProvider()), HarnessSection(provider: GeminiProvider())]
        let sections = [
            section(profile("default", "claude"), scan([(0, "opus", 100)], prompts: 2)),
            section(profile("default", "gemini"), scan([(-3, "gemini-3-pro", 0)], prompts: 40)),
        ]
        let all = try #require(AllAgentsDigest.build(harnesses: harnesses, sections: sections, now: now, calendar: utc))
        #expect(all.members.map(\.state) == ["counted", "noTokens"])
        #expect(!all.partial)
        #expect(all.countLabel == "1 of 2 agents")
        #expect(all.activity?.todayPrompts == 2)
        #expect(all.activity?.days.map(\.dayKey) == ["2026-11-21"])
    }

    @Test("same-named models: one row per agent, accounts of one agent summed")
    func rows() throws {
        let harnesses = [HarnessSection(provider: ClaudeProvider()), HarnessSection(provider: CodexProvider())]
        let sections = [
            section(profile("default", "claude"), scan([(0, "opus", 100), (0, "unknown", 5)], pricing: claudePricing)),
            section(profile("work", "claude"), scan([(0, "opus", 50), (-1, "sonnet", 20)], pricing: claudePricing)),
            section(profile("default", "codex"), scan([(0, "gpt-5", 70), (0, "unknown", 7)])),
        ]
        let all = try #require(AllAgentsDigest.build(harnesses: harnesses, sections: sections, now: now, calendar: utc))
        #expect(all.models?.map { "\($0.agent ?? "")/\($0.id)" } == ["claude/opus", "codex/gpt-5", "codex/unknown", "claude/unknown"])
        let opus = try #require(all.models?.first { $0.id == "opus" })
        #expect(opus.tally.total == 150)
        #expect(opus.cost == 150e-6)
        // Unpriced stays absent — Codex has no table here, Claude no rate for unknown.
        #expect(all.models?.first { $0.id == "gpt-5" }?.cost == nil)
        #expect(all.models?.first { $0.agent == "claude" && $0.id == "unknown" }?.cost == nil)
        #expect(all.activity?.todayCost == 150e-6)
        #expect(all.activity?.days.map(\.tokens) == [20, 232])
        #expect(all.activity?.modelDays.last?.models.count == 4)
    }

    @Test("one agent keeps its own colours; several wear agent tones, by the agent's own catalog family")
    func colours() throws {
        let claude = ClaudeProvider()
        let codex = CodexProvider()
        let model = "gpt-5.2-codex"
        // Codex's ledger as its engine seeds it: by Codex's own family reading.
        let codexLedger = ModelColorLedger().assigning([
            ("gpt-5.1", codex.modelCatalog.familyName("gpt-5.1")),
            (model, codex.modelCatalog.familyName(model)),
        ])
        let slots = try #require(codexLedger.slots(for: model, family: codex.modelCatalog.familyName(model)))
        let several = try #require(AllAgentsDigest.build(
            harnesses: [HarnessSection(provider: claude), HarnessSection(provider: codex, colorLedger: codexLedger)],
            sections: [
                section(profile("default", "claude"), scan([(0, "opus", 10)])),
                section(profile("default", "codex"), scan([(0, model, 10)])),
            ], now: now, calendar: utc))
        #expect(several.models?.first { $0.id == model }?.color == ModelColorMath.agentShade(
            hueSlot: slots.hue, shadeSlot: slots.shade, accent: RGBColor(codex.accent), on: .dark))

        let claudeLedger = ModelColorLedger().assigning([("claude-opus-4-8", "Opus"), ("claude-sonnet-4-5", "Sonnet")])
        let one = try #require(AllAgentsDigest.build(
            harnesses: [HarnessSection(provider: claude, colorLedger: claudeLedger)],
            sections: [
                section(profile("default", "claude"), scan([(0, "claude-sonnet-4-5", 10)])),
                section(profile("work", "claude"), scan([(0, "claude-sonnet-4-5", 10)])),
            ], now: now, calendar: utc))
        #expect(one.countLabel == "2 accounts")
        #expect(one.models?.first?.color == ModelColorMath.rgb(
            hueSlot: 1, shadeSlot: 0, accent: RGBColor(claude.accent), on: .dark))
    }

    @Test("hourly buckets stop at the section's own span; today's are always there")
    func hours() throws {
        let harnesses = [HarnessSection(provider: ClaudeProvider()), HarnessSection(provider: CodexProvider())]
        let sections = [
            section(profile("default", "claude"), scan([(0, "opus", 10), (-7, "opus", 10), (-8, "opus", 10)])),
            section(profile("default", "codex"), scan([(0, "gpt-5", 5)])),
        ]
        let all = try #require(AllAgentsDigest.build(harnesses: harnesses, sections: sections, now: now, calendar: utc))
        #expect(all.activity?.hourDays.map(\.dayKey) == ["2026-11-14", "2026-11-21"])
        #expect(all.activity?.todayHours == [HourBucket(hour: 10, tokens: 15, cost: nil)])
        // Day totals keep their full horizon.
        #expect(all.activity?.days.count == 3)
    }

    /// ONE answer: the digest's per-model sums over a span are what the
    /// panel's own breakdown (`ConsumptionOutline`) counts for the same
    /// accounts and span — agent by agent, tokens and cost.
    @Test("the section agrees with the panel's outline over the same accounts")
    func agreesWithThePanel() throws {
        let claude = ClaudeProvider()
        let codex = CodexProvider()
        let claudeScan = scan([(0, "opus", 100), (-2, "sonnet", 40), (-9, "opus", 7)], pricing: claudePricing)
        let workScan = scan([(-1, "opus", 30)], pricing: claudePricing)
        let codexScan = scan([(0, "gpt-5", 70), (-3, "unknown", 9)])
        let all = try #require(AllAgentsDigest.build(
            harnesses: [HarnessSection(provider: claude), HarnessSection(provider: codex)],
            sections: [
                section(profile("default", "claude"), claudeScan),
                section(profile("work", "claude"), workScan),
                section(profile("default", "codex"), codexScan),
            ], now: now, calendar: utc))
        let accounts = [
            AccountConsumption(agent: "claude", account: "default", days: claudeScan.days, pricing: claudePricing),
            AccountConsumption(agent: "claude", account: "work", days: workScan.days, pricing: claudePricing),
            AccountConsumption(agent: "codex", account: "codex", days: codexScan.days, pricing: PricingTable(rates: [:], fetchedAt: .distantPast, source: .bundled)),
        ]
        let span = DateInterval(start: day(-6), end: day(1))
        let outline = ConsumptionOutline.build(accounts, in: span, foldFamilies: false)
        let inSpan = try #require(all.activity).modelDays.filter { $0.dayKey >= "2026-11-15" && $0.dayKey <= "2026-11-21" }
        let rows = inSpan.flatMap(\.models)
        for agent in outline.roots {
            guard case .agent(let id) = agent.kind else { Issue.record("expected agent rows"); continue }
            let mine = rows.filter { $0.agent == id }
            #expect(mine.reduce(0) { $0 + $1.tally.total } == agent.tokens)
            let costs = mine.compactMap(\.cost)
            #expect((costs.isEmpty ? nil : costs.reduce(0, +)) == agent.cost)
        }
        #expect(rows.reduce(0) { $0 + $1.tally.total } == outline.tokens)
    }

    /// The composer runs on every heartbeat; the section is rebuilt only
    /// when what it is made of changes.
    @Test("the host's memo rebuilds on a changed scan or a new day, not on a heartbeat")
    func memo() throws {
        let harnesses = [HarnessSection(provider: ClaudeProvider()), HarnessSection(provider: CodexProvider())]
        let claudeScan = scan([(0, "opus", 10)])
        func sections(_ codex: SectionConsumption?) -> [ProfileSection] {
            [section(profile("default", "claude"), claudeScan), section(profile("default", "codex"), codex)]
        }
        let cache = AllAgentsCache()
        let first = AllAgentsDigest.build(
            harnesses: harnesses, sections: sections(nil), now: now, calendar: utc, cache: cache)
        #expect(first?.partial == true)
        // A heartbeat later the same day, nothing changed: the memo answers.
        let later = now.addingTimeInterval(3600)
        let heartbeat = AllAgentsDigest.build(
            harnesses: harnesses, sections: sections(nil), now: later, calendar: utc, cache: cache)
        #expect(heartbeat == first)
        // Codex's scan lands: rebuilt.
        let landed = AllAgentsDigest.build(
            harnesses: harnesses, sections: sections(scan([(0, "gpt-5", 5)])), now: later, calendar: utc,
            cache: cache)
        #expect(landed?.partial == false)
        #expect(landed?.activity?.todayTokens == 15)
        // The next day turns "today" over: rebuilt, from the same scans.
        let tomorrow = AllAgentsDigest.build(
            harnesses: harnesses, sections: sections(scan([(0, "gpt-5", 5)])),
            now: now.addingTimeInterval(86400), calendar: utc, cache: cache)
        #expect(tomorrow?.activity?.todayTokens == 0)
    }

    /// Absent ≠ zero for the whole total: while no member is counted (every
    /// first scan still out) there is no total to publish — not a zero one.
    @Test("nobody counted yet: members and partial, no total at all")
    func nobodyCounted() throws {
        let harnesses = [
            HarnessSection(provider: ClaudeProvider()), HarnessSection(provider: CodexProvider()),
            HarnessSection(provider: GeminiProvider()),
        ]
        let sections = [
            section(profile("default", "claude"), nil),
            section(profile("default", "codex"), nil),
            section(profile("default", "gemini"), scan([(0, "gemini-3", 9)])),
        ]
        let all = try #require(AllAgentsDigest.build(harnesses: harnesses, sections: sections, now: now, calendar: utc))
        #expect(all.members.map(\.state) == ["scanning", "scanning", "noTokens"])
        #expect(all.partial)
        #expect(all.countLabel == "0 of 3 agents")
        #expect(all.models == nil)
        #expect(all.activity == nil)
        // Absent on the wire, not zeros.
        let json = try #require(String(data: try JSONEncoder().encode(all), encoding: .utf8))
        #expect(!json.contains("\"activity\""))
        #expect(!json.contains("\"models\""))
    }

    /// Across a DST change the 35-day cut crosses a midnight an hour off
    /// local midnight; the memo keys on where each cut falls, so it can't
    /// keep a day the per-account sections have already dropped.
    @Test("the memo follows each horizon's cut, not only today")
    func memoFollowsTheCuts() throws {
        var zurich = Calendar(identifier: .gregorian)
        zurich.timeZone = TimeZone(identifier: "Europe/Zurich")!
        let harnesses = [HarnessSection(provider: ClaudeProvider()), HarnessSection(provider: CodexProvider())]
        // 2026-03-29 is spring-forward in Zurich; 35 days later is 2026-05-03.
        let start = zurich.date(from: DateComponents(year: 2026, month: 3, day: 28))!
        let edge = zurich.date(from: DateComponents(year: 2026, month: 5, day: 2, hour: 0, minute: 30))!
        let after = zurich.date(from: DateComponents(year: 2026, month: 5, day: 2, hour: 1, minute: 30))!
        func days(_ dates: [Date]) -> SectionConsumption {
            SectionConsumption(
                days: dates.map {
                    var day = DailyActivity(day: $0, tokens: 5, messages: 0, prompts: 0)
                    day.models["opus"] = TokenTally(input: 5, output: 0, cacheCreation: 0, cacheRead: 0)
                    return day
                },
                timeline: [], pricing: PricingTable(rates: [:], fetchedAt: .distantPast, source: .bundled))
        }
        let scans = [
            section(profile("default", "claude"), days([start, zurich.startOfDay(for: edge)])),
            section(profile("default", "codex"), days([zurich.startOfDay(for: edge)])),
        ]
        let cache = AllAgentsCache()
        let cached = { (now: Date) in
            AllAgentsDigest.build(harnesses: harnesses, sections: scans, now: now, calendar: zurich, cache: cache)
        }
        let fresh = { (now: Date) in
            AllAgentsDigest.build(harnesses: harnesses, sections: scans, now: now, calendar: zurich)
        }
        // Same local day both times; whatever the cut does in between, the
        // memo answers what a fresh build would.
        #expect(cached(edge) == fresh(edge))
        #expect(cached(after) == fresh(after))
    }

    @Test("the CLI's membership over a digest matches the writer's")
    func membershipOverADigest() throws {
        let harnesses = [HarnessSection(provider: ClaudeProvider()), HarnessSection(provider: CodexProvider())]
        let state = MeteringDigest.compose(
            harnesses: harnesses,
            sections: [
                section(profile("default", "claude"), scan([(0, "opus", 1)])),
                section(profile("b", "claude"), dormant: true, nil),
                section(profile("default", "codex"), scan([(0, "gpt-5", 1)])),
            ],
            focused: "default", host: "daemon", pid: 1, appVersion: "0", systemAccent: nil,
            activeInterval: 300, appUpdate: nil, nextReprobeAt: nil, now: now, calendar: utc)
        let all = try #require(state.allAgents)
        #expect(ConsumptionMembership.members(of: state).map(\.account) == all.members.map(\.profile))
    }
}
