import SwiftUI
import Charts
import CockpitShared
import UsageKit

/// Daily stacked token bars on two independent Y axes — Input/Output scaled against the
/// trailing axis, Cache Read/Creation against the leading one, exactly as
/// `UsageSeries.isCacheAxis` prescribes. Each group is normalized against its own per-range max
/// and given half of the plot height, so a bar's total height doesn't correspond to a single
/// real total: it is the source dashboard's deliberate two-axis replica. Splitting the height
/// (rather than letting each group span the whole plot, as the source app did) keeps the stack
/// inside a fixed 0...1 domain, which is what lets the estimated-cost line share the same space
/// and still use its full range. The cost is normalized against its own daily max and anchored
/// by a labelled peak rather than by a third axis.
struct DailyUsageChartCard: View {
    let daily: [DailyUsage]
    let range: DateRangeFilter
    let money: (Double) -> String

    private struct BarPoint: Identifiable {
        let day: Date
        let series: UsageSeries
        /// Fraction (0...1) of this series' own axis-group max over the range.
        let normalized: Double
        /// Deterministic (day, series) key rather than a fresh `UUID()`: `points` is recomputed
        /// on every redraw, and a random id would make Swift Charts see a brand-new dataset
        /// each time, defeating its mark diffing.
        var id: String { "\(day.timeIntervalSince1970)-\(series.rawValue)" }
    }

    private struct CostPoint: Identifiable {
        let day: Date
        let cost: Double
        let normalized: Double
        var id: Date { day }
    }

    /// Each group owns half of the shared 0...1 plotting scale: Input/Output the lower half,
    /// Cache Read/Creation the upper one. Ticks are placed inside each half and labelled
    /// against that group's own max.
    private static let ioFractions: [Double] = [0, 0.125, 0.25, 0.375, 0.5]
    private static let cacheFractions: [Double] = [0.5, 0.625, 0.75, 0.875, 1.0]
    /// Share of the plot height given to each axis group.
    private static let groupShare = 0.5

    private var cacheMax: Double {
        max(daily.map { Double($0.cacheReadTokens + $0.cacheCreationTokens) }.max() ?? 1, 1)
    }
    private var ioMax: Double {
        max(daily.map { Double($0.inputTokens + $0.outputTokens) }.max() ?? 1, 1)
    }
    private var costMax: Double {
        max(daily.map(\.estimatedCostUSD).max() ?? 0, 0.0001)
    }

    private var barPoints: [BarPoint] {
        let cacheMax = cacheMax
        let ioMax = ioMax
        return daily.flatMap { day in
            UsageSeries.allCases.map { series in
                BarPoint(
                    day: day.day,
                    series: series,
                    normalized: Double(series.value(from: day))
                        / (series.isCacheAxis ? cacheMax : ioMax) * Self.groupShare)
            }
        }
    }

    private var costPoints: [CostPoint] {
        let costMax = costMax
        return daily.map {
            CostPoint(day: $0.day, cost: $0.estimatedCostUSD, normalized: $0.estimatedCostUSD / costMax)
        }
    }

    private var peak: CostPoint? {
        costPoints.max { $0.cost < $1.cost }
    }

    var body: some View {
        let money = money
        return VStack(alignment: .leading, spacing: 16) {
            header
            if daily.isEmpty {
                Text("Aucune donnée sur cette période.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .frame(maxWidth: .infinity, minHeight: 280, alignment: .center)
            } else {
                chart(money: money)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
    }

    private var header: some View {
        HStack(spacing: 12) {
            SectionLabel(text: "Usage quotidien — \(range.frenchLabel)")
            Spacer()
            if !daily.isEmpty {
                ForEach(UsageSeries.allCases) { series in
                    legendChip(series.frenchLabel, color: series.color)
                }
                legendChip("Coût — max \(money(costMax))", color: UsagePalette.cost)
            }
        }
    }

    private func chart(money: @escaping (Double) -> String) -> some View {
        let cacheMax = cacheMax
        let ioMax = ioMax
        return Chart {
            ForEach(barPoints) { point in
                BarMark(
                    x: .value("Jour", point.day, unit: .day),
                    y: .value("Tokens", point.normalized))
                .foregroundStyle(by: .value("Série", point.series.frenchLabel))
            }
            ForEach(costPoints) { point in
                LineMark(
                    x: .value("Jour", point.day, unit: .day),
                    y: .value("Coût", point.normalized))
                .foregroundStyle(UsagePalette.cost)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.monotone)
            }
            if let peak, peak.cost > 0 {
                PointMark(
                    x: .value("Jour", peak.day, unit: .day),
                    y: .value("Coût", peak.normalized))
                .foregroundStyle(UsagePalette.cost)
                .symbolSize(40)
                .annotation(position: .top, alignment: .center) {
                    Text(money(peak.cost))
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(UsagePalette.cost)
                }
            }
        }
        .chartForegroundStyleScale(UsageSeries.styleScale)
        .chartLegend(.hidden)
        .chartYScale(domain: 0...1)
        .chartYAxis {
            AxisMarks(position: .leading, values: Self.cacheFractions) { value in
                AxisGridLine().foregroundStyle(Theme.cardStroke)
                AxisValueLabel {
                    if let fraction = value.as(Double.self) {
                        Text(FRFormat.tokens(Int((fraction - Self.groupShare) / Self.groupShare * cacheMax)))
                            .foregroundStyle(UsagePalette.cacheRead)
                    }
                }
            }
            AxisMarks(position: .trailing, values: Self.ioFractions) { value in
                AxisGridLine().foregroundStyle(Theme.cardStroke)
                AxisValueLabel {
                    if let fraction = value.as(Double.self) {
                        Text(FRFormat.tokens(Int(fraction / Self.groupShare * ioMax)))
                            .foregroundStyle(UsagePalette.input)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(10, max(2, daily.count)))) { _ in
                AxisGridLine().foregroundStyle(Theme.cardStroke)
                AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: false)
                    .foregroundStyle(Theme.slate)
            }
        }
        .frame(minHeight: 280)
    }

    private func legendChip(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title).font(.system(size: 10)).foregroundStyle(Theme.slate)
        }
    }
}
