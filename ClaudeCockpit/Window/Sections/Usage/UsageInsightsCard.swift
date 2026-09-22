import SwiftUI
import UsageKit

/// Automatically-derived signals about the filtered usage — cost trend, pricing gaps, cache
/// efficiency. Rendered from `Insight.kind`, not from its English `text`.
struct UsageInsightsCard: View {
    let insights: [Insight]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Signaux et alertes")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(insights) { insight in
                    row(insight)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
    }

    private func row(_ insight: Insight) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(insight.level.frenchLabel.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(insight.level.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    insight.level.color.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(insight.frenchText)
                .font(.system(size: 12))
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
