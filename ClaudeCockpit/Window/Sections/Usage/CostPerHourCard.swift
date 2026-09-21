import SwiftUI
import Charts
import UsageKit

/// "Hier vs aujourd'hui, par heure" — yesterday is a wide context bar, today overlays as a
/// narrower emphasis bar on the same hour slot, with a dashed rule on the current hour. Two
/// independently-coloured `BarMark` series drawn without a shared `foregroundStyle(by:)` key,
/// so Swift Charts overlays them instead of dodging them side by side.
struct CostPerHourCard: View {
    let yesterday: [HourlyUsage] // 24 entries, hour 0...23
    let today: [HourlyUsage] // 24 entries, hour 0...23
    let money: (Double) -> String

    private var currentHour: Int { Calendar.current.component(.hour, from: Date()) }

    var body: some View {
        let money = money
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "Coût par heure")
                Spacer()
                legendChip("Hier", color: UsagePalette.context)
                legendChip("Aujourd'hui", color: Theme.blue)
            }
            Chart {
                // `.fixed(_:)`, not `.ratio(_:)`: with a plain `Int` x-value (no `.day`-style
                // unit to band against), Swift Charts silently draws nothing for a
                // ratio-sized bar — it needs an absolute width.
                ForEach(yesterday) { bucket in
                    BarMark(
                        x: .value("Heure", bucket.hour),
                        y: .value("Coût", bucket.estimatedCostUSD),
                        width: .fixed(12))
                    .foregroundStyle(UsagePalette.context.opacity(0.45))
                }
                ForEach(today) { bucket in
                    BarMark(
                        x: .value("Heure", bucket.hour),
                        y: .value("Coût", bucket.estimatedCostUSD),
                        width: .fixed(6))
                    .foregroundStyle(Theme.blue)
                }
                RuleMark(x: .value("Heure", currentHour))
                    .foregroundStyle(Theme.slate)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .center) {
                        Text("maintenant").font(.system(size: 10)).foregroundStyle(Theme.slate)
                    }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: 4)) { value in
                    AxisGridLine().foregroundStyle(Theme.cardStroke)
                    AxisValueLabel {
                        if let hour = value.as(Int.self) {
                            Text("\(hour) h").foregroundStyle(Theme.slate)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Theme.cardStroke)
                    AxisValueLabel {
                        if let cost = value.as(Double.self) {
                            Text(money(cost)).foregroundStyle(Theme.slate)
                        }
                    }
                }
            }
            .frame(minHeight: 160)
            HStack(alignment: .bottom) {
                total("Hier", yesterday.reduce(0) { $0 + $1.estimatedCostUSD }, color: Theme.ink)
                Spacer()
                total(
                    "Aujourd'hui",
                    today.reduce(0) { $0 + $1.estimatedCostUSD },
                    color: Theme.blue,
                    alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
    }

    private func legendChip(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.slate)
        }
    }

    private func total(
        _ label: String,
        _ value: Double,
        color: Color,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            SectionLabel(text: label)
            Text(money(value))
                .font(.display(20))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}
