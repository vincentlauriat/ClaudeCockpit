import Foundation
import XCTest
@testable import QuotaKit

/// `URLProtocol` stub: every request handled by the session it is installed on is
/// answered from the registered closure, so no test ever reaches the network.
final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var handler: Handler?

    static func respond(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        Self.handler = handler
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
    }

    private static func currentHandler() -> Handler? {
        lock.lock(); defer { lock.unlock() }
        return handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.currentHandler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A clock the tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

/// A token provider that never touches the keychain.
struct StubCredentials: TokenProviding {
    var token = "token"
    var failure: (any Error)?

    func accessToken() throws -> String {
        if let failure { throw failure }
        return token
    }
}

/// A gauge client that counts its calls and replays a scripted list of outcomes.
actor StubQuotaAPI: QuotaFetching {
    private var outcomes: [Result<GaugeSnapshot, any Error>]
    private(set) var calls = 0

    init(outcomes: [Result<GaugeSnapshot, any Error>]) {
        self.outcomes = outcomes
    }

    func fetch(token: String) async throws -> GaugeSnapshot {
        calls += 1
        guard !outcomes.isEmpty else {
            XCTFail("StubQuotaAPI called more times than scripted")
            throw QuotaError.malformed
        }
        return try outcomes.removeFirst().get()
    }
}

func makeSnapshot(fetchedAt: Date, weekUtilization: Double) -> GaugeSnapshot {
    GaugeSnapshot(
        fetchedAt: fetchedAt,
        session: Meter(key: "five_hour", name: "session", utilization: 10,
                       resetsAt: fetchedAt.addingTimeInterval(3 * 3600), windowHours: 5),
        week: Meter(key: "seven_day", name: "all", utilization: weekUtilization,
                    resetsAt: fetchedAt.addingTimeInterval(72 * 3600), windowHours: 168),
        models: []
    )
}

/// `XCTAssertThrowsError` for async expressions.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "expected an error",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ inspect: (any Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message, file: file, line: line)
    } catch {
        inspect(error)
    }
}
