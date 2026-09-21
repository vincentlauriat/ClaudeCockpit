import XCTest
@testable import QuotaKit

/// A representative payload of `GET /api/oauth/usage`, reconstructed from the way the
/// ClaudeMenu client parses it: two known windows, per-model windows with unfamiliar
/// names, one model window without `resets_at`, a spend meter to ignore and a
/// non-meter object.
private let samplePayload = """
{
  "five_hour":       { "utilization": 54.0, "resets_at": "2026-09-21T20:00:00Z" },
  "seven_day":       { "utilization": 84.5, "resets_at": "2026-09-24T20:00:00.123Z" },
  "seven_day_opus":  { "utilization": 12,   "resets_at": "2026-09-24T20:00:00Z" },
  "seven_day_fable": { "utilization": 74.25, "resets_at": "2026-09-24T20:00:00Z" },
  "seven_day_nimbus_quill": { "utilization": 3.5 },
  "extra_usage":     { "utilization": 10.0 },
  "account":         { "tier": "max" }
}
"""

final class QuotaAPITests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_790_000_000)

    private func parseSample() throws -> GaugeSnapshot {
        try QuotaAPI.parse(Data(samplePayload.utf8), fetchedAt: fetchedAt)
    }

    func testDecodesSessionAndWeeklyMeters() throws {
        let snapshot = try parseSample()
        XCTAssertEqual(snapshot.fetchedAt, fetchedAt)

        let session = try XCTUnwrap(snapshot.session)
        XCTAssertEqual(session.key, "five_hour")
        XCTAssertEqual(session.name, "session")
        XCTAssertEqual(session.utilization, 54, accuracy: 0.001)
        XCTAssertEqual(session.windowHours, 5)
        XCTAssertTrue(session.isSession)
        XCTAssertEqual(session.resetsAt, ISO8601Date.parse("2026-09-21T20:00:00Z"))

        let week = try XCTUnwrap(snapshot.week)
        XCTAssertEqual(week.name, "all")
        XCTAssertEqual(week.utilization, 84.5, accuracy: 0.001)
        XCTAssertEqual(week.windowHours, 168)
        // Fractional seconds must parse too.
        XCTAssertNotNil(week.resetsAt)
        XCTAssertFalse(week.isSession)
    }

    func testModelMetersAreNamedSortedAndKeepMissingResetDates() throws {
        let snapshot = try parseSample()
        XCTAssertEqual(snapshot.models.map(\.name), ["fable", "nimbus_quill", "opus"])
        XCTAssertEqual(snapshot.models.allSatisfy { $0.windowHours == 168 }, true)

        let quill = try XCTUnwrap(snapshot.models.first { $0.name == "nimbus_quill" })
        XCTAssertNil(quill.resetsAt, "a model window without resets_at must still be reported")
        XCTAssertEqual(quill.utilization, 3.5, accuracy: 0.001)
    }

    func testSpendMeterAndNonMeterObjectsAreIgnored() throws {
        let snapshot = try parseSample()
        XCTAssertFalse(snapshot.models.contains { $0.key == "extra_usage" })
        XCTAssertFalse(snapshot.models.contains { $0.key == "account" })
    }

    func testWeeklyMetersPutAllFirst() throws {
        let snapshot = try parseSample()
        XCTAssertEqual(snapshot.weeklyMeters.map(\.name), ["all", "fable", "nimbus_quill", "opus"])
    }

    func testPayloadWithoutKnownWindowIsMalformed() {
        let body = Data(#"{"seven_day_opus": {"utilization": 12}}"#.utf8)
        XCTAssertThrowsError(try QuotaAPI.parse(body, fetchedAt: fetchedAt)) { error in
            XCTAssertEqual(error as? QuotaError, .malformed)
        }
    }

    func testGarbageBodyIsMalformed() {
        XCTAssertThrowsError(try QuotaAPI.parse(Data("nope".utf8), fetchedAt: fetchedAt)) { error in
            XCTAssertEqual(error as? QuotaError, .malformed)
        }
    }

    func testStatusMapping() {
        XCTAssertEqual(QuotaAPI.error(status: 401, headers: [:]), .unauthorized)
        XCTAssertEqual(QuotaAPI.error(status: 429, headers: [:]), .rateLimited(retryAfter: nil))
        XCTAssertEqual(QuotaAPI.error(status: 429, headers: ["Retry-After": "42"]),
                       .rateLimited(retryAfter: 42))
        XCTAssertEqual(QuotaAPI.error(status: 429, headers: ["retry-after": "42"]),
                       .rateLimited(retryAfter: 42))
        XCTAssertEqual(QuotaAPI.error(status: 503, headers: [:]), .http(503))
    }

    // MARK: - End-to-end through a stubbed URLSession

    private func session(status: Int, body: Data, headers: [String: String] = [:]) -> URLSession {
        StubURLProtocol.respond { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testFetchSendsExpectedHeadersAndDecodes() async throws {
        let api = QuotaAPI(session: session(status: 200, body: Data(samplePayload.utf8)))
        let snapshot = try await api.fetch(token: "secret")
        XCTAssertEqual(snapshot.week?.utilization, 84.5)
    }

    func testFetchMapsUnauthorized() async {
        let api = QuotaAPI(session: session(status: 401, body: Data()))
        await XCTAssertThrowsErrorAsync(try await api.fetch(token: "secret")) { error in
            XCTAssertEqual(error as? QuotaError, .unauthorized)
        }
    }

    func testFetchMapsRateLimitWithRetryAfter() async {
        let api = QuotaAPI(session: session(status: 429, body: Data(),
                                            headers: ["Retry-After": "30"]))
        await XCTAssertThrowsErrorAsync(try await api.fetch(token: "secret")) { error in
            XCTAssertEqual(error as? QuotaError, .rateLimited(retryAfter: 30))
        }
    }

    func testFetchMapsOtherStatus() async {
        let api = QuotaAPI(session: session(status: 500, body: Data()))
        await XCTAssertThrowsErrorAsync(try await api.fetch(token: "secret")) { error in
            XCTAssertEqual(error as? QuotaError, .http(500))
        }
    }
}
