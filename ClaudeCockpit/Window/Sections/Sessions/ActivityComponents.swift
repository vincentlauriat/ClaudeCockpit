// Building blocks of the "Activité" tab — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import SwiftUI
import Charts
import CockpitShared
import SessionsKit

// MARK: - Range

/// The range the "Activité" tab reports on. `custom` carries its own two dates,
/// held by the view; the others are computed against a stable anchor date so the
/// reload key does not change on every redraw.
enum ActivityRange: String, CaseIterable, Identifiable {
    case day, week, month, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Jour"
        case .week: "Semaine"
        case .month: "Mois"
        case .custom: "Personnalisé"
        }
    }

    /// Sentence fragment used under the totals, e.g. "sur les 30 derniers jours".
    var note: String {
        switch self {
        case .day: "depuis minuit"
        case .week: "sur les 7 derniers jours"
        case .month: "sur les 30 derniers jours"
        case .custom: "sur la période choisie"
        }
    }
}

// MARK: - Placeholder

/// Centred icon + title + sentence, the empty and loading state of both feeds.
struct ActivityPlaceholder: View {
    let icon: String
    let title: String
    let message: String
    var isBusy = false

    var body: some View {
        VStack(spacing: 10) {
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.mist)
            }
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.slate)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(.horizontal, 24)
        .panelStyle()
    }
}

// MARK: - Heatmap

/// Assistant turns as a 7 × 24 grid, one row per weekday and one column per hour.
///
/// `ActivityReport.buckets` is sparse — an hour nobody worked has no row at all — so
/// the grid is rendered from a dictionary rather than from the array, otherwise the
/// weeks would come out ragged. Rows are ordered Monday-first while `Calendar`
/// numbers Sunday 1, hence the explicit order below.
struct ActivityHeatmapCard: View {
    let buckets: [ActivityBucket]

