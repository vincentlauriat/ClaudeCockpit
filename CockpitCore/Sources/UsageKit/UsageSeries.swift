import Foundation

/// The four token buckets shown in the daily usage chart, in bottom-to-top stacking order.
/// The per-case `Color` lives in the app layer now.
public enum UsageSeries: String, CaseIterable, Identifiable, Hashable, Sendable {
    case input = "Input"
    case output = "Output"
    case cacheRead = "Cache Read"
    case cacheCreation = "Cache Creation"

    public var id: String { rawValue }

    public func value(from day: DailyUsage) -> Int {
        switch self {
        case .input: day.inputTokens
        case .output: day.outputTokens
        case .cacheRead: day.cacheReadTokens
        case .cacheCreation: day.cacheCreationTokens
        }
    }

    /// Which of the daily chart's two independent Y axes this series is scaled against:
    /// Cache Read/Creation share a left "millions" axis, Input/Output share a right
    /// "hundreds of thousands" axis — reproducing the reference dashboard's two-axis look.
    public var isCacheAxis: Bool {
        switch self {
        case .cacheRead, .cacheCreation: true
        case .input, .output: false
        }
    }
}

/// Aggregate token usage and cost for a single calendar day — one point of the daily series.
public struct DailyUsage: Identifiable, Hashable, Sendable {
    public var id: Date { day }
    public let day: Date
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheCreationTokens: Int = 0
    /// Added versus the source app, which only carried tokens per day.
    public var estimatedCostUSD: Double = 0

    public init(
        day: Date,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        estimatedCostUSD: Double = 0
    ) {
        self.day = day
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.estimatedCostUSD = estimatedCostUSD
    }

    public var total: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }
}

/// Aggregate usage for one hour-of-day (0...23) on a specific calendar day — feeds the
/// "cost per hour" card, which compares today's activity so far against yesterday's.
public struct HourlyUsage: Identifiable, Hashable, Sendable {
    public var id: Int { hour }
    public let hour: Int
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheCreationTokens: Int = 0
    public var estimatedCostUSD: Double = 0

    public init(hour: Int) { self.hour = hour }
}

/// Aggregate cost for one calendar month, across all recorded history.
public struct MonthlyUsage: Identifiable, Hashable, Sendable {
    public var id: Date { monthStart }
    public let monthStart: Date
    public var estimatedCostUSD: Double = 0

    public init(monthStart: Date, estimatedCostUSD: Double = 0) {
        self.monthStart = monthStart
        self.estimatedCostUSD = estimatedCostUSD
    }
}

/// Aggregate usage for one calendar year, across all recorded history.
public struct YearlyUsage: Identifiable, Hashable, Sendable {
    public var id: Int { year }
    public let year: Int
    public var sessionCount: Int = 0
    public var estimatedCostUSD: Double = 0

    public init(year: Int, sessionCount: Int = 0, estimatedCostUSD: Double = 0) {
        self.year = year
        self.sessionCount = sessionCount
        self.estimatedCostUSD = estimatedCostUSD
    }
}

/// Aggregate stats for the currently filtered set of usage events (the stat cards row).
public struct UsageSummary: Hashable, Sendable {
    public var sessionCount: Int = 0
    public var turnCount: Int = 0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheCreationTokens: Int = 0
    public var estimatedCostUSD: Double = 0

    public init() {}

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }
}
