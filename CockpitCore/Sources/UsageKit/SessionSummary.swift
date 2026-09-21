import Foundation

/// Session-level metadata that doesn't live on every transcript line — a human-readable name
/// only appears on standalone `type: "ai-title"` lines (or the `slug` field on a few line
/// types), so it's collected separately from `UsageEvent` while scanning every line, not just
/// assistant turns.
public struct SessionInfo: Codable, Hashable, Sendable {
    public var title: String?
    public var slug: String?
    public var cwd: String?

    public init(title: String? = nil, slug: String? = nil, cwd: String? = nil) {
        self.title = title
        self.slug = slug
        self.cwd = cwd
    }

    /// Best available human-readable label for this session.
    public func displayName(fallback sessionId: String) -> String {
        title ?? slug ?? String(sessionId.prefix(8))
    }
}

/// Aggregate of one session's `UsageEvent`s (main conversation plus any sub-agent turns
/// sharing the same `sessionId`), for the sessions list.
public struct SessionSummary: Identifiable, Hashable, Sendable {
    public let id: String // sessionId
    public let displayName: String
    public let cwd: String
    public let firstSeen: Date
    public let lastSeen: Date
    public let turnCount: Int
    public let modelsUsed: [String]
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let estimatedCostUSD: Double

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    public init?(
        sessionId: String,
        events: [UsageEvent],
        info: SessionInfo?,
        pricing: PricingSettings
    ) {
        guard let first = events.first else { return nil }
        self.id = sessionId
        self.displayName = info?.displayName(fallback: sessionId) ?? String(sessionId.prefix(8))
        self.cwd = info?.cwd ?? first.cwd
        self.firstSeen = events.map(\.timestamp).min() ?? first.timestamp
        self.lastSeen = events.map(\.timestamp).max() ?? first.timestamp
        self.turnCount = events.count
        self.modelsUsed = Array(Set(events.map(\.model))).sorted()
        self.inputTokens = events.reduce(0) { $0 + $1.inputTokens }
        self.outputTokens = events.reduce(0) { $0 + $1.outputTokens }
        self.cacheCreationTokens = events.reduce(0) { $0 + $1.cacheCreationTokens }
        self.cacheReadTokens = events.reduce(0) { $0 + $1.cacheReadTokens }
        self.estimatedCostUSD = PricingCalculator.estimatedCostUSD(for: events, pricing: pricing)
    }
}