    private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]
    private static let labelWidth: CGFloat = 26
    private static let cellSpacing: CGFloat = 2
    private static let cellHeight: CGFloat = 16

    /// French weekday names, from the shared locale rather than a hardcoded list.
    private static let shortWeekdays: [String] = {
        let formatter = DateFormatter()
        formatter.locale = FRFormat.locale
        return formatter.shortWeekdaySymbols
    }()
    private static let standaloneWeekdays: [String] = {
        let formatter = DateFormatter()
        formatter.locale = FRFormat.locale
        return formatter.standaloneWeekdaySymbols
    }()

    /// `weekday * 24 + hour` → assistant turns.
    private var counts: [Int: Int] {
        Dictionary(
            buckets.map { ($0.weekday * 24 + $0.hour, $0.assistantTurns) },
            uniquingKeysWith: +)
    }

    private var peak: Int { buckets.map(\.assistantTurns).max() ?? 0 }

    var body: some View {
        let counts = counts
        let peak = peak
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "Activité par heure")
                Spacer()
                if peak > 0 {
                    Text("pic : " + FRFormat.plural(peak, "tour"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                        .monospacedDigit()
                }
            }
            if peak == 0 {
                Text("Aucun tour assistant sur cette période.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                VStack(spacing: Self.cellSpacing) {
                    ForEach(Self.weekdayOrder, id: \.self) { weekday in
                        row(weekday: weekday, counts: counts, peak: peak)
                    }
                    hourAxis
                }
                legend(peak: peak)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
    }

    private func row(weekday: Int, counts: [Int: Int], peak: Int) -> some View {
        HStack(spacing: Self.cellSpacing) {
            Text(initial(weekday))
                .font(.label(9))
                .foregroundStyle(Theme.mist)
                .frame(width: Self.labelWidth, alignment: .leading)
            ForEach(0..<24, id: \.self) { hour in
                let turns = counts[weekday * 24 + hour] ?? 0
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Self.intensity(turns: turns, peak: peak))
                    .frame(height: Self.cellHeight)
                    .frame(maxWidth: .infinity)
                    .help(tooltip(weekday: weekday, hour: hour, turns: turns))
            }
        }
    }

    private var hourAxis: some View {
        HStack(spacing: Self.cellSpacing) {
            Spacer().frame(width: Self.labelWidth)
            ForEach(0..<24, id: \.self) { hour in
                Text(hour % 3 == 0 ? "\(hour)" : "")
                    .font(.label(9))
                    .foregroundStyle(Theme.mist)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func legend(peak: Int) -> some View {
        HStack(spacing: 6) {
            Spacer()
            Text("moins").font(.label(9)).foregroundStyle(Theme.mist)
            ForEach(0..<5, id: \.self) { step in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Self.intensity(turns: step * peak / 4, peak: peak))
                    .frame(width: 12, height: 12)
            }
            Text("plus").font(.label(9)).foregroundStyle(Theme.mist)
        }
    }

    /// Single-hue violet ramp. An empty hour keeps the neutral track colour so the
    /// grid never loses its shape, and the exponent lifts the quiet hours enough to
    /// stay visible next to a dominant peak. Light and dark both come from `Theme`.
    private static func intensity(turns: Int, peak: Int) -> Color {
        guard peak > 0, turns > 0 else { return Theme.track }
        let ratio = min(1, Double(turns) / Double(peak))
        return Theme.violet.opacity(0.18 + 0.82 * pow(ratio, 0.6))
    }

    private func initial(_ weekday: Int) -> String {
        guard Self.shortWeekdays.indices.contains(weekday - 1) else { return "" }
        return Self.shortWeekdays[weekday - 1].prefix(2).capitalized
    }

    private func tooltip(weekday: Int, hour: Int, turns: Int) -> String {
        let day = Self.standaloneWeekdays.indices.contains(weekday - 1)
            ? Self.standaloneWeekdays[weekday - 1]
            : ""
        let count: String
        switch turns {
        case 0: count = "aucun tour"
        case 1: count = "1 tour"
        default: count = FRFormat.plural(turns, "tour")
        }
        return "\(day) \(hour) h · \(count)"
    }
}

// MARK: - Cost per day

/// Daily cost bars. macOS 14's Swift Charts has no per-mark hover, so the bar under
/// the pointer is resolved from the plot geometry and echoed in the header.
struct ActivityCostChart: View {
    let days: [DayCost]
    let money: (Double) -> String

    @State private var hovered: DayCost.ID?

    private var hoveredDay: DayCost? { days.first { $0.id == hovered } }
    private var total: Double { days.reduce(0) { $0 + $1.costUSD } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if days.isEmpty {
                Text("Aucun coût enregistré sur cette période.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else {
                chart
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionLabel(text: "Coût par jour")
            Spacer()
            if let day = hoveredDay {
                Text("\(FRFormat.shortDate(day.day)) · \(money(day.costUSD))")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.blue)
            } else if !days.isEmpty {
                Text("total \(money(total))")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.slate)
            }
        }
    }

    private var chart: some View {
        Chart(days) { day in
            BarMark(
                x: .value("Jour", day.day, unit: .day),
                y: .value("Coût", day.costUSD),
                width: .ratio(0.6))
            .cornerRadius(3)
            .foregroundStyle(Theme.blue.opacity(hovered == nil || hovered == day.id ? 1 : 0.35))
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Theme.cardStroke)
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(money(raw))
                            .font(.label(9))
                            .foregroundStyle(Theme.mist)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(10, max(2, days.count)))) { _ in
                AxisGridLine().foregroundStyle(Theme.cardStroke)
                AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: false)
                    .foregroundStyle(Theme.slate)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let point) = phase,
                              let plot = proxy.plotFrame,
                              let date: Date = proxy.value(atX: point.x - geometry[plot].origin.x)
                        else {
                            hovered = nil
                            return
                        }
                        hovered = nearest(to: date)?.id
                    }
            }
        }
        .frame(height: 200)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Coût par jour")
        .accessibilityValue(summary)
    }

    private func nearest(to date: Date) -> DayCost? {
        days.min {
            abs($0.day.timeIntervalSince(date)) < abs($1.day.timeIntervalSince(date))
        }
    }

    private var summary: String {
        days.map { "\(FRFormat.shortDate($0.day)) : \(money($0.costUSD))" }.joined(separator: ", ")
    }
}

