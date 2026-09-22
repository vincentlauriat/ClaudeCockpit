import SwiftUI
import CockpitShared
import UsageKit

/// Local usage dashboard: everything read from `~/.claude/projects` transcripts, aggregated by
/// UsageKit and filtered through `store.usageFilters`.
struct UsageView: View {
    @Environment(CockpitStore.self) private var store

    private let cardColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        @Bindable var store = store
        let money: (Double) -> String = { store.money($0) }

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let message = store.usageState.errorMessage {
                    SourceBanner(
                        kind: .error,
                        message: "Lecture de l'usage impossible : \(message). Aucun transcript trouvé dans ~/.claude/projects ?",
                        action: { Task { await store.refreshUsage(rescan: true) } },
                        actionTitle: "Rescanner")
                }
                UsageFilterBar(
                    filters: $store.usageFilters,
                    availableFamilies: store.usage?.availableModelFamilies ?? [],
                    availableProjects: store.usage?.availableProjects ?? [])
                content(money: money)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Usage local")
                    .font(.display(22))
                    .foregroundStyle(Theme.ink)
                Text(updatedLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
            }
            Spacer(minLength: 12)
            if store.usageState.isLoading {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await store.refreshUsage(rescan: true) }
            } label: {
                Label("Rescanner", systemImage: "arrow.clockwise")
            }
            .disabled(store.usageState.isLoading)
            .help("Relire tous les transcripts de ~/.claude/projects")
        }
    }

    private var updatedLabel: String {
        guard let date = store.usageLastScan else { return "Analyse des transcripts…" }
        return "Mis à jour \(FRFormat.relative(date))"
    }

    // MARK: Body states

    @ViewBuilder
    private func content(money: @escaping (Double) -> String) -> some View {
        if let usage = store.usage, usage.filteredEventCount > 0 {
            dashboard(usage, money: money)
        } else if store.usage == nil && store.usageState.errorMessage == nil {
            placeholder(
                icon: "hourglass",
                title: "Lecture des transcripts…",
                message: "Premier scan de ~/.claude/projects, cela peut prendre quelques secondes.")
        } else if store.usageState.errorMessage == nil {
            placeholder(
                icon: "tray",
                title: "Aucun usage sur cette période",
                message: "Élargissez la période ou retirez le filtre projet pour voir davantage d'activité.")
        }
    }

    private func placeholder(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.mist)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.slate)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .panelStyle()
    }

    private func dashboard(_ usage: UsageSnapshot, money: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            UsageStatGrid(totals: usage.totals, range: usage.filters.range, money: money)
            LazyVGrid(columns: cardColumns, spacing: 16) {
                SessionsPerWeekCard(
                    lastWeek: usage.sessionsLastWeekByWeekday,
                    thisWeek: usage.sessionsThisWeekByWeekday,
                    lastWeekTotal: usage.sessionsLastWeekTotal,
                    thisWeekTotal: usage.sessionsThisWeekTotal)
                CostPerHourCard(
                    yesterday: usage.hourlyYesterday,
                    today: usage.hourlyToday,
                    money: money)
                UsageInsightsCard(insights: usage.insights)
                ModelMixCard(rows: usage.costByFamily, money: money)
            }
            DailyUsageChartCard(daily: usage.daily, range: usage.filters.range, money: money)
            UsageBreakdownTable(snapshot: usage, money: money)
            UsageSessionsList(sessions: usage.sessions, money: money)
        }
    }
}
