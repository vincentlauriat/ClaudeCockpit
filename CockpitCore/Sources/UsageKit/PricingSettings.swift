import Foundation

/// User-editable pricing for the 4 model families. `.default` matches Anthropic's published
/// per-model input rate, with output/cache-write/cache-read derived via the ratios that hold
/// across every current model: output = 5x input, cache write (5 min TTL) = 1.25x input,
/// cache read = 0.1x input.
///
/// Persistence moved out of the type: the source app wrote to `UserDefaults` directly, the
/// cockpit stores the JSON produced by `jsonString` in `@AppStorage`.
public struct PricingSettings: Codable, Equatable, Hashable, Sendable {
    public var opus: ModelPricing
    public var sonnet: ModelPricing
    public var haiku: ModelPricing
    public var fable: ModelPricing

    public init(opus: ModelPricing, sonnet: ModelPricing, haiku: ModelPricing, fable: ModelPricing) {
        self.opus = opus
        self.sonnet = sonnet
        self.haiku = haiku
        self.fable = fable
    }

    public static let `default` = PricingSettings(
        // Opus 4.8: $5/$25 per MTok.
        opus: ModelPricing(inputPerMTok: 5, outputPerMTok: 25, cacheWritePerMTok: 6.25, cacheReadPerMTok: 0.50),
        // Sonnet 5 standard rate: $3/$15 per MTok.
        sonnet: ModelPricing(inputPerMTok: 3, outputPerMTok: 15, cacheWritePerMTok: 3.75, cacheReadPerMTok: 0.30),
        // Haiku 4.5: $1/$5 per MTok.
        haiku: ModelPricing(inputPerMTok: 1, outputPerMTok: 5, cacheWritePerMTok: 1.25, cacheReadPerMTok: 0.10),
        // Fable 5: $10/$50 per MTok.
        fable: ModelPricing(inputPerMTok: 10, outputPerMTok: 50, cacheWritePerMTok: 12.50, cacheReadPerMTok: 1.00)
    )

    public func family(forModel modelId: String) -> ModelFamily {
        ModelFamily.detect(from: modelId)
    }

    public func pricing(forModel modelId: String) -> ModelPricing {
        pricing(for: ModelFamily.detect(from: modelId))
    }

    public func pricing(for family: ModelFamily) -> ModelPricing {
        switch family {
        case .opus: opus
        case .sonnet: sonnet
        case .haiku: haiku
        case .fable: fable
        }
    }

    public mutating func setPricing(_ pricing: ModelPricing, for family: ModelFamily) {
        switch family {
        case .opus: opus = pricing
        case .sonnet: sonnet = pricing
        case .haiku: haiku = pricing
        case .fable: fable = pricing
        }
    }

    /// Whether the model id actually named a known family, rather than silently falling back
    /// to the Sonnet default.
    public func hasDedicatedTier(forModel modelId: String) -> Bool {
        ModelFamily.hasDedicatedTier(modelId)
    }

    // MARK: - JSON round-trip

    public func jsonData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decoded(from data: Data) throws -> PricingSettings {
        try JSONDecoder().decode(PricingSettings.self, from: data)
    }

    /// UTF-8 JSON, suitable for `@AppStorage`. Falls back to the defaults' JSON if encoding
    /// ever failed (it cannot, for a fixed set of `Double`s).
    public var jsonString: String {
        guard let data = try? jsonData(), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// Decodes settings previously produced by `jsonString`; returns `.default` on anything
    /// unreadable, so a corrupt preference never blocks the app.
    public static func decoded(fromJSONString text: String) -> PricingSettings {
        guard let data = text.data(using: .utf8),
              let decoded = try? decoded(from: data)
        else { return .default }
        return decoded
    }
}
