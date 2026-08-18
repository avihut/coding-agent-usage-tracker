import Foundation
import Testing

@testable import UsageCore

/// The Statuspage adapter against REAL captured payloads: the healthy page as
/// served on 2026-08-19, and the actual 2026-08-18 "Degraded performance for
/// multiple models" incident rewound to its monitoring phase. Fixtures beat
/// hand-written JSON here — the shape that matters is the one Atlassian
/// actually sends, including the fields we deliberately ignore.
@Suite("Statuspage adapter")
struct StatuspageFeedTests {
    static func fixture(_ name: String) throws -> StatuspageSummary {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/status/\(name).json")
        return try StatuspageSummary.decode(from: Data(contentsOf: url))
    }

    static func card(
        _ name: String, checkedAt: Date = Date(timeIntervalSince1970: 1_787_000_000)
    ) throws -> ServiceStatusCard {
        StatuspageAdapter.card(
            from: try fixture(name), providerID: "claude",
            pageURL: "https://status.claude.com", checkedAt: checkedAt,
            okAt: checkedAt, stale: false)
    }

    @Test("a healthy page reads as none, with every component operational")
    func healthy() throws {
        let card = try Self.card("summary-healthy")

        #expect(card.indicatorValue == .none)
        #expect(card.descriptionText == "All Systems Operational")
        #expect(card.pageName == "Claude")
        #expect(card.pageURL == "https://status.claude.com")
        #expect(card.components.count == 6)
        #expect(card.components.filter { !$0.isOperational }.isEmpty)
        #expect(card.components.map(\.name).contains("Claude Code"))
        #expect(!card.hasIncident)
        #expect(card.activeIncident == nil)
        #expect(card.maintenances.isEmpty)
    }

    @Test("an incident arrives with its phase, newest message, and components")
    func incident() throws {
        let card = try Self.card("summary-incident")

        #expect(card.indicatorValue == .minor)
        #expect(card.hasIncident)
        let incident = try #require(card.activeIncident)
        #expect(incident.name == "Degraded performance for multiple models")
        #expect(incident.impact == "minor")
        #expect(incident.phase == "monitoring")
        // The NEWEST update, not the first one posted — the feed lists them
        // newest-first, but nothing in the format guarantees that.
        #expect(incident.lastMessage?.hasPrefix("A fix has been implemented") == true)
        #expect(incident.componentNames.contains("Claude API (api.anthropic.com)"))
        #expect(incident.url == "https://stspg.io/tcsfmtc03xgm")
        #expect(incident.resolvedAt == nil)

        // Degraded components come through with the page's own vocabulary.
        let degraded = card.components.filter { !$0.isOperational }
        #expect(degraded.count == 3)
        #expect(Set(degraded.map(\.status)) == ["degraded_performance"])
        #expect(degraded.first?.displayStatus == "Degraded performance")
    }

    @Test("incident duration counts from its start until now")
    func duration() throws {
        let card = try Self.card("summary-incident")
        let incident = try #require(card.activeIncident)
        // The real incident started 16:20:22Z on 2026-08-18.
        let now = incident.startedAt.addingTimeInterval(4_320)  // 1h 12m
        #expect(abs(incident.duration(now: now) - 4_320) < 1)
        // A resolved incident stops counting at its resolution.
        let resolved = StatusIncident(
            id: "x", name: "n", impact: "minor", phase: "resolved",
            startedAt: incident.startedAt, lastUpdateAt: nil, lastMessage: nil,
            url: nil, componentNames: [], resolvedAt: incident.startedAt.addingTimeInterval(600))
        #expect(resolved.duration(now: now) == 600)
    }

    @Test("an in-progress maintenance reads as maintenance, never as an incident")
    func maintenance() throws {
        let card = try Self.card("summary-maintenance")

        // The page itself still says "none"; an active window makes it blue.
        #expect(card.indicatorValue == .maintenance)
        #expect(!card.hasIncident, "maintenance must never light the incident surfaces")
        #expect(card.maintenances.count == 1)
        let window = try #require(card.maintenances.first)
        #expect(window.isActive)
        #expect(window.name == "Scheduled infrastructure maintenance")
        #expect(window.windowStart != nil)
        #expect(window.windowEnd != nil)
    }

