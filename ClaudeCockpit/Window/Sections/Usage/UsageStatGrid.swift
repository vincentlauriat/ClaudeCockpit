import SwiftUI
import CockpitShared
import UsageKit

/// The seven KPI tiles above the charts: volume, then the four token buckets, then cost.
struct UsageStatGrid: View {
    let totals: UsageSummary
    let range: DateRangeFilter
    let money: (Double) -> String

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 12)]

    private var rangeNote: String {
        range == .all ? "sur tout l'historique" : "sur « \(range.frenchLabel.lowercased()) »"
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            StatTile(
                label: "Sessions",
                value: FRFormat.integer(totals.sessionCount),
                note: rangeNote,
                icon: "bubble.left.and.bubble.right")
            StatTile(
                label: "Tours",
                value: FRFormat.tokens(totals.turnCount),
                note: rangeNote,
                icon: "arrow.triangle.2.circlepath")
            StatTile(
                label: "Entrée",
                value: FRFormat.tokens(totals.inputTokens),
                note: "tokens envoyés",
                tint: UsagePalette.input,
                icon: "arrow.down.circle")
            StatTile(
                label: "Sortie",
                value: FRFormat.tokens(totals.outputTokens),
                note: "tokens générés",
                tint: UsagePalette.output,
                icon: "arrow.up.circle")
            StatTile(
                label: "Cache lu",
                value: FRFormat.tokens(totals.cacheReadTokens),
                note: "lectures du cache de prompt",
                tint: UsagePalette.cacheRead,
                icon: "arrow.clockwise.circle")
            StatTile(
                label: "Cache créé",
                value: FRFormat.tokens(totals.cacheCreationTokens),
                note: "écritures dans le cache",
                tint: UsagePalette.cacheCreation,
                icon: "square.stack.3d.up")
            StatTile(
                label: "Coût estimé",
                value: money(totals.estimatedCostUSD),
                note: "tarifs API, approximatif",
                tint: Theme.blue,
                icon: "creditcard")
        }
    }
}
