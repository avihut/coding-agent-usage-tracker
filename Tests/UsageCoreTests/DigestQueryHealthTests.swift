import Foundation
import Testing

@testable import UsageCore

/// The `health` noun, against the same golden fixture every other query test
/// uses — which carries a minor incident in its monitoring phase, one
/// recently-resolved incident, and a scheduled maintenance, so the interesting
/// branches are exercised by the shared contract rather than by a bespoke
/// digest.
@Suite("DigestQuery.health")
struct DigestQueryHealthTests {
    let golden: LiveState
    let goldenRaw: Data
    /// The fixture's own `engine.generatedAt`, as every query suite pins it.
    let now = ISO8601DateFormatter().date(from: "2026-08-16T12:00:00Z")!

    init() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/digest/live-state-v1.json")
        goldenRaw = try Data(contentsOf: fixtureURL)
        golden = try LiveState.decoder().decode(LiveState.self, from: goldenRaw)
    }

    func run(_ args: [String], digest: LiveState? = nil, now: Date? = nil) -> QueryOutput {
        DigestQuery.run(
            arguments: args, digest: digest ?? golden, rawDigest: goldenRaw,
            environment: [:], now: now ?? self.now)
    }

    /// A digest from an engine that publishes no card at all.
    var cardless: LiveState {
        LiveState(
            engine: golden.engine, meters: golden.meters, menuBar: golden.menuBar,
            models: golden.models, activity: golden.activity, sessions: golden.sessions)
    }

    // MARK: - Summary

    @Test("the summary names the incident, its phase, and how long it has run")
    func summary() {
        let out = run(["health"])
        // Started 10:49 against the pinned 12:00 now; checked 11:58:30.
        #expect(
            out.stdout
                == "minor · Degraded performance for multiple models · monitoring · "
                    + "1 hr 11 min · checked 2 min ago")
        #expect(out.exitCode == 0)
        #expect(out.note == nil)
    }

    @Test("fields answer individually")
    func fields() {
        #expect(run(["health", "indicator"]).stdout == "minor")
        #expect(run(["health", "impact"]).stdout == "minor")
        #expect(run(["health", "phase"]).stdout == "monitoring")
        #expect(run(["health", "incident"]).stdout == "Degraded performance for multiple models")
        #expect(
            run(["health", "message"]).stdout
                == "A fix has been implemented and we are monitoring the results.")
        #expect(run(["health", "page-url"]).stdout == "https://status.claude.com")
        #expect(run(["health", "ok"]).stdout == "false")
        #expect(run(["health", "stale"]).stdout == "false")
        // 10:49 → 12:00.
        #expect(run(["health", "duration"]).stdout == "4260")
        #expect(run(["health", "age"]).stdout == "90")
    }

    @Test("--fields builds one row, in the order asked")
    func multiField() {
        let out = run(["health", "--fields", "indicator,phase,duration"])
        #expect(out.stdout == "minor\tmonitoring\t4260")
        #expect(out.exitCode == 0)

        let headed = run(["health", "--fields", "indicator,phase", "--header"])
        #expect(headed.stdout == "indicator\tphase\nminor\tmonitoring")
    }

    @Test("tables come back as their own block")
    func tables() {
        let components = run(["health", "components"])
        #expect(components.stdout.hasPrefix("name\tstatus\n"))
        #expect(components.stdout.contains("claude.ai\tdegraded_performance"))

        let resolved = run(["health", "resolved"])
        #expect(resolved.stdout.contains("Elevated error rates"))

        let maintenances = run(["health", "maintenances"])
        #expect(maintenances.stdout.contains("Scheduled infrastructure maintenance"))

        // A table can't be a cell in a row — refused by name, not by sniffing.
        let mixed = run(["health", "--fields", "indicator,components"])
        #expect(mixed.exitCode == 19)
        #expect(mixed.note?.contains("it's a table") == true)
    }

    // MARK: - --check, the script's branch

    @Test("--check exits 22 while something is open, 0 when nothing is")
    func check() {
        let open = run(["health", "--check"])
        #expect(open.stdout.isEmpty)
        #expect(open.exitCode == 22)

        let calm = run(["health", "--check"], digest: quiet)
        #expect(calm.stdout.isEmpty)
        #expect(calm.exitCode == 0)

        // No card is not an incident: silence and 0, same as healthy.
        let absent = run(["health", "--check"], digest: cardless)
        #expect(absent.stdout.isEmpty)
        #expect(absent.exitCode == 0)
    }

    // MARK: - Absent card

    /// The whole point of the noun's nil-tolerance: a status bar re-running
    /// this every render against an engine that tracks no status must go
    /// quiet, never red, and never claim the service is fine.
    @Test("an absent card prints nothing and still exits 0")
    func absentCard() {
        let summary = run(["health"], digest: cardless)
        #expect(summary.stdout.isEmpty)
        #expect(summary.exitCode == 0)

        let field = run(["health", "indicator"], digest: cardless)
        #expect(field.stdout.isEmpty)
        #expect(field.exitCode == 0)

        #expect(run(["health"], digest: cardless, now: now).stdout != "none")

        let json = run(["health", "--json"], digest: cardless)
        #expect(json.stdout == "null")
        #expect(json.exitCode == 0)

        let table = run(["health", "components"], digest: cardless)
        #expect(table.stdout.isEmpty)
        #expect(table.exitCode == 0)
    }

    // MARK: - Registers

    @Test("--json prints the card, --raw insists on a field")
    func registers() {
        let json = run(["health", "--json"])
        #expect(json.stdout.contains("\"indicator\" : \"minor\""))
        #expect(json.exitCode == 0)

        let raw = run(["health", "--raw"])
        #expect(raw.exitCode == 19)
        #expect(raw.note?.contains("raw needs a field") == true)

        let rawField = run(["health", "indicator", "--raw"])
        #expect(rawField.stdout == "minor")
    }

    @Test("a healthy card says so without inventing an incident")
    func healthy() {
        let out = run(["health"], digest: quiet)
        #expect(out.stdout == "none · All Systems Operational · checked 2 min ago")
        #expect(run(["health", "ok"], digest: quiet).stdout == "true")
        #expect(run(["health", "incident"], digest: quiet).stdout.isEmpty)
        #expect(run(["health", "duration"], digest: quiet).stdout.isEmpty)
        // An empty incident list is not an absent one: the table is legal
        // and empty, and `--json` says so.
        #expect(run(["health", "incidents", "--json"], digest: quiet).stdout == "[\n\n]")
    }

    @Test("an unreachable feed reads as unknown, never as healthy")
    func unknown() {
        let out = run(["health"], digest: unreachable)
        #expect(out.stdout == "unknown · status unavailable · checked 2 min ago")
        #expect(run(["health", "indicator"], digest: unreachable).stdout == "unknown")
        // `ok` goes ABSENT rather than true: an unreachable page has no
        // readable incidents, and "true" would report the service fine on
        // the strength of knowing nothing.
        #expect(run(["health", "ok"], digest: unreachable).stdout.isEmpty)
        // Not knowing is still not an incident, so a script's gate stays open.
        #expect(run(["health", "--check"], digest: unreachable).exitCode == 0)
    }

    @Test("an unknown field enumerates the legal ones")
    func unknownField() {
        let out = run(["health", "bogus"])
        #expect(out.exitCode == 19)
        #expect(out.note?.hasPrefix("health has no field 'bogus'") == true)
        #expect(out.note?.contains("indicator") == true)
        #expect(out.note?.contains("phase") == true)
    }

    @Test("flags that belong to other nouns are still refused")
    func inapplicableFlags() {
        #expect(run(["health", "--all"]).exitCode == 19)
        #expect(run(["health", "--background"]).exitCode == 19)
        #expect(run(["health", "--last", "5"]).exitCode == 19)
    }

    // MARK: - Digest variants

    /// The golden's card with the incident cleared.
    var quiet: LiveState {
        rebuilt(
            ServiceStatusCard(
                providerID: "claude", pageName: "Claude",
                pageURL: "https://status.claude.com", indicator: "none",
                descriptionText: "All Systems Operational",
                checkedAt: golden.serviceStatus!.checkedAt,
                okAt: golden.serviceStatus!.okAt, stale: false,
                components: golden.serviceStatus!.components, incidents: []))
    }

    var unreachable: LiveState {
        rebuilt(
            ServiceStatusCard(
                providerID: "claude", pageName: "Claude",
                pageURL: "https://status.claude.com", indicator: "unknown",
                descriptionText: "",
                checkedAt: golden.serviceStatus!.checkedAt,
                okAt: golden.serviceStatus!.okAt, stale: true,
                components: [], incidents: []))
    }

    private func rebuilt(_ card: ServiceStatusCard) -> LiveState {
        LiveState(
            engine: golden.engine, meters: golden.meters, menuBar: golden.menuBar,
            models: golden.models, activity: golden.activity, sessions: golden.sessions,
            serviceStatus: card)
    }
}
