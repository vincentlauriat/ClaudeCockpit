import Foundation

/// The 4 pricing tiers `PricingSettings` distinguishes between, in a fixed display order
/// (also the order model-mix rows are shown in, highest tier first).
///
/// The SwiftUI `Color` the source app attached to each case lives in the app layer now —
/// UsageKit is Foundation-only.
public enum ModelFamily: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case opus = "Opus"
    case sonnet = "Sonnet"
    case haiku = "Haiku"
    case fable = "Fable"

    public var id: String { rawValue }

    /// Maps a model identifier (e.g. `claude-opus-4-8`, `claude-sonnet-5`,
    /// `claude-haiku-4-5-20251001`) to its pricing family. Falls back to Sonnet for
    /// unrecognized models rather than under/over-estimating wildly. Identical substring
    /// matching to the source app — the single place it happens.
    public static func detect(from modelId: String) -> ModelFamily {
        let id = modelId.lowercased()
        if id.contains("opus") { return .opus }
        if id.contains("haiku") { return .haiku }
        if id.contains("fable") { return .fable }
        return .sonnet
    }

    /// Whether the model id actually named a known family, rather than silently falling back
    /// to the Sonnet default — used by the insights to flag models needing a confirmed rate.
    public static func hasDedicatedTier(_ modelId: String) -> Bool {
        let id = modelId.lowercased()
        return id.contains("opus") || id.contains("sonnet") || id.contains("haiku") || id.contains("fable")
    }
}

/// One family's share of estimated cost for the currently filtered usage.
public struct ModelCostRow: Identifiable, Hashable, Sendable {
    public var id: ModelFamily { family }
    public let family: ModelFamily
    public let costUSD: Double

    public init(family: ModelFamily, costUSD: Double) {
        self.family = family
        self.costUSD = costUSD
    }
}