// MARK: - Tool mix

/// Tools ranked by call count, each bar sized against the busiest tool. The failing
/// share of a bar is the only thing painted red — the tool itself is never judged.
struct ActivityToolMix: View {
    let rows: [ToolMixRow]
    /// How many tools the card shows before it stops.
    var limit = 12

    private var top: [ToolMixRow] {
        Array(rows.sorted { $0.calls > $1.calls }.prefix(limit))
    }

    var body: some View {
        let top = top
        let peak = max(1, top.first?.calls ?? 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "Outils")
                Spacer()
                if rows.count > top.count {
                    Text("\(FRFormat.integer(top.count)) sur \(FRFormat.integer(rows.count))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                }
            }
            if top.isEmpty {
                Text("Aucun appel d'outil sur cette période.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            } else {
                VStack(spacing: 8) {
                    ForEach(top) { row in
                        bar(row, peak: peak)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
    }

    private func bar(_ row: ToolMixRow, peak: Int) -> some View {
        HStack(spacing: 10) {
            Text(row.id)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 120, alignment: .leading)
                .help(row.id)
            GeometryReader { geometry in
                let full = geometry.size.width * CGFloat(row.calls) / CGFloat(peak)
                let failed = full * CGFloat(row.errorRate)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    HStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(Theme.violet.opacity(0.75))
                                .frame(width: max(0, full - failed))
                            Rectangle()
                                .fill(Color.red.opacity(0.85))
                                .frame(width: failed)
                        }
                        .clipShape(Capsule())
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(height: 12)
            Text(FRFormat.integer(row.calls))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .frame(width: 52, alignment: .trailing)
            Text(row.errors > 0 ? FRFormat.percent(row.errorRate) : "")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.red)
                .frame(width: 46, alignment: .trailing)
                .help(row.errors > 0 ? "\(FRFormat.integer(row.errors)) appels en erreur" : "")
        }
    }
}

// MARK: - Model mix

/// Which models did the assistant turns, as one part-to-whole bar plus its legend.
struct ActivityModelShare: View {
    let models: [ModelCount]

    private static let palette: [Color] = [Theme.violet, Theme.blue, Theme.emerald, Theme.accent, Theme.slate]

    private var sorted: [ModelCount] { models.sorted { $0.turns > $1.turns } }
    private var total: Int { models.reduce(0) { $0 + $1.turns } }

    var body: some View {
        let sorted = sorted
        let total = total
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Modèles")
            if sorted.isEmpty || total == 0 {
                Text("Aucun modèle identifié sur cette période.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            } else {
                stackedBar(sorted, total: total)
                legend(sorted, total: total)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
    }

    private func stackedBar(_ rows: [ModelCount], total: Int) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    Self.color(index)
                        .frame(width: max(0, geometry.size.width * CGFloat(row.turns) / CGFloat(total)))
                }
            }
        }
        .frame(height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func legend(_ rows: [ModelCount], total: Int) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Self.color(index))
                        .frame(width: 9, height: 9)
                    Text(Self.shortName(row.model))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .help(row.model)
                    Spacer(minLength: 4)
                    Text(FRFormat.percent(Double(row.turns) / Double(total)))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.slate)
                    Text(FRFormat.plural(row.turns, "tour"))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .frame(width: 88, alignment: .trailing)
                }
            }
        }
    }

    /// Cycles the theme hues, then dims them, so a long tail stays distinguishable
    /// without any colour being written down here.
    private static func color(_ index: Int) -> Color {
        let base = palette[index % palette.count]
        let cycle = index / palette.count
        return cycle == 0 ? base : base.opacity(max(0.35, 1 - 0.25 * Double(cycle)))
    }

    /// `claude-opus-5-20260101` → `opus-5`. The full identifier stays in the tooltip.
    static func shortName(_ raw: String) -> String {
        var name = raw
        if name.hasPrefix("claude-") { name.removeFirst("claude-".count) }
        var parts = name.split(separator: "-")
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
            name = parts.joined(separator: "-")
        }
        return name.isEmpty ? raw : name
    }
}
