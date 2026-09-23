import SwiftUI
import CockpitShared
import QuotaKit
import RTKKit
import SessionsKit
import SkillsKit
import UsageKit

/// The landing screen: four KPI tiles, then the quota column on the left and the
/// insights + RTK week on the right. Every block carries its own banner, so a
/// failing source never blanks the page.
struct OverviewView: View {
    @Environment(CockpitStore.self) private var store
    @State private var now = Date()

    /// Today's sessions, from the store's own dedicated query rather than from
    /// `store.sessions`, which is the browser's filtered page.
    @State private var todaySessions: [SessionRef] = []
    /// When `todaySessions` was read — what "depuis minuit" and the relative time
    /// of the latest session are measured against.
    @State private var sessionsAsOf = Date()
    @State private var sessionsLoaded = false

    private var rtkWeekSaved: Int {
        store.rtk?.last7Days.reduce(0) { $0 + $1.savedTokens } ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                tiles
                HStack(alignment: .top, spacing: 16) {
                    quotaColumn.frame(maxWidth: .infinity, alignment: .leading)
                    sideColumn.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
        }
        .onAppear { now = Date() }
        // Re-read after every index pass: a session that started since the last one
        // would otherwise never reach the card.
        .task(id: store.sessionIndex.lastRun) {
            let asOf = Date()
            let rows = await store.todaySessions(now: asOf)
            guard !Task.isCancelled else { return }
            sessionsAsOf = asOf
            todaySessions = rows
            sessionsLoaded = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Vue d'ensemble").font(.display(24, weight: .bold))
                Text(updatedCaption).font(.system(size: 12)).foregroundStyle(Theme.slate)
            }
            Spacer()
        }
    }

    /// The freshest of the four sources — what "mis à jour" means at a glance.
    private var updatedCaption: String {
        let dates = [
            store.quotaState.lastSuccess, store.usageState.lastSuccess,
            store.rtkState.lastSuccess, store.skillsState.lastSuccess,
        ].compactMap { $0 }
        guard let latest = dates.max() else { return "Aucune source lue pour l'instant" }
        return "Mis à jour \(FRFormat.relative(latest, now: now))"
    }

    // MARK: Tiles

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
            StatTile(
                label: "Quota semaine",
                value: store.quota?.week.map { FRFormat.percent($0.utilization, fraction: false) } ?? "—",
                note: quotaTileNote,
                tint: QuotaFormat.tone(used: store.quota?.week?.utilization ?? 0, projection: store.weekProjection),
                icon: "gauge.with.dots.needle.33percent")
            StatTile(
                label: "Coût du jour",
                value: store.usage.map { store.money($0.costTodayUSD) } ?? "—",
                note: store.usage.map { "\(FRFormat.tokens($0.tokensToday)) tokens depuis minuit" },
                tint: Theme.blue,
                icon: "eurosign.circle")
            StatTile(
                label: "Tokens économisés RTK, 7 j",
                value: store.rtk == nil ? "—" : FRFormat.tokens(rtkWeekSaved),
                note: store.rtk.map { "\(FRFormat.tokens($0.today.savedTokens)) aujourd'hui" },
                tint: Theme.emerald,
                icon: "scissors")
            StatTile(
                label: "Skills actifs",
                value: store.skills.map { FRFormat.integer($0.count(kind: .skill, level: .global)) } ?? "—",
                note: store.skills.map { "\(FRFormat.integer($0.count(kind: .skill))) au total, tous niveaux" },
                tint: Theme.violet,
                icon: "sparkles")
        }
    }

    private var quotaTileNote: String? {
        guard let projection = store.weekProjection else { return nil }
        return "Réinitialisation dans " + FRFormat.duration(projection.hoursLeft * 3600)
    }

    // MARK: Left column — quotas

    private var quotaColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Quota hebdomadaire")
            if let message = store.quotaState.errorMessage {
                SourceBanner(
                    kind: .warning,
                    message: QuotaFormat.bannerMessage(message),
                    action: { Task { await store.refreshQuota(force: true) } })
            }
            if store.quota == nil && store.quotaState.isLoading {
                QuotaSkeleton(rows: 3)
            } else {
                QuotaHeroCard(
                    week: store.quota?.week,
                    projection: store.weekProjection,
                    isLoading: store.quotaState.isLoading)
                if let session = store.quota?.session {
                    QuotaMeterCard(meter: session, now: now)
                }
                QuotaBudgetCard(projection: store.weekProjection)
            }
        }
    }

    // MARK: Right column — insights & RTK

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Insights")
            insightsCard
            SectionLabel(text: "Sessions aujourd'hui")
            sessionsTodayCard
            SectionLabel(text: "7 derniers jours")
            rtkWeekCard
        }
    }

    // MARK: Sessions today

    /// Recorded cost where the transcript has one, priced from the per-model
    /// tokens everywhere else, and a count of the sessions that offer neither.
    /// A missing cost is never counted as zero.
    private var todayCost: (total: Double, missing: Int) {
        todaySessions.reduce(into: (total: 0.0, missing: 0)) { result, session in
            if let cost = store.sessionCost(session) { result.total += cost.usd } else { result.missing += 1 }
        }
    }

    private var sessionsTodayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = store.sessionsState.errorMessage {
                SourceBanner(
                    kind: .info,
                    message: "Index des sessions indisponible : \(message)",
                    action: { Task { await store.indexSessions() } },
                    actionTitle: "Réindexer")
            } else if !sessionsLoaded || (todaySessions.isEmpty && store.sessionIndex.isRunning) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(store.sessionIndex.isRunning
                        ? "Indexation des transcripts en cours…"
                        : "Lecture des sessions du jour…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else if todaySessions.isEmpty {
                Text("Aucune session depuis minuit.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(FRFormat.integer(todaySessions.count))
                        .font(.display(26))
                        .monospacedDigit()
                        .foregroundStyle(Theme.violet)
                    Text(todaySessions.count < 2 ? "session" : "sessions")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.slate)
                    Spacer()
                    Text(costLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.blue)
                }
                if let latest = todaySessions.first {
                    Text(latest.title)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("dernière activité \(FRFormat.relative(latest.lastTimestamp, now: sessionsAsOf))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                }
                if todayCost.missing > 0 {
                    Text(costCaveat)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }

    private var costLabel: String {
        let cost = todayCost
        // Every session lacking its cost line: a total would be a fabricated zero.
        if cost.missing == todaySessions.count { return "coût inconnu" }
        return store.money(cost.total)
    }

    private var costCaveat: String {
        let missing = todayCost.missing
        return missing == todaySessions.count
            ? "Aucune de ces sessions n'a enregistré son coût."
            : "Coût partiel : \(FRFormat.plural(missing, "session")) sans coût enregistré."
    }

    private var insightsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message = store.usageState.errorMessage {
                SourceBanner(kind: .error, message: message, action: { Task { await store.refreshUsage() } })
            } else if let insights = store.usage?.insights, !notable(insights).isEmpty {
                let rows = notable(insights)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, insight in
                    if index > 0 { Divider().opacity(0.4) }
                    insightRow(insight)
                }
            } else {
                Text(store.usage == nil ? "Lecture des transcripts…" : "Rien de notable sur la période analysée.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
        }
        .padding(14)
        .card()
    }

    /// `noNotableChange` is an empty state, not a bullet.
    private func notable(_ insights: [Insight]) -> [Insight] {
        insights.filter { $0.kind != .noNotableChange }
    }

    private func insightRow(_ insight: Insight) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(insight.level))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color(insight.level))
                .frame(width: 18)
            Text(sentence(insight))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private func color(_ level: Insight.Level) -> Color {
        switch level {
        case .critical: .red
        case .warning: .orange
        case .good: Theme.emerald
        case .info: Theme.blue
        }
    }
    private func icon(_ level: Insight.Level) -> String {
        switch level {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .good: "checkmark.seal.fill"
        case .info: "info.circle.fill"
        }
    }

    /// The engine's sentence is English; `kind` carries the same information, so the
    /// French wording is rebuilt here rather than translated.
    private func sentence(_ insight: Insight) -> String {
        switch insight.kind {
        case .costUp(let fraction):
            return "Le coût a augmenté de \(FRFormat.percent(fraction)) par rapport à la semaine précédente."
        case .costDown(let fraction):
            return "Le coût a baissé de \(FRFormat.percent(fraction)) par rapport à la semaine précédente."
        case .unpricedModel(let model):
            return "Le modèle \(model) n'a pas de tarif dédié : le tarif Sonnet lui est appliqué."
        case .cacheHitRate(let rate):
            return "Le cache est bien utilisé : \(FRFormat.percent(rate)) des tokens réutilisables sont relus."
        case .noNotableChange:
            return "Rien de notable sur la période analysée."
        }
    }

    private var rtkWeekCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = store.rtkState.errorMessage {
                SourceBanner(kind: .info, message: message, action: { Task { await store.refreshRTK() } })
            } else if let days = store.rtk?.last7Days, !days.isEmpty {
                let peak = max(1, days.map(\.savedTokens).max() ?? 1)
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(days) { day in
                        VStack(spacing: 6) {
                            Capsule()
                                .fill(day.savedTokens > 0 ? Theme.emerald : Theme.track)
                                .frame(height: max(4, 74 * CGFloat(day.savedTokens) / CGFloat(peak)))
                            Text(FRFormat.weekday(day.date))
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.slate)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 96, alignment: .bottom)
                Text("\(FRFormat.tokens(rtkWeekSaved)) tokens évités sur sept jours")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
            } else {
                Text(store.rtk == nil ? "Lecture de la base rtk…" : "Aucune commande filtrée ces sept derniers jours.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }
}
