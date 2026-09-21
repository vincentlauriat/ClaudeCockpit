import Foundation

/// Computes the estimated USD cost of a set of usage events, applying each event's own model
/// pricing tier (see `PricingSettings`).
public enum PricingCalculator {
    public static func estimatedCostUSD(
        for events: some Sequence<UsageEvent>,
        pricing settings: PricingSettings
    ) -> Double {
        events.reduce(0) { total, event in
            total + settings.pricing(forModel: event.model).cost(for: event)
        }
    }

    public static func estimatedCostUSD(for event: UsageEvent, pricing settings: PricingSettings) -> Double {
        settings.pricing(forModel: event.model).cost(for: event)
    }
}
