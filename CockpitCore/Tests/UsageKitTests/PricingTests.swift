import XCTest
@testable import UsageKit

final class PricingTests: XCTestCase {
    func testModelFamilyDetection() {
        XCTAssertEqual(ModelFamily.detect(from: "claude-opus-5"), .opus)
        XCTAssertEqual(ModelFamily.detect(from: "claude-opus-4-8"), .opus)
        XCTAssertEqual(ModelFamily.detect(from: "claude-haiku-4-5-20251001"), .haiku)
        XCTAssertEqual(ModelFamily.detect(from: "claude-fable-5-1"), .fable)
        XCTAssertEqual(ModelFamily.detect(from: "claude-sonnet-5"), .sonnet)
        // Unknown ids fall back to Sonnet rather than under/over-estimating wildly.
        XCTAssertEqual(ModelFamily.detect(from: "some-unknown-model"), .sonnet)
        XCTAssertFalse(ModelFamily.hasDedicatedTier("some-unknown-model"))
        XCTAssertTrue(ModelFamily.hasDedicatedTier("claude-sonnet-5"))
        // Matching is case-insensitive, like the source app's.
        XCTAssertEqual(ModelFamily.detect(from: "CLAUDE-OPUS-5"), .opus)
    }

    func testDefaultPricingRatesAreUnchangedFromTheSourceApp() {
        let pricing = PricingSettings.default
        XCTAssertEqual(pricing.opus, ModelPricing(inputPerMTok: 5, outputPerMTok: 25, cacheWritePerMTok: 6.25, cacheReadPerMTok: 0.50))
        XCTAssertEqual(pricing.sonnet, ModelPricing(inputPerMTok: 3, outputPerMTok: 15, cacheWritePerMTok: 3.75, cacheReadPerMTok: 0.30))
        XCTAssertEqual(pricing.haiku, ModelPricing(inputPerMTok: 1, outputPerMTok: 5, cacheWritePerMTok: 1.25, cacheReadPerMTok: 0.10))
        XCTAssertEqual(pricing.fable, ModelPricing(inputPerMTok: 10, outputPerMTok: 50, cacheWritePerMTok: 12.50, cacheReadPerMTok: 1.00))
    }

    /// One million input, 200 k output, 400 k cache write and 10 M cache read on Opus:
    /// 5.00 + 5.00 + 2.50 + 5.00 = 17.50 USD.
    func testKnownModelCostMath() {
        let event = EventFactory.make(
            model: "claude-opus-5",
            timestamp: TestClock.now,
            inputTokens: 1_000_000,
            outputTokens: 200_000,
            cacheCreationTokens: 400_000,
            cacheReadTokens: 10_000_000)

        let cost = PricingCalculator.estimatedCostUSD(for: event, pricing: .default)
        XCTAssertEqual(cost, 17.50, accuracy: 1e-9)
        XCTAssertEqual(PricingSettings.default.pricing(forModel: event.model).cost(for: event), 17.50, accuracy: 1e-9)
        XCTAssertEqual(PricingCalculator.estimatedCostUSD(for: [event, event], pricing: .default), 35.0, accuracy: 1e-9)
    }

    func testEditedRatesApplyToTheMatchingFamilyOnly() {
        var pricing = PricingSettings.default
        pricing.setPricing(
            ModelPricing(inputPerMTok: 100, outputPerMTok: 0, cacheWritePerMTok: 0, cacheReadPerMTok: 0),
            for: .haiku)

        let haiku = EventFactory.make(model: "claude-haiku-4-5", timestamp: TestClock.now, inputTokens: 1_000_000)
        let sonnet = EventFactory.make(model: "claude-sonnet-5", timestamp: TestClock.now, inputTokens: 1_000_000)
        XCTAssertEqual(PricingCalculator.estimatedCostUSD(for: haiku, pricing: pricing), 100, accuracy: 1e-9)
        XCTAssertEqual(PricingCalculator.estimatedCostUSD(for: sonnet, pricing: pricing), 3, accuracy: 1e-9)
    }

    func testPricingSettingsJSONRoundTrip() throws {
        var pricing = PricingSettings.default
        pricing.setPricing(
            ModelPricing(inputPerMTok: 7.5, outputPerMTok: 37.5, cacheWritePerMTok: 9.375, cacheReadPerMTok: 0.75),
            for: .opus)

        let data = try pricing.jsonData()
        XCTAssertEqual(try PricingSettings.decoded(from: data), pricing)
        XCTAssertEqual(PricingSettings.decoded(fromJSONString: pricing.jsonString), pricing)
        // Anything unreadable falls back to the published defaults.
        XCTAssertEqual(PricingSettings.decoded(fromJSONString: "not json"), .default)
    }

    func testUsageEventCodableRoundTrip() throws {
        let event = EventFactory.make(
            id: "uuid-1", messageId: "msg-1", timestamp: TestClock.now,
            inputTokens: 1, outputTokens: 2, cacheCreationTokens: 3, cacheReadTokens: 4,
            attributionAgent: "explore", attributionSkill: "deepsearch")
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(UsageEvent.self, from: data), event)
        XCTAssertEqual(event.totalTokens, 10)
    }
}
