import Foundation
import Testing
@testable import UsageCore

@Suite("Session ordering and search")
struct SessionOrderingTests {
    private func session(
        _ id: String, title: String, end: TimeInterval, tokens: Int = 0,
        path: String? = nil, branch: String? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id, title: title, projectPath: path, gitBranch: branch,
            agentVersion: nil, kind: .interactive,
            start: Date(timeIntervalSinceReferenceDate: end - 60),
            end: Date(timeIntervalSinceReferenceDate: end),
            activeSeconds: 60, prompts: 1, apiCalls: 1, toolCalls: 0,
            subagentCount: 0, compactions: 0,
            models: tokens > 0 ? ["m": TokenTally(input: tokens, output: 0)] : [:])
    }

    @Test("recency: newest first by default, ascending reverses")
    func recency() {
        let sessions = [
            session("a", title: "A", end: 100),
            session("b", title: "B", end: 300),
            session("c", title: "C", end: 200),
        ]
        let desc = SessionOrdering.sorted(sessions, by: .recency, ascending: false) { _ in nil }
        #expect(desc.map(\.id) == ["b", "c", "a"])
        let asc = SessionOrdering.sorted(sessions, by: .recency, ascending: true) { _ in nil }
        #expect(asc.map(\.id) == ["a", "c", "b"])
    }

    @Test("name: natural, case-insensitive; ties break newest-first")
    func names() {
        let sessions = [
            session("ten", title: "chat 10", end: 100),
            session("two", title: "chat 2", end: 200),
            session("alpha", title: "Alpha", end: 50),
            session("twinOld", title: "twin", end: 300),
            session("twinNew", title: "twin", end: 400),
        ]
        let asc = SessionOrdering.sorted(sessions, by: .name, ascending: true) { _ in nil }
        #expect(asc.map(\.id) == ["alpha", "two", "ten", "twinNew", "twinOld"])
        let desc = SessionOrdering.sorted(sessions, by: .name, ascending: false) { _ in nil }
        #expect(desc.map(\.id) == ["twinNew", "twinOld", "ten", "two", "alpha"])
    }

    @Test("tokens: both directions; ties break newest-first")
    func tokens() {
        let sessions = [
            session("small", title: "s", end: 100, tokens: 10),
            session("bigOld", title: "b1", end: 200, tokens: 500),
            session("bigNew", title: "b2", end: 300, tokens: 500),
            session("mid", title: "m", end: 400, tokens: 40),
        ]
        let desc = SessionOrdering.sorted(sessions, by: .tokens, ascending: false) { _ in nil }
        #expect(desc.map(\.id) == ["bigNew", "bigOld", "mid", "small"])
        let asc = SessionOrdering.sorted(sessions, by: .tokens, ascending: true) { _ in nil }
        #expect(asc.map(\.id) == ["small", "mid", "bigNew", "bigOld"])
    }

    @Test("cost: absent sinks to the end under BOTH directions")
    func costs() {
        let sessions = [
            session("free", title: "f", end: 500),
            session("cheap", title: "c", end: 100),
            session("dear", title: "d", end: 200),
        ]
        let cost: (SessionSummary) -> Double? = { s in
            switch s.id {
            case "cheap": 0.5
            case "dear": 9.0
            default: nil
            }
        }
        let desc = SessionOrdering.sorted(sessions, by: .cost, ascending: false, costOf: cost)
        #expect(desc.map(\.id) == ["dear", "cheap", "free"])
        let asc = SessionOrdering.sorted(sessions, by: .cost, ascending: true, costOf: cost)
        #expect(asc.map(\.id) == ["cheap", "dear", "free"])
    }

    @Test("search matches title, path, branch, and id, case-insensitively")
    func search() {
        let s = session(
            "ABC123-uuid", title: "Fix the meter hover", end: 0,
            path: "/Users/x/Projects/claude-usage-menubar/main", branch: "feature/hover")
        #expect(SessionOrdering.matches(s, query: ""))
        #expect(SessionOrdering.matches(s, query: "   "))
        #expect(SessionOrdering.matches(s, query: "METER"))
        #expect(SessionOrdering.matches(s, query: "usage-menubar"))
        #expect(SessionOrdering.matches(s, query: "feature/ho"))
        #expect(SessionOrdering.matches(s, query: "abc123"))
        #expect(!SessionOrdering.matches(s, query: "prices"))
    }
}
