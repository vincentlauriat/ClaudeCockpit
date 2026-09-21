import XCTest
@testable import QuotaKit

final class QuotaServiceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_789_128_000)

    private func service(_ outcomes: [Result<GaugeSnapshot, any Error>],
                         clock: TestClock,
                         credentials: StubCredentials = StubCredentials())
        -> (QuotaService, StubQuotaAPI) {
        let api = StubQuotaAPI(outcomes: outcomes)
        let service = QuotaService(credentials: credentials, api: api,
                                   minimumSpacing: 180, backoffAfter429: 900,
                                   clock: { clock.now })
        return (service, api)
    }

    func testFirstRefreshHitsTheAPIAndCaches() async throws {
        let clock = TestClock(start)
        let snapshot = makeSnapshot(fetchedAt: start, weekUtilization: 42)
        let (service, api) = service([.success(snapshot)], clock: clock)

        let result = try await service.refresh()
        XCTAssertEqual(result.week?.utilization, 42)
        await assertCalls(api, 1)
        await AssertEqualAsync(await service.lastSnapshot, snapshot)
        await AssertNilAsync(await service.lastError)
        let next = await service.nextAllowedRefresh
        XCTAssertEqual(next, start.addingTimeInterval(180))
    }

    func testSecondCallWithinTheSpacingReturnsTheCache() async throws {
        let clock = TestClock(start)
        let first = makeSnapshot(fetchedAt: start, weekUtilization: 42)
        let (service, api) = service([.success(first)], clock: clock)

        _ = try await service.refresh()
        clock.advance(60)
        let cached = try await service.refresh()

        XCTAssertEqual(cached, first, "a call 1 min later must not hit the network")
        await assertCalls(api, 1)
    }

    func testCallAfterTheSpacingHitsTheAPIAgain() async throws {
        let clock = TestClock(start)
        let first = makeSnapshot(fetchedAt: start, weekUtilization: 42)
        let second = makeSnapshot(fetchedAt: start.addingTimeInterval(200), weekUtilization: 43)
        let (service, api) = service([.success(first), .success(second)], clock: clock)

        _ = try await service.refresh()
        clock.advance(200)
        let result = try await service.refresh()

        XCTAssertEqual(result, second)
        await assertCalls(api, 2)
    }

    func testForceJumpsTheSpacing() async throws {
        let clock = TestClock(start)
        let first = makeSnapshot(fetchedAt: start, weekUtilization: 42)
        let second = makeSnapshot(fetchedAt: start.addingTimeInterval(10), weekUtilization: 44)
        let (service, api) = service([.success(first), .success(second)], clock: clock)

        _ = try await service.refresh()
        clock.advance(10)
        let forced = try await service.refresh(force: true)

        XCTAssertEqual(forced, second)
        await assertCalls(api, 2)
    }

    func testForceStillHonoursTheTenSecondFloor() async throws {
        let clock = TestClock(start)
        let first = makeSnapshot(fetchedAt: start, weekUtilization: 42)
        let (service, api) = service([.success(first)], clock: clock)

        _ = try await service.refresh()
        clock.advance(2)
        let cached = try await service.refresh(force: true)

        XCTAssertEqual(cached, first, "a double-tap on the refresh button must not call twice")
        await assertCalls(api, 1)
    }

    func testRateLimitStartsABackoffThatEvenForceRespects() async throws {
        let clock = TestClock(start)
        let first = makeSnapshot(fetchedAt: start, weekUtilization: 42)
        let (service, api) = service([.success(first),
                                      .failure(QuotaError.rateLimited(retryAfter: nil))],
                                     clock: clock)

        _ = try await service.refresh()
        clock.advance(200)
        await XCTAssertThrowsErrorAsync(try await service.refresh()) { error in
            XCTAssertEqual(error as? QuotaError, .rateLimited(retryAfter: nil))
        }
        await assertCalls(api, 2)

        let next = await service.nextAllowedRefresh
        XCTAssertEqual(next, start.addingTimeInterval(200 + 900))

        // Forcing during the backoff is refused and serves the last good snapshot.
        clock.advance(300)
        let cached = try await service.refresh(force: true)
        XCTAssertEqual(cached, first, "the failed read must not drop the cached snapshot")
        await assertCalls(api, 2, "no network call while the 429 backoff runs")
    }

    func testRefreshResumesOnceTheBackoffElapsed() async throws {
        let clock = TestClock(start)
        let first = makeSnapshot(fetchedAt: start, weekUtilization: 42)
        let recovered = makeSnapshot(fetchedAt: start.addingTimeInterval(1100), weekUtilization: 50)
        let (service, api) = service([.success(first),
                                      .failure(QuotaError.rateLimited(retryAfter: nil)),
                                      .success(recovered)],
                                     clock: clock)

        _ = try await service.refresh()
        clock.advance(200)
        await XCTAssertThrowsErrorAsync(try await service.refresh())

        clock.advance(901)
        let result = try await service.refresh()
        XCTAssertEqual(result, recovered)
        await assertCalls(api, 3)
        await AssertNilAsync(await service.lastError)
    }

    func testRetryAfterLongerThanTheDefaultBackoffWins() async throws {
        let clock = TestClock(start)
        let (service, api) = service([.failure(QuotaError.rateLimited(retryAfter: 1800))],
                                     clock: clock)

        await XCTAssertThrowsErrorAsync(try await service.refresh())
        let next = await service.nextAllowedRefresh
        XCTAssertEqual(next, start.addingTimeInterval(1800))
        await assertCalls(api, 1)
    }

    func testThrottledWithoutAnyCachedSnapshot() async {
        let clock = TestClock(start)
        let (service, api) = service([.failure(QuotaError.http(500))], clock: clock)

        await XCTAssertThrowsErrorAsync(try await service.refresh()) { error in
            XCTAssertEqual(error as? QuotaError, .http(500))
        }
        clock.advance(10)
        await XCTAssertThrowsErrorAsync(try await service.refresh()) { error in
            XCTAssertEqual(error as? QuotaError,
                           .throttled(until: self.start.addingTimeInterval(180)))
        }
        await assertCalls(api, 1)
    }

    func testNonRateLimitFailureStillAllowsAForcedRetry() async throws {
        let clock = TestClock(start)
        let recovered = makeSnapshot(fetchedAt: start.addingTimeInterval(5), weekUtilization: 7)
        let (service, api) = service([.failure(QuotaError.http(500)), .success(recovered)],
                                     clock: clock)

        await XCTAssertThrowsErrorAsync(try await service.refresh())
        clock.advance(10)
        let result = try await service.refresh(force: true)
        XCTAssertEqual(result, recovered)
        await assertCalls(api, 2)
    }

    func testCredentialFailureIsReportedAndSpacedLikeAnyOtherError() async {
        let clock = TestClock(start)
        let credentials = StubCredentials(token: "", failure: CredentialError.expired)
        let (service, api) = service([], clock: clock, credentials: credentials)

        await XCTAssertThrowsErrorAsync(try await service.refresh()) { error in
            XCTAssertEqual(error as? CredentialError, .expired)
        }
        await assertCalls(api, 0, "no network call without a token")
        let message = await service.lastError
        XCTAssertEqual(message, CredentialError.expired.errorDescription)
    }

    func testConcurrentCallersShareOneNetworkRead() async throws {
        let clock = TestClock(start)
        let snapshot = makeSnapshot(fetchedAt: start, weekUtilization: 42)
        let (service, api) = service([.success(snapshot)], clock: clock)

        async let a = service.refresh()
        async let b = service.refresh()
        let results = try await [a, b]

        XCTAssertEqual(results, [snapshot, snapshot])
        await assertCalls(api, 1)
    }
}

// MARK: - Async assertion helpers

func AssertEqualAsync<T: Equatable>(_ value: T?, _ expected: T?,
                                    file: StaticString = #filePath, line: UInt = #line) async {
    XCTAssertEqual(value, expected, file: file, line: line)
}

/// Reads the actor-isolated call counter of the stubbed gauge client.
func assertCalls(_ api: StubQuotaAPI, _ expected: Int, _ message: String = "",
                 file: StaticString = #filePath, line: UInt = #line) async {
    let calls = await api.calls
    XCTAssertEqual(calls, expected, message, file: file, line: line)
}

func AssertNilAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async {
    XCTAssertNil(value, file: file, line: line)
}
