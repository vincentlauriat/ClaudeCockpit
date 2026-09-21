import Foundation

/// Per-million-token pricing (USD) for one model family. Editable from the UI (see
/// `PricingSettings`) — these are just the 4 rates plus the cost formula.
public struct ModelPricing: Codable, Equatable, Hashable, Sendable {
    public var inputPerMTok: Double
    public var outputPerMTok: Double
    public var cacheWritePerMTok: Double
    public var cacheReadPerMTok: Double

    public init(
        inputPerMTok: Double,
        outputPerMTok: Double,
        cacheWritePerMTok: Double,
        cacheReadPerMTok: Double
    ) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheWritePerMTok = cacheWritePerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
    }

    public func cost(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int
    ) -> Double {
        let million = 1_000_000.0
        return Double(inputTokens) / million * inputPerMTok
            + Double(outputTokens) / million * outputPerMTok
            + Double(cacheCreationTokens) / million * cacheWritePerMTok
            + Double(cacheReadTokens) / million * cacheReadPerMTok
    }

    public func cost(for event: UsageEvent) -> Double {
        cost(
            inputTokens: event.inputTokens,
            outputTokens: event.outputTokens,
            cacheCreationTokens: event.cacheCreationTokens,
            cacheReadTokens: event.cacheReadTokens
        )
    }
}
