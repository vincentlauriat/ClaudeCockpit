import Foundation

/// UserDefaults keys. Views bind with `@AppStorage`; the store reads them directly.
enum SettingsKey {
    static let launchAtLogin = "settings.launchAtLogin"
    static let menuBarOnly = "settings.menuBarOnly"
    static let usageRefreshSeconds = "settings.usageRefreshSeconds"   // Int, default 30
    static let rtkDBPath = "settings.rtkDBPath"                       // String, empty = auto
    static let projectRoots = "settings.projectRoots"                 // String, newline-separated
    static let pricingJSON = "settings.pricingJSON"                   // PricingSettings JSON
    static let currency = "settings.currency"                         // "USD" | "EUR"
    static let eurRate = "settings.eurRate"                           // Double, USD→EUR
    static let panelSectionLimits = "panel.section.limits"
    static let panelSectionToday = "panel.section.today"
    static let panelSectionSavings = "panel.section.savings"
    static let mainSection = "window.section"                         // last selected sidebar item

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            usageRefreshSeconds: 30,
            currency: "USD",
            eurRate: 0.92,
            panelSectionLimits: true,
            panelSectionToday: true,
            panelSectionSavings: true,
        ])
    }
}
