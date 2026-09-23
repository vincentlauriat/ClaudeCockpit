// "Activité" tab of the Sessions section — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import SwiftUI
import CockpitShared
import SessionsKit
import UsageKit

/// Local analytics derived from the transcript index: when the work happens, what it
/// costs per day, which tools and which models. Everything comes from one
/// `ActivityReport`, so the range and the project filter are the only two inputs.
struct SessionsActivityView: View {
    @Environment(CockpitStore.self) private var store
    @AppStorage(SettingsKey.sessionsIndexEnabled) private var indexEnabled = true

    @State private var range: ActivityRange = .month
    @State private var projectCwd: String?
    @State private var projects: [ProjectCount] = []
    @State private var report: ActivityReport?

    /// "Now" for the relative ranges, held in state rather than recomputed inside
    /// `interval`: a fresh `Date()` there would change the reload key on every redraw
    /// and re-query the index endlessly. It is refreshed when the range changes and
    /// after every index pass, so a tab left open overnight stops calling yesterday
    /// "aujourd'hui".
    @State private var anchor = Date()
    /// Forces a reload the interval alone cannot express — a re-index while the range
    /// is `custom`, whose bounds do not move with `anchor`.
    @State private var reloadToken = 0
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var customEnd = Date()

    private let tileColumns = [GridItem(.adaptive(minimum: 170, maximum: 280), spacing: 12)]
    private let cardColumns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                filterBar
                if let message = store.sessionsState.errorMessage {
                    SourceBanner(
                        kind: .error,
                        message: "Lecture de l'index impossible : \(message)",
                        action: { Task { await store.indexSessions() } },
                        actionTitle: "Réindexer")
                }
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .task { projects = await store.sessionProjects() }
        .task(id: reloadKey) { await load() }
        // A pass over the archive can add turns, days and tools to the current range;
        // without this the tab would keep showing the numbers it loaded on arrival.
        .onChange(of: store.sessionIndex.lastRun) { _, _ in
            anchor = Date()
            reloadToken += 1
            Task { projects = await store.sessionProjects() }
        }
    }

    // MARK: Inputs

    /// Everything a reload depends on, in one `Hashable` so `.task(id:)` fires once
    /// per real change instead of once per redraw.
    private struct ReloadKey: Hashable {
        let since: Date
        let until: Date
        let project: String?
        let token: Int
    }

    private var reloadKey: ReloadKey {
        let interval = interval
        return ReloadKey(
            since: interval.since, until: interval.until,
            project: projectCwd, token: reloadToken)
    }

    private var interval: (since: Date, until: Date) {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: anchor)
        switch range {
        case .day:
            return (startOfToday, anchor)
        case .week:
            return (calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday, anchor)
        case .month:
            return (calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday, anchor)
        case .custom:
            let lower = calendar.startOfDay(for: min(customStart, customEnd))
            let upperDay = calendar.startOfDay(for: max(customStart, customEnd))
            let upper = calendar.date(byAdding: .day, value: 1, to: upperDay) ?? upperDay
            return (lower, upper)
        }
    }

    private func load() async {
        report = nil
        let interval = interval
        let fresh = await store.sessionActivity(
            since: interval.since, until: interval.until, projectCwd: projectCwd)
        guard !Task.isCancelled else { return }
        report = fresh
    }

    // MARK: Filter bar

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Période")
                    Picker("", selection: rangeBinding) {
                        ForEach(ActivityRange.allCases) { value in
                            Text(value.title).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(minWidth: 320, maxWidth: 420)
                }
                Divider().frame(height: 32)
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Projet")
                    Picker("", selection: $projectCwd) {
                        Text("Tous les projets").tag(String?.none)
                        ForEach(projects) { project in
                            Text(UsagePath.shorten(project.cwd)).tag(String?.some(project.cwd))
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 220, maxWidth: 320)
                }
                Spacer(minLength: 0)
            }
            if range == .custom {
                HStack(spacing: 16) {
                    DatePicker("Du", selection: $customStart, displayedComponents: .date)
                    DatePicker("Au", selection: $customEnd, displayedComponents: .date)
                    Spacer(minLength: 0)
                }
                .environment(\.locale, FRFormat.locale)
                .font(.system(size: 12))
            }
        }
        .panelStyle()
    }

    private var rangeBinding: Binding<ActivityRange> {
        Binding(
            get: { range },
            set: { value in
                // A new relative range measures from now, not from the last reload.
                anchor = Date()
                range = value
            })
    }

    // MARK: Body states

    @ViewBuilder
    private var content: some View {
        if !indexEnabled {
            ActivityPlaceholder(
                icon: "square.stack.3d.up.slash",
                title: "Indexation désactivée",
                message: "Activez « Indexer les transcripts » dans les réglages pour alimenter cette section.")
        } else if let report {
            if report.sessions == 0 && report.turns == 0 {
                ActivityPlaceholder(
                    icon: "tray",
                    title: "Aucune activité sur cette période",
                    message: "Élargissez la période ou retirez le filtre projet pour voir davantage de sessions.")
            } else {
                dashboard(report)
            }
        } else if store.sessionIndex.isRunning {
            ActivityPlaceholder(
                icon: "hourglass",
                title: "Indexation en cours",
                message: "\(FRFormat.integer(store.sessionIndex.filesDone)) transcripts sur \(FRFormat.integer(store.sessionIndex.filesTotal)) analysés.",
                isBusy: true)
        } else {
            ActivityPlaceholder(
                icon: "hourglass",
                title: "Calcul de l'activité…",
                message: "Agrégation des tours, des outils et des coûts sur la période choisie.",
                isBusy: true)
        }
    }

    private func dashboard(_ report: ActivityReport) -> some View {
        let money: (Double) -> String = { store.money($0) }
        return VStack(alignment: .leading, spacing: 16) {
            totals(report)
            ActivityHeatmapCard(buckets: report.buckets)
            ActivityCostChart(days: report.days, money: money)
            LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 16) {
                ActivityToolMix(rows: report.tools)
                ActivityModelShare(models: report.models)
            }
        }
    }

    private func totals(_ report: ActivityReport) -> some View {
        LazyVGrid(columns: tileColumns, spacing: 12) {
            StatTile(
                label: "Sessions",
                value: FRFormat.integer(report.sessions),
                note: range.note,
                icon: "bubble.left.and.bubble.right")
            StatTile(
                label: "Tours",
                value: FRFormat.tokens(report.turns),
                note: "tours assistant",
                tint: Theme.violet,
                icon: "arrow.triangle.2.circlepath")
            StatTile(
                label: "Appels d'outils",
                value: FRFormat.tokens(report.toolCalls),
                note: toolErrorNote(report),
                tint: Theme.accent,
                icon: "wrench.and.screwdriver")
            StatTile(
                label: "Coût",
                value: store.money(report.costUSD),
                note: "d'après les transcripts",
                tint: Theme.blue,
                icon: "creditcard")
        }
    }

    private func toolErrorNote(_ report: ActivityReport) -> String {
        let errors = report.tools.reduce(0) { $0 + $1.errors }
        guard errors > 0 else { return "aucune erreur" }
        return "\(FRFormat.integer(errors)) en erreur"
    }
}
