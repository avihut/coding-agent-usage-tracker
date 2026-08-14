import Foundation
import Testing
@testable import UsageCore

@Suite("UsageService pipeline")
struct UsageServiceTests {
    @Test("success: live state, cache written")
    func liveSuccess() async {
        let token = uniqueToken()
        let cache = temporaryCache()
        StubURLProtocol.register(token: token) { _ in (200, loadFixture("real-2026-08-07")) }

        let state = await makeService(token: token, cache: cache).refresh()

        #expect(!state.isStale)
        #expect(state.snapshot?.summary == MenuBarSummary(session: 6, weeklyAll: 17, scopedMax: 22, worstLevel: .normal))
        #expect(cache.load() != nil)
    }

    @Test("transport failure falls back to cached snapshot, greyed")
    func cachedFallback() async {
        let token = uniqueToken()
        let cache = temporaryCache()
        let service = makeService(token: token, cache: cache)
        StubURLProtocol.register(token: token) { _ in (200, loadFixture("real-2026-08-07")) }
        _ = await service.refresh()

        StubURLProtocol.register(token: token) { _ in throw URLError(.notConnectedToInternet) }
        let state = await service.refresh()

        guard case .cached(let snapshot, let error) = state else {
            Issue.record("expected cached, got \(state)")
            return
        }
        #expect(error == .network)
        #expect(snapshot.summary.session == 6)
        #expect(state.isStale)
    }

    @Test("transport failure with no cache is unavailable but readable")
    func unavailableWithoutCache() async {
        let token = uniqueToken()
        StubURLProtocol.register(token: token) { _ in throw URLError(.notConnectedToInternet) }
        let state = await makeService(token: token, cache: temporaryCache()).refresh()
        #expect(state == .unavailable(.network))
        #expect(state.error?.shortText.isEmpty == false)
    }

    @Test("missing credentials surface as noCredentials without any request")
    func noCredentials() async {
        let token = uniqueToken()
        let requests = Box(0)
        StubURLProtocol.register(token: token) { _ in
            requests.mutate { $0 += 1 }
            return (200, Data())
        }
        let state = await makeService(token: token, credential: .failure(.notFound), cache: temporaryCache()).refresh()
        #expect(state == .unavailable(.noCredentials))
        #expect(requests.value == 0)
    }

    @Test("keychain denial is its own readable state")
    func keychainDenied() async {
        let state = await makeService(
            token: uniqueToken(), credential: .failure(.accessDenied(-128)), cache: temporaryCache()
        ).refresh()
        #expect(state == .unavailable(.keychainDenied))
    }

    @Test("retries exactly once on transport failure")
    func retriesOnceOnTransport() async {
        let token = uniqueToken()
        let attempts = Box(0)
        StubURLProtocol.register(token: token) { _ in
            var current = 0
            attempts.mutate { $0 += 1; current = $0 }
            if current == 1 { throw URLError(.timedOut) }
            return (200, loadFixture("real-2026-08-07"))
        }
        let state = await makeService(token: token, cache: temporaryCache()).refresh()
        #expect(!state.isStale)
        #expect(attempts.value == 2)
    }

    @Test("does not retry auth failures")
    func noRetryOnAuthFailure() async {
        let token = uniqueToken()
        let attempts = Box(0)
        StubURLProtocol.register(token: token) { _ in
            attempts.mutate { $0 += 1 }
            return (401, Data())
        }
        let state = await makeService(token: token, cache: temporaryCache()).refresh()
        #expect(state == .unavailable(.signInExpired))
        #expect(attempts.value == 1)
    }

    @Test("429 is not retried and surfaces as rateLimited")
    func rateLimitedNoRetry() async {
        let token = uniqueToken()
        let attempts = Box(0)
        StubURLProtocol.registerWithHeaders(token: token) { _ in
            attempts.mutate { $0 += 1 }
            return (429, Data(), ["Retry-After": "120"])
        }
        let state = await makeService(token: token, cache: temporaryCache()).refresh()
        #expect(state == .unavailable(.rateLimited(retryAfter: 120)))
        #expect(attempts.value == 1)
    }

    @Test("undecodable 200 body degrades to schema error")
    func schemaDrift() async {
        let token = uniqueToken()
        StubURLProtocol.register(token: token) { _ in (200, Data("<html>maintenance</html>".utf8)) }
        let state = await makeService(token: token, cache: temporaryCache()).refresh()
        #expect(state == .unavailable(.schema))
    }
}

@Suite("TriggerGate")
struct TriggerGateTests {
    @Test("first trigger allowed, repeats gated, allowed again after interval")
    func gating() {
        var gate = TriggerGate(minimumInterval: 60)
        let t0 = Date(timeIntervalSince1970: 1000)
        let results = [
            gate.shouldAllow(at: t0),
            gate.shouldAllow(at: t0.addingTimeInterval(30)),
            gate.shouldAllow(at: t0.addingTimeInterval(59)),
            gate.shouldAllow(at: t0.addingTimeInterval(61)),
        ]
        #expect(results == [true, false, false, true])
    }
}

