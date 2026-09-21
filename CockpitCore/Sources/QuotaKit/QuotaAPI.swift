import Foundation

/// Anything able to produce a gauge snapshot from a bearer token.
public protocol QuotaFetching: Sendable {
    func fetch(token: String) async throws -> GaugeSnapshot
}

/// `GET https://api.anthropic.com/api/oauth/usage` — the same gauge Claude Code's `/usage` shows.
///
/// Response shape (only the parts we use):
/// ```
/// { "five_hour": { "utilization": 54.0, "resets_at": "…" },
///   "seven_day": { "utilization": 84.0, "resets_at": "…" },
///   "seven_day_opus": { … }, "seven_day_sonnet": { … }, … }
/// ```
/// Every top-level object carrying a `utilization` becomes a `Meter`, so new per-model
/// keys show up without a code change — including ones with no `resets_at`.
public struct QuotaAPI: QuotaFetching, Sendable {
    public static let defaultEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let session: URLSession
    private let endpoint: URL
    private let timeout: TimeInterval

    public init(session: URLSession = .shared,
                endpoint: URL = QuotaAPI.defaultEndpoint,
                timeout: TimeInterval = 15) {
        self.session = session
        self.endpoint = endpoint
        self.timeout = timeout
    }

    public func fetch(token: String) async throws -> GaugeSnapshot {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Self.error(status: http.statusCode, headers: http.allHeaderFields)
        }
        return try Self.parse(data, fetchedAt: Date())
    }

    /// Maps a non-2xx status onto the typed error, reading `Retry-After` on a 429.
    static func error(status: Int, headers: [AnyHashable: Any]) -> QuotaError {
        switch status {
        case 401: return .unauthorized
        case 429: return .rateLimited(retryAfter: retryAfter(headers))
        default: return .http(status)
        }
    }

    private static func retryAfter(_ headers: [AnyHashable: Any]) -> TimeInterval? {
        let value = headers.first { ($0.key as? String)?.lowercased() == "retry-after" }?.value
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
        return TimeInterval(text)
    }

    public static func parse(_ data: Data, fetchedAt: Date) throws -> GaugeSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.malformed
        }
        var session: Meter?
        var week: Meter?
        var models: [Meter] = []

        for (key, value) in root {
            guard let dict = value as? [String: Any],
                  let utilization = number(dict["utilization"]) else { continue }
            // `extra_usage` is a spend meter, not a rate-limit window — skip it.
            if key == "extra_usage" { continue }
            let resetsAt = (dict["resets_at"] as? String).flatMap(ISO8601Date.parse)
            switch key {
            case Meter.sessionKey:
                session = Meter(key: key, name: "session", utilization: utilization,
                                resetsAt: resetsAt, windowHours: 5)
            case Meter.weekKey:
                week = Meter(key: key, name: "all", utilization: utilization,
                             resetsAt: resetsAt, windowHours: 168)
            default:
                let name = key.hasPrefix(Meter.modelKeyPrefix)
                    ? String(key.dropFirst(Meter.modelKeyPrefix.count))
                    : key
                models.append(Meter(key: key, name: name, utilization: utilization,
                                    resetsAt: resetsAt, windowHours: 168))
            }
        }
        models.sort { $0.name < $1.name }
        guard session != nil || week != nil else { throw QuotaError.malformed }
        return GaugeSnapshot(fetchedAt: fetchedAt, session: session, week: week, models: models)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

/// ISO-8601 parsing that accepts both `…Z` and `…​.123Z`.
public enum ISO8601Date {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parse(_ text: String) -> Date? {
        withFraction.date(from: text) ?? plain.date(from: text)
    }
}
