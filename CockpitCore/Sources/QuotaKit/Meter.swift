import Foundation

/// One meter as reported by Anthropic's OAuth usage endpoint.
public struct Meter: Identifiable, Equatable, Hashable, Sendable {
    /// Raw key in the API response (`five_hour`, `seven_day`, `seven_day_opus`, …).
    public let key: String
    /// Display name: `session`, `all`, or the model suffix (`opus`, `fable`, …).
    public let name: String
    /// Percentage already used, 0…100 (may exceed 100 on overage).
    public let utilization: Double
    /// When the window resets, if the API provided it.
    public let resetsAt: Date?
    /// Window length in hours (5 for the session meter, 168 for weekly ones).
    public let windowHours: Double

    public var id: String { key }

    public var isSession: Bool { key == Meter.sessionKey }

    /// `seven_day_<model>` — a documented per-model weekly window. Anything else that
    /// is neither the session nor the `all` meter is an undocumented quota bucket.
    public var isModelWindow: Bool { key.hasPrefix(Meter.modelKeyPrefix) }

    public static let sessionKey = "five_hour"
    public static let weekKey = "seven_day"
    /// Prefix stripped from per-model weekly keys (`seven_day_opus` → `opus`).
    public static let modelKeyPrefix = "seven_day_"

    public init(key: String, name: String, utilization: Double,
                resetsAt: Date?, windowHours: Double) {
        self.key = key
        self.name = name
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.windowHours = windowHours
    }
}

/// Everything read from Anthropic's gauge in one call.
public struct GaugeSnapshot: Equatable, Sendable {
    public let fetchedAt: Date
    /// The rolling 5-hour session window.
    public let session: Meter?
    /// The weekly `all` window — the one that actually runs out.
    public let week: Meter?
    /// Per-model weekly meters: every `seven_day_<model>` key.
    public let models: [Meter]
    /// Undocumented buckets the API also reports (`nimbus_quill`, …): neither a known
    /// window nor a model. Kept as-is so the UI can show them without presenting them
    /// as models.
    public let other: [Meter]

    public init(fetchedAt: Date, session: Meter?, week: Meter?, models: [Meter], other: [Meter] = []) {
        self.fetchedAt = fetchedAt
        self.session = session
        self.week = week
        self.models = models
        self.other = other
    }

    /// `all` first, then the per-model meters.
    public var weeklyMeters: [Meter] {
        var list: [Meter] = []
        if let week { list.append(week) }
        list.append(contentsOf: models)
        return list
    }
}