    @Test("malformed bytes throw instead of producing a card")
    func malformed() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/status/malformed.json")
        let data = try Data(contentsOf: url)
        #expect(throws: (any Error).self) {
            try StatuspageSummary.decode(from: data)
        }
    }

    @Test("resolved incidents never appear as active")
    func resolvedAreFiltered() throws {
        // The captured incident, as originally served: resolved.
        let json = """
            {"page": {"name": "Claude", "url": "https://status.claude.com"},
             "status": {"indicator": "none", "description": "All Systems Operational"},
             "components": [],
             "incidents": [{"id": "q7txxvbsftgq", "name": "Degraded performance",
                            "status": "resolved", "impact": "minor",
                            "created_at": "2026-08-18T16:20:22.240Z",
                            "started_at": "2026-08-18T16:20:22.231Z",
                            "resolved_at": "2026-08-18T19:01:45.447Z",
                            "incident_updates": []}],
             "scheduled_maintenances": []}
            """
        let page = try StatuspageSummary.decode(from: Data(json.utf8))
        let card = StatuspageAdapter.card(
            from: page, providerID: "claude", pageURL: "https://status.claude.com",
            checkedAt: Date(), okAt: Date(), stale: false)

        #expect(!card.hasIncident)
        #expect(card.indicatorValue == .none)
    }

    @Test("worst impact leads when several incidents are open")
    func worstFirst() throws {
        let json = """
            {"page": {"name": "Claude", "url": "https://status.claude.com"},
             "status": {"indicator": "minor", "description": "Partially Degraded Service"},
             "components": [],
             "incidents": [
               {"id": "a", "name": "Small thing", "status": "investigating", "impact": "minor",
                "started_at": "2026-08-18T16:00:00.000Z", "incident_updates": []},
               {"id": "b", "name": "Big thing", "status": "identified", "impact": "critical",
                "started_at": "2026-08-18T17:00:00.000Z", "incident_updates": []}],
             "scheduled_maintenances": []}
            """
        let page = try StatuspageSummary.decode(from: Data(json.utf8))
        let card = StatuspageAdapter.card(
            from: page, providerID: "claude", pageURL: "https://status.claude.com",
            checkedAt: Date(), okAt: Date(), stale: false)

        #expect(card.activeIncident?.id == "b")
        // A page under-reporting its own indicator must not silence the
        // loud surfaces — the worst open incident wins.
        #expect(card.indicatorValue == .critical)
    }

    @Test("group headers and healthy hidden components stay out of the list")
    func componentFiltering() throws {
        let json = """
            {"page": {"name": "Claude", "url": "https://status.claude.com"},
             "status": {"indicator": "none", "description": "All Systems Operational"},
             "components": [
               {"name": "Group", "status": "operational", "group": true},
               {"name": "Visible", "status": "operational", "group": false},
               {"name": "Hidden when fine", "status": "operational",
                "only_show_if_degraded": true, "group": false},
               {"name": "Hidden but broken", "status": "major_outage",
                "only_show_if_degraded": true, "group": false}],
             "incidents": [], "scheduled_maintenances": []}
            """
        let page = try StatuspageSummary.decode(from: Data(json.utf8))
        let card = StatuspageAdapter.card(
            from: page, providerID: "claude", pageURL: "https://status.claude.com",
            checkedAt: Date(), okAt: Date(), stale: false)

        #expect(card.components.map(\.name) == ["Visible", "Hidden but broken"])
    }

    @Test("an unrecognized indicator reads as unknown, never as healthy")
    func unknownIndicator() {
        #expect(ServiceStatusCard.Indicator.parse("some_future_state") == .unknown)
        #expect(ServiceStatusCard.Indicator.parse("critical") == .critical)
        // Ranking: unknown never outranks a real observation.
        #expect(ServiceStatusCard.Indicator.unknown.rank < ServiceStatusCard.Indicator.none.rank)
        #expect(ServiceStatusCard.Indicator.critical.rank > ServiceStatusCard.Indicator.major.rank)
        #expect(ServiceStatusCard.Indicator.minor.rank > ServiceStatusCard.Indicator.maintenance.rank)
    }

    /// Decision D2, pinned where all three faces read it: any unresolved
    /// incident shouts (minor included), and nothing else does.
    @Test("only unresolved incidents are loud enough to badge")
    func alarmingImpact() throws {
        #expect(try Self.card("summary-healthy").alarmingImpact == nil)
        #expect(try Self.card("summary-incident").alarmingImpact == .minor)
        // Expected work is not an alarm, and neither is a failed reading.
        #expect(try Self.card("summary-maintenance").alarmingImpact == nil)

        let unknown = ServiceStatusCard(
            providerID: "claude", pageName: "Claude", pageURL: "u",
            indicator: "unknown", descriptionText: "", checkedAt: Date(), okAt: nil,
            stale: true, components: [], incidents: [])
        #expect(unknown.alarmingImpact == nil)

        for impact in ["minor", "major", "critical"] {
            let card = ServiceStatusCard(
                providerID: "claude", pageName: "Claude", pageURL: "u",
                indicator: impact, descriptionText: "", checkedAt: Date(), okAt: Date(),
                stale: false, components: [],
                incidents: [
                    StatusIncident(
                        id: "i", name: "n", impact: impact, phase: "investigating",
                        startedAt: Date(), lastUpdateAt: nil, lastMessage: nil, url: nil,
                        componentNames: [])
                ])
            #expect(card.alarmingImpact == ServiceStatusCard.Indicator.parse(impact))
        }
    }

    @Test("the feed asks exactly one endpoint")
    func endpoint() {
        let feed = StatuspageFeed(base: URL(string: "https://status.claude.com")!)
        #expect(feed.summaryURL.absoluteString == "https://status.claude.com/api/v2/summary.json")
    }
}
