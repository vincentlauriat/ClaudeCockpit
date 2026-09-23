// Sessions browser — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import Combine
import SwiftUI
import CockpitShared
import SessionsKit
import UsageKit

/// Left: every indexed session, grouped and filtered. Right: the transcript of the
/// selected one. The list never reads a transcript itself — everything on a row
/// comes from the index.
struct SessionsBrowserView: View {
    @Environment(CockpitStore.self) private var store
    @AppStorage(SettingsKey.sessionsGrouping) private var groupingRaw = SessionGrouping.day.rawValue

    @State private var searchText = ""
    @State private var debounce: Task<Void, Never>?
    @State private var selection: String?
    @State private var hits: [SearchHit] = []
    @State private var projects: [ProjectCount] = []
    @State private var period: Period = .all
    @State private var now = Date()
    @State private var targetMessageId: String?
    @FocusState private var searchFocused: Bool

    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    enum SessionGrouping: String, CaseIterable, Identifiable {
        case day, project
        var id: String { rawValue }
        var title: String {
            switch self {
            case .day: return "Par jour"
            case .project: return "Par projet"
            }
        }
    }

    enum Period: String, CaseIterable, Identifiable {
        case today, week, month, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .today: return "Aujourd'hui"
            case .week: return "7 j"
            case .month: return "30 j"
            case .all: return "Tout"
            }
        }
        func since(_ reference: Date, calendar: Calendar = .current) -> Date? {
            switch self {
            case .today: return calendar.startOfDay(for: reference)
            case .week: return calendar.date(byAdding: .day, value: -7, to: reference)
            case .month: return calendar.date(byAdding: .day, value: -30, to: reference)
            case .all: return nil
            }
        }
    }

    private var grouping: SessionGrouping {
        SessionGrouping(rawValue: groupingRaw) ?? .day
    }

    var body: some View {
        VStack(spacing: 0) {
            filterHeader
            Divider().opacity(0.4)
            HSplitView {
                listPane
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 520)
                detailPane
                    .frame(minWidth: 420)
            }
        }
        .onReceive(clock) { now = $0 }
        .task { projects = await store.sessionProjects() }
        .onChange(of: store.sessionIndex.lastRun) { _, _ in
            Task { projects = await store.sessionProjects() }
        }
        .onChange(of: searchText) { _, value in scheduleSearch(value) }
        .onDisappear { debounce?.cancel() }
    }

    // MARK: - Header

    private var filterHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                searchField
                Spacer(minLength: 8)
                Picker("Regroupement", selection: $groupingRaw) {
                    ForEach(SessionGrouping.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            chips
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.panel)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.slate)
            TextField("Rechercher dans tous les transcripts", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.mist)
                .accessibilityLabel("Effacer la recherche")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .frame(maxWidth: 320)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                projectMenu
                periodMenu
                SessionChip(
                    title: "Étoilées", systemImage: "star",
                    active: store.sessionFilter.starredOnly, tint: Theme.accent
                ) { store.sessionFilter.starredOnly.toggle() }
                SessionChip(
                    title: "Avec erreurs", systemImage: "exclamationmark.triangle",
                    active: store.sessionFilter.withErrorsOnly, tint: .red
                ) { store.sessionFilter.withErrorsOnly.toggle() }
                SessionChip(
                    title: "Sous-agents", systemImage: "person.2",
                    active: store.sessionFilter.includeSubagents, tint: Theme.violet
                ) { store.sessionFilter.includeSubagents.toggle() }
            }
            .padding(.vertical, 1)
        }
    }

    private var projectMenu: some View {
        Menu {
            Button("Tous les projets") { store.sessionFilter.projectCwd = nil }
            Divider()
            ForEach(projects) { project in
                Button("\(UsagePath.shorten(project.cwd)) (\(project.sessions))") {
                    store.sessionFilter.projectCwd = project.cwd
                }
            }
        } label: {
            SessionChip(
                title: store.sessionFilter.projectCwd.map { UsagePath.shorten($0) } ?? "Projet",
                systemImage: "folder",
                active: store.sessionFilter.projectCwd != nil,
                tint: Theme.blue)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var periodMenu: some View {
        Menu {
            ForEach(Period.allCases) { value in
                Button(value.title) {
                    period = value
                    store.sessionFilter.since = value.since(Date())
                }
            }
        } label: {
            SessionChip(
                title: period.title,
                systemImage: "calendar",
                active: period != .all,
                tint: Theme.blue)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Search

    /// The store's `sessionFilter` re-queries on every assignment, so the query
    /// only lands once the typing has stopped.
    private func scheduleSearch(_ value: String) {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            store.sessionFilter.query = trimmed
            hits = trimmed.isEmpty ? [] : await store.searchSessions(trimmed)
        }
    }

    private var hitsBySession: [String: [SearchHit]] {
        Dictionary(grouping: hits, by: \.sessionId)
    }

    // MARK: - List

    @ViewBuilder
    private var listPane: some View {
        if store.sessions.isEmpty {
            emptyState
        } else {
            List(selection: $selection) {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.items) { session in
                            SessionRowView(
                                session: session,
                                now: now,
                                hits: hitsBySession[session.id] ?? [],
                                onSelectHit: { hit in
                                    selection = hit.sessionId
                                    targetMessageId = hit.messageId
                                })
                                .tag(session.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .onKeyPress(keys: ["j", "k"]) { press in
                guard !searchFocused else { return .ignored }
                move(by: press.key == "j" ? 1 : -1)
                return .handled
            }
        }
    }

    private var flattenedIds: [String] {
        groups.flatMap { $0.items.map(\.id) }
    }

    private func move(by delta: Int) {
        let ids = flattenedIds
        guard !ids.isEmpty else { return }
        guard let current = selection, let index = ids.firstIndex(of: current) else {
            selection = ids.first
            return
        }
        let next = min(max(0, index + delta), ids.count - 1)
        selection = ids[next]
    }

    // MARK: - Grouping

    struct SessionGroupRows: Identifiable {
        let id: String
        let title: String
        let items: [SessionRef]
    }

    private var groups: [SessionGroupRows] {
        switch grouping {
        case .day: return dayGroups
        case .project: return projectGroups
        }
    }

    private var dayGroups: [SessionGroupRows] {
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: store.sessions) {
            calendar.startOfDay(for: $0.lastTimestamp)
        }
        let formatter = ISO8601DateFormatter()
        return buckets.keys.sorted(by: >).map { day in
            SessionGroupRows(
                id: formatter.string(from: day),
                title: dayTitle(day, calendar: calendar),
                items: (buckets[day] ?? []).sorted { $0.lastTimestamp > $1.lastTimestamp })
        }
    }

    private func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Aujourd'hui" }
        if calendar.isDateInYesterday(day) { return "Hier" }
        return FRFormat.shortDate(day)
    }

    private var projectGroups: [SessionGroupRows] {
        let buckets = Dictionary(grouping: store.sessions, by: \.cwd)
        let ordered = buckets.keys.sorted { left, right in
            let lastLeft = buckets[left]?.map(\.lastTimestamp).max() ?? .distantPast
            let lastRight = buckets[right]?.map(\.lastTimestamp).max() ?? .distantPast
            return lastLeft > lastRight
        }
        return ordered.map { cwd in
            SessionGroupRows(
                id: cwd,
                title: UsagePath.shorten(cwd),
                items: (buckets[cwd] ?? []).sorted { $0.lastTimestamp > $1.lastTimestamp })
        }
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: 10) {
            if store.sessionIndex.isRunning {
                ProgressView().controlSize(.small)
                Text("Indexation des transcripts…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("\(store.sessionIndex.filesDone) fichiers sur \(store.sessionIndex.filesTotal). La liste se remplit au fur et à mesure.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: emptyIcon)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.mist)
                Text(emptyTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .multilineTextAlignment(.center)
                if store.sessionIndex.lastRun == nil {
                    Button("Indexer maintenant") { Task { await store.indexSessions() } }
                        .controlSize(.small)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hasActiveFilter: Bool {
        let filter = store.sessionFilter
        return !filter.query.isEmpty || filter.projectCwd != nil || filter.since != nil
            || filter.starredOnly || filter.withErrorsOnly
    }

    private var emptyIcon: String {
        if store.sessionIndex.lastRun == nil { return "tray" }
        return hasActiveFilter ? "line.3.horizontal.decrease.circle" : "text.bubble"
    }

    private var emptyTitle: String {
        if store.sessionIndex.lastRun == nil { return "Index non construit" }
        if hasActiveFilter { return "Aucun résultat" }
        return "Aucune session indexée"
    }

    private var emptyMessage: String {
        if store.sessionIndex.lastRun == nil {
            return "Les transcripts de ~/.claude/projects n'ont pas encore été lus."
        }
        if hasActiveFilter {
            return "Aucune session ne correspond à ce filtre. Élargissez la période ou retirez un critère."
        }
        return "Aucun transcript trouvé dans ~/.claude/projects."
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let id = selection, let session = store.sessions.first(where: { $0.id == id }) {
            SessionDetailView(session: session, targetMessageId: $targetMessageId)
                .id(session.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.mist)
                Text("Sélectionnez une session")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Le transcript complet s'affiche ici : tours, appels d'outils, diffs et sous-agents.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
    }
}

// MARK: - Row

/// One session in the list. Everything shown comes from the index, except the
/// health grade, which is queried when the row scrolls into view.
///
/// `SessionHealthRule.evaluate` takes messages, so grading a session may cost a
/// materialised transcript. If it turns out to, this badge must fall back to the
/// `toolErrors` / `toolCalls` already carried by `SessionRef`: one query per
/// visible row across a fast scroll would be exactly the eager read the spec
/// forbids.
private struct SessionRowView: View {
    let session: SessionRef
    let now: Date
    let hits: [SearchHit]
    let onSelectHit: (SearchHit) -> Void

    @Environment(CockpitStore.self) private var store
    @State private var health: SessionHealth?

    private var isLive: Bool {
        now.timeIntervalSince(session.lastTimestamp) < SessionsPalette.liveWindow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleLine
            Text(UsagePath.shorten(session.cwd))
                .font(.system(size: 11))
                .foregroundStyle(Theme.slate)
                .lineLimit(1)
                .truncationMode(.head)
            statsLine
            ForEach(Array(hits.prefix(3))) { hit in
                Button { onSelectHit(hit) } label: {
                    Text(SessionsPalette.oneLine(hit.snippet, limit: 180))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                        .lineLimit(2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.accent.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Ouvrir ce message dans le transcript")
            }
        }
        .padding(.vertical, 4)
        .task(id: session.id) { health = await store.sessionHealth(session.id) }
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Button {
                Task { await store.setSessionStarred(!session.isStarred, sessionId: session.id) }
            } label: {
                Image(systemName: session.isStarred ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(session.isStarred ? Theme.accent : Theme.mist)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.isStarred ? "Retirer des favoris" : "Mettre en favori")

            Text(session.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)

            if isLive {
                Circle()
                    .fill(Theme.emerald)
                    .frame(width: 6, height: 6)
                    .help("Session active à l'instant")
                    .accessibilityLabel("Session active")
            }
            if session.isSubagent {
                Image(systemName: "person.2")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.violet)
                    .help("Transcript de sous-agent")
            }
            Spacer(minLength: 4)
            if let health {
                HealthBadge(grade: health.grade, compact: true)
            }
        }
    }

    private var statsLine: some View {
        HStack(spacing: 8) {
            Text(FRFormat.time(session.firstTimestamp))
            Text(FRFormat.duration(session.duration))
            Text("\(FRFormat.integer(session.userTurns + session.assistantTurns)) tours")
            if session.toolErrors > 0 {
                Text("\(FRFormat.integer(session.toolErrors)) err.").foregroundStyle(.red)
            }
            Spacer(minLength: 4)
            Text(session.costStateUSD.map { store.money($0) } ?? "–")
                .foregroundStyle(session.costStateUSD == nil ? Theme.mist : Theme.blue)
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(Theme.mist)
    }
}
