import Foundation

/// Everything the usage screens display, computed once per refresh by `UsageAggregator`.
/// Immutable and `Sendable`: the app stores it and reads it from the main actor.
public struct UsageSnapshot: Sendable {
    /// When the snapshot was computed — the "now" used by every fixed window below.
    public let generatedAt: Date
    public let filters: UsageFilters
    public let pricing: PricingSettings

    /// Events left after the model/project/range filters, newest last.
    public let filteredEvents: [UsageEvent]
    public let totals: UsageSummary

    public let daily: [DailyUsage]
    public let costByFamily: [ModelCostRow]
    public let sessions: [SessionSummary]
    private let breakdowns: [BreakdownDimension: [BreakdownRow]]

    /// Fixed "today vs yesterday" / "this week vs last week" comparisons. These ignore the
    /// range filter (a fixed window is the point of a day/week-over-day/week comparison) but
    /// still respect the model and project filters.
    public let hourlyToday: [HourlyUsage]
    public let hourlyYesterday: [HourlyUsage]
    public let sessionsThisWeekByWeekday: [Int]
    public let sessionsLastWeekByWeekday: [Int]
    /// Distinct sessions over the whole week. Not the sum of the per-weekday counts above:
    /// those dedupe within a day, so a session spanning midnight appears in two days.
    public let sessionsThisWeekTotal: Int
    public let sessionsLastWeekTotal: Int
    public let costThisWeekUSD: Double
    public let costLastWeekUSD: Double

    public let monthly: [MonthlyUsage]
    public let yearly: [YearlyUsage]
    public let insights: [Insight]

    /// Cost and tokens recorded since midnight, model/project filters applied, range ignored.
    public let costTodayUSD: Double
    public let tokensToday: Int

    /// Options for the filter pickers, derived from the whole event set.
    public let availableProjects: [String]
    public let availableModels: [String]
    public let availableModelFamilies: [ModelFamily]

    public init(
        generatedAt: Date,
        filters: UsageFilters,
        pricing: PricingSettings,
        filteredEvents: [UsageEvent],
        totals: UsageSummary,
        daily: [DailyUsage],
        costByFamily: [ModelCostRow],
        sessions: [SessionSummary],
        breakdowns: [BreakdownDimension: [BreakdownRow]],
        hourlyToday: [HourlyUsage],
        hourlyYesterday: [HourlyUsage],
        sessionsThisWeekByWeekday: [Int],
        sessionsLastWeekByWeekday: [Int],
        sessionsThisWeekTotal: Int,
        sessionsLastWeekTotal: Int,
        costThisWeekUSD: Double,
        costLastWeekUSD: Double,
        monthly: [MonthlyUsage],
        yearly: [YearlyUsage],
        insights: [Insight],
        costTodayUSD: Double,
        tokensToday: Int,
        availableProjects: [String],
        availableModels: [String],
        availableModelFamilies: [ModelFamily]
    ) {
        self.generatedAt = generatedAt
        self.filters = filters
        self.pricing = pricing
        self.filteredEvents = filteredEvents
        self.totals = totals
        self.daily = daily
        self.costByFamily = costByFamily
        self.sessions = sessions
        self.breakdowns = breakdowns
        self.hourlyToday = hourlyToday
        self.hourlyYesterday = hourlyYesterday
        self.sessionsThisWeekByWeekday = sessionsThisWeekByWeekday
        self.sessionsLastWeekByWeekday = sessionsLastWeekByWeekday
        self.sessionsThisWeekTotal = sessionsThisWeekTotal
        self.sessionsLastWeekTotal = sessionsLastWeekTotal
        self.costThisWeekUSD = costThisWeekUSD
        self.costLastWeekUSD = costLastWeekUSD
        self.monthly = monthly
        self.yearly = yearly
        self.insights = insights
        self.costTodayUSD = costTodayUSD
        self.tokensToday = tokensToday
        self.availableProjects = availableProjects
        self.availableModels = availableModels
        self.availableModelFamilies = availableModelFamilies
    }

    /// Breakdown rows for one dimension, sorted by cost descending.
    public func breakdown(for dimension: BreakdownDimension) -> [BreakdownRow] {
        breakdowns[dimension] ?? []
    }

    /// An empty snapshot, for the app's initial state.
    public static func empty(
        filters: UsageFilters = UsageFilters(),
        pricing: PricingSettings = .default,
        now: Date = Date()
    ) -> UsageSnapshot {
        UsageAggregator.snapshot(events: [], filters: filters, pricing: pricing, now: now)
    }
}