@Suite("Formatting")
struct FormattingTests {
    @Test("menu bar segments from real payload")
    func segments() throws {
        let meters = MeterBuilder.meters(from: try UsageResponse.decode(from: loadFixture("real-2026-08-07")))
        let segments = UsageFormatting.menuBarSegments(from: meters)
        #expect(segments.map(\.percent) == [6, 17, 22])
        #expect(segments.map(\.tag) == ["S", "W", "F"])
        #expect(segments.allSatisfy { $0.level == .normal })
    }

    @Test("segments tolerate missing meters")
    func segmentsPartial() throws {
        let meters = MeterBuilder.meters(from: try UsageResponse.decode(from: loadFixture("unknown-kind")))
        let segments = UsageFormatting.menuBarSegments(from: meters)
        #expect(segments.map(\.percent) == [nil, nil, 63])
        #expect(segments.map(\.tag) == ["S", "W", "L"])
    }

    @Test("reset text under 24h is relative")
    func resetRelative() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(UsageFormatting.resetText(now.addingTimeInterval(3 * 3600 + 20 * 60), now: now) == "resets in 3h 20m")
        #expect(UsageFormatting.resetText(now.addingTimeInterval(35 * 60), now: now) == "resets in 35m")
        #expect(UsageFormatting.resetText(now.addingTimeInterval(2 * 3600), now: now) == "resets in 2h")
        #expect(UsageFormatting.resetText(now.addingTimeInterval(-5), now: now) == "resets soon")
    }

    @Test("exhaust text speaks resetText's exact tiers with its own verb")
    func exhaustPhrase() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(UsageFormatting.exhaustText(now.addingTimeInterval(2 * 3600 + 10 * 60), now: now) == "runs out in 2h 10m")
        #expect(UsageFormatting.exhaustText(now.addingTimeInterval(45 * 60), now: now) == "runs out in 45m")
        #expect(UsageFormatting.exhaustText(now.addingTimeInterval(-1), now: now) == "runs out soon")
        // Beyond a day both phrases go weekday-absolute (epoch is a Thursday).
        let utc = TimeZone(identifier: "UTC")!
        let posix = Locale(identifier: "en_US_POSIX")
        let far = now.addingTimeInterval(30 * 3600)
        #expect(UsageFormatting.exhaustText(far, now: now, timeZone: utc, locale: posix) == "runs out Fri 06:00")
        #expect(UsageFormatting.resetText(far, now: now, timeZone: utc, locale: posix) == "resets Fri 06:00")
    }

    @Test("segments carry each meter's prediction severity")
    func segmentsSeverity() throws {
        let meters = MeterBuilder.meters(from: try UsageResponse.decode(from: loadFixture("real-2026-08-07")))
        let now = Date(timeIntervalSince1970: 0)
        let predictions = [
            // Burns through the limit before reset — severity pegged at 1.
            "Session (5h)": PredictionEngine.prediction(
                percent: 80, resetsAt: now.addingTimeInterval(2 * 3600), ratePerHour: 20, now: now),
            // Projected 90 at reset — a third of the way up the 85→100 ramp.
            "Weekly · Fable": PredictionEngine.prediction(
                percent: 60, resetsAt: now.addingTimeInterval(3 * 3600), ratePerHour: 10, now: now),
        ]
        let segments = UsageFormatting.menuBarSegments(from: meters, predictions: predictions)
        #expect(segments[0].severity == 1)
        #expect(segments[1].severity == nil)
        #expect(abs((segments[2].severity ?? 0) - 1.0 / 3.0) < 0.0001)
    }

    @Test("reset text beyond 24h is weekday + time")
    func resetAbsolute() {
        let now = Date(timeIntervalSince1970: 0)                       // Thu 1970-01-01
        let reset = Date(timeIntervalSince1970: 2 * 86400 + 14 * 3600) // Sat 1970-01-03 14:00 UTC
        let text = UsageFormatting.resetText(
            reset, now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            locale: Locale(identifier: "en_US_POSIX")
        )
        #expect(text == "resets Sat 14:00")
    }

    @Test("clock time")
    func clock() {
        let date = Date(timeIntervalSince1970: 14 * 3600 + 5 * 60)
        #expect(UsageFormatting.clockTime(date, timeZone: TimeZone(secondsFromGMT: 0)!) == "14:05")
    }

    @Test("next-update countdown")
    func countdown() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(UsageFormatting.countdownText(to: now.addingTimeInterval(272), now: now) == "next in 4m 32s")
        #expect(UsageFormatting.countdownText(to: now.addingTimeInterval(45), now: now) == "next in 45s")
        #expect(UsageFormatting.countdownText(to: now.addingTimeInterval(3900), now: now) == "next in 1h 5m")
        #expect(UsageFormatting.countdownText(to: now.addingTimeInterval(-3), now: now) == "next any moment")
    }
}
