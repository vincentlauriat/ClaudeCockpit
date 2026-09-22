import SwiftUI
import CockpitShared
import UsageKit

/// Estimated cost split by pricing family for the filtered usage, as a single horizontal
/// stacked bar — a part-to-whole view, not a trend.
struct ModelMixCard: View {
    let rows: [ModelCostRow]
    let money: (Double) -> String

    private var total: Double { rows.reduce(0) { $0 + $1.costUSD } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Répartition par modèle")
            if rows.isEmpty || total <= 0 {
                Text("Aucune donnée sur cette période.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            } else {
                stackedBar
                legend
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
    }

    private var stackedBar: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(rows) { row in
                    row.family.color
                        .frame(width: max(0, geo.size.width * (row.costUSD / total)))
                }
            }
        }
        .frame(height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var legend: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(row.family.color)
                        .frame(width: 9, height: 9)
                    Text("\(row.family.label) · \(FRFormat.percent(row.costUSD / total))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                    Spacer(minLength: 4)
                    Text(money(row.costUSD))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                }
            }
        }
    }
}
