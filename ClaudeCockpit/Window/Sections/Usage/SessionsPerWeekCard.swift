import SwiftUI
import Charts
import CockpitShared
import UsageKit

/// "Cette semaine vs la semaine dernière", one point per weekday. Last week is context (mist),
/// this week is the emphasis series. Independent of the range filter: a week-over-week
/// comparison against an arbitrary range would mean nothing.
struct SessionsPerWeekCard: View {
    let lastWeek: [Int] // 7 values, Monday...Sunday
    let thisWeek: [Int] // 7 values, Monday...Sunday
    /// Distinct sessions over each week. Deliberately not `lastWeek.reduce(0, +)`: the
    /// per-weekday values dedupe within a day, so a session spanning midnight counts twice.
    let lastWeekTotal: Int
    let thisWeekTotal: Int

    private static let weekdays = ["lun.", "mar.", "mer.", "jeu.", "ven.", "sam.", "dim."]
    private static let lastWeekSeries = "Semaine dernière"
    private static let thisWeekSeries = "Cette semaine"

    private struct Point: Identifiable {
        let weekday: String
        let index: Int
        let value: Int
        let series: String
        var id: String { "\(series)-\(index)" }
    }

    private func value(_ values: [Int], _ index: Int) -> Int {
        index < values.count ? values[index] : 0
    }

    private var points: [Point] {
        Self.weekdays.indices.flatMap { i in
            [
                Point(weekday: Self.weekdays[i], index: i, value: value(lastWeek, i), series: Self.lastWeekSeries),
                Point(weekday: Self.weekdays[i], index: i, value: value(thisWeek, i), series: Self.thisWeekSeries),
            ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "Sessions par semaine")
                Spacer()
                legendChip(Self.lastWeekSeries, color: UsagePalette.context)
                legendChip(Self.thisWeekSeries, color: Theme.blue)
            }
            Chart(points) { point in
                LineMark(
                    x: .value("Jour", point.weekday),
                    y: .value("Sessions", point.value))
                .foregroundStyle(by: .value("Série", point.series))
                .interpolationMethod(.catmullRom)
            }
            .chartForegroundStyleScale([
                Self.lastWeekSeries: UsagePalette.context,
                Self.thisWeekSeries: Theme.blue,
            ])
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Theme.cardStroke)
                    AxisValueLabel().foregroundStyle(Theme.slate)
                }
            }
            .chartXAxis {
                AxisMarks { AxisValueLabel().foregroundStyle(Theme.slate) }
            }
            .frame(minHeight: 160)
            HStack(alignment: .bottom) {
                total("Semaine dernière", lastWeekTotal, color: Theme.ink)
                Spacer()
                total("Cette semaine", thisWeekTotal, color: Theme.blue, alignment: .trailing)
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
        _ value: Int,
        color: Color,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            SectionLabel(text: label)
            Text(FRFormat.integer(value))
                .font(.display(20))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}
