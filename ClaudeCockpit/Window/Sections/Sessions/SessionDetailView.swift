// Session transcript detail — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import AppKit
import SwiftUI
import CockpitShared
import SessionsKit
import UsageKit

/// The full transcript of one session, paged.
///
/// A session can hold tens of thousands of lines and the benchmark transcript is
/// 35 MB, so the body never asks for more than ``pageSize`` messages at a time and
/// appends the next page as the reader nears the end. `sessionMessageCount` gives
/// the total so the footer can say how far in the reader is.
struct SessionDetailView: View {
    let session: SessionRef
    /// A message the browser wants scrolled to — a search hit, typically.
    @Binding var targetMessageId: String?

    @Environment(CockpitStore.self) private var store
    @AppStorage(SettingsKey.sessionsShowSystemLines) private var showSystemLines = false

    @State private var messages: [SessionMessage] = []
    /// `toolUseId → tool_result`, rebuilt as pages land. A call and its result sit
    /// on two transcript lines, so a page boundary can separate them.
    @State private var results: [String: ContentBlock] = [:]
    @State private var elapsedById: [String: TimeInterval] = [:]
    @State private var total = 0
    @State private var isLoading = false
    @State private var reachedEnd = false
    @State private var health: SessionHealth?
    @State private var showHealth = false
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var confirmHide = false
    @State private var findVisible = false
    @State private var findQuery = ""
    @State private var findMatches: [String] = []
    @State private var findIndex = 0
    @State private var scrollTarget: String?
    @State private var targetMissing = false
    @State private var isChasingTarget = false
    @FocusState private var findFocused: Bool
    @FocusState private var titleFocused: Bool

    private static let pageSize = 200

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if findVisible {
                findBar
                Divider().opacity(0.4)
            }
            transcript
        }
        .background(Theme.background)
        .task(id: session.id) { await reload() }
        .onChange(of: showSystemLines) { _, _ in
            // Not a display filter: the store passes it to the service as
            // `includeMeta`, so the pages themselves change and must be refetched.
            Task { await reload() }
        }
        .onChange(of: targetMessageId) { _, _ in resolveTarget() }
        .onChange(of: findQuery) { _, _ in recomputeMatches() }
        .alert("Masquer cette session ?", isPresented: $confirmHide) {
            Button("Annuler", role: .cancel) {}
            Button("Masquer", role: .destructive) {
                Task { await store.hideSession(session.id) }
            }
        } message: {
            Text("La session disparaît de la liste. Le transcript sur le disque n'est jamais modifié et une reconstruction de l'index la fera revenir.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                titleField
                Spacer(minLength: 8)
                toolbar
            }
            metaLine
            statsLine
            if !session.prLinks.isEmpty { prLine }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.panel)
    }

    @ViewBuilder
    private var titleField: some View {
        if isEditingTitle {
            TextField("Titre de la session", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.display(16))
                .foregroundStyle(Theme.ink)
                .focused($titleFocused)
                .onSubmit { commitTitle() }
                .frame(maxWidth: 420)
        } else {
            HStack(spacing: 6) {
                Text(session.title)
                    .font(.display(16))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Button {
                    titleDraft = session.customName ?? session.title
                    isEditingTitle = true
                    titleFocused = true
                } label: {
                    Image(systemName: "pencil").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.mist)
                .help("Renommer la session")
                .accessibilityLabel("Renommer la session")
            }
        }
    }

    private func commitTitle() {
        isEditingTitle = false
        titleFocused = false
        let draft = titleDraft
        Task { await store.renameSession(session.id, to: draft) }
    }

    private var metaLine: some View {
        HStack(spacing: 8) {
            Label(UsagePath.shorten(session.cwd), systemImage: "folder")
                .lineLimit(1)
                .truncationMode(.head)
            if let branch = session.gitBranch, !branch.isEmpty {
                Label(branch, systemImage: "arrow.triangle.branch").lineLimit(1)
            }
            if let version = session.claudeVersion, !version.isEmpty {
                Label("Claude Code \(version)", systemImage: "app.badge").lineLimit(1)
            }
            Label(FRFormat.dateTime(session.firstTimestamp), systemImage: "calendar")
            Label(FRFormat.duration(session.duration), systemImage: "clock")
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.slate)
    }

    private var statsLine: some View {
        HStack(spacing: 6) {
            SessionChip(title: "Entrée \(FRFormat.tokens(session.inputTokens))", tint: Theme.blue)
            SessionChip(title: "Sortie \(FRFormat.tokens(session.outputTokens))", tint: Theme.blue)
            SessionChip(
                title: "Cache \(FRFormat.tokens(session.cacheReadTokens + session.cacheCreationTokens))",
                tint: Theme.blue)
            if let cost = session.costStateUSD {
                SessionChip(title: store.money(cost), systemImage: "eurosign.circle", active: true, tint: Theme.blue)
            }
            SessionChip(title: FRFormat.plural(session.toolCalls, "outil"), systemImage: "wrench.and.screwdriver")
            if session.toolErrors > 0 {
                SessionChip(
                    title: FRFormat.plural(session.toolErrors, "erreur"),
                    systemImage: "exclamationmark.triangle", active: true, tint: .red)
            }
            Spacer(minLength: 8)
            healthControl
        }
    }

    @ViewBuilder
    private var healthControl: some View {
        if let health {
            Button { showHealth.toggle() } label: {
                HStack(spacing: 5) {
                    HealthBadge(grade: health.grade)
                    Text("\(health.score)/100")
                        .font(.data(10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.slate)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Détail de la note de santé")
            .popover(isPresented: $showHealth, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        HealthBadge(grade: health.grade)
                        Text("Santé de la session · \(health.score)/100")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    if health.evidence.isEmpty {
                        Text("Aucun incident relevé.").font(.system(size: 12)).foregroundStyle(Theme.slate)
                    } else {
                        ForEach(Array(health.evidence.enumerated()), id: \.offset) { _, line in
                            Label(line, systemImage: "circle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.slate)
                        }
                    }
                }
                .padding(14)
                .frame(width: 340, alignment: .leading)
            }
        }
    }

    private var prLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 11))
                .foregroundStyle(Theme.violet)
            ForEach(session.prLinks, id: \.url) { link in
                Link("#\(link.number) \(link.repository)", destination: link.url)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.violet)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await store.setSessionStarred(!session.isStarred, sessionId: session.id) }
            } label: {
                Image(systemName: session.isStarred ? "star.fill" : "star")
                    .foregroundStyle(session.isStarred ? Theme.accent : Theme.mist)
            }
            .buttonStyle(.plain)
            .help(session.isStarred ? "Retirer des favoris" : "Mettre en favori")
            .accessibilityLabel(session.isStarred ? "Retirer des favoris" : "Mettre en favori")

            Button {
                store.resumeSession(session)
            } label: {
                Label("Reprendre dans le Terminal", systemImage: "play.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.canResume(session) ? Theme.emerald : Theme.mist)
            .disabled(!store.canResume(session))
            .help(store.canResume(session)
                  ? "Reprendre dans le Terminal"
                  : "Le dossier de travail de cette session n'existe plus")
            .accessibilityLabel("Reprendre dans le Terminal")

            Button {
                Task { await store.revealTranscript(session) }
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.mist)
            .help("Révéler le transcript dans le Finder")
            .accessibilityLabel("Révéler le transcript")

            Menu {
                Button("Markdown") { Task { await store.exportSession(session, format: .markdown) } }
                Button("HTML") { Task { await store.exportSession(session, format: .html) } }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help("Exporter la session")
            .accessibilityLabel("Exporter la session")

            Button {
                copyIdentifier()
            } label: {
                Image(systemName: "number")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.mist)
            .help("Copier l'identifiant de la session")
            .accessibilityLabel("Copier l'identifiant")

            Button {
                findVisible = true
                findFocused = true
            } label: {
                Image(systemName: "text.magnifyingglass")
            }
            .buttonStyle(.plain)
            .foregroundStyle(findVisible ? Theme.accent : Theme.mist)
            .keyboardShortcut("f", modifiers: .command)
            .help("Rechercher dans la session (Cmd+F)")
            .accessibilityLabel("Rechercher dans la session")

            Button {
                confirmHide = true
            } label: {
                Image(systemName: "eye.slash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.mist)
            .help("Masquer cette session de la liste")
            .accessibilityLabel("Masquer la session")
        }
        .font(.system(size: 13))
    }

    private func copyIdentifier() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.id, forType: .string)
        store.notice = "Identifiant copié : \(session.id)"
    }

    // MARK: - Find bar

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.slate)
            TextField("Rechercher dans les tours chargés", text: $findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($findFocused)
                .onSubmit { step(1) }
            if !findQuery.isEmpty {
                Text(findMatches.isEmpty
                     ? "Aucun tour"
                     : "\(findIndex + 1) sur \(findMatches.count)")
                    .font(.data(11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.slate)
            }
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.mist)
                .keyboardShortcut("[", modifiers: .command)
                .disabled(findMatches.isEmpty)
                .help("Tour précédent (Cmd+[ ou [)")
                .accessibilityLabel("Tour précédent")
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.mist)
                .keyboardShortcut("]", modifiers: .command)
                .disabled(findMatches.isEmpty)
                .help("Tour suivant (Cmd+] ou ])")
                .accessibilityLabel("Tour suivant")
            Button {
                findVisible = false
                findQuery = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.mist)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Fermer la recherche")
            bareBracketShortcuts
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Theme.panel)
    }

    /// Bare `[` / `]` navigation, armed only while the field is not focused so the
    /// two characters stay typable inside the query itself.
    @ViewBuilder
    private var bareBracketShortcuts: some View {
        if !findFocused && !findMatches.isEmpty {
            Group {
                Button("") { step(-1) }.keyboardShortcut("[", modifiers: [])
                Button("") { step(1) }.keyboardShortcut("]", modifiers: [])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func step(_ delta: Int) {
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex + delta + findMatches.count) % findMatches.count
        scrollTarget = findMatches[findIndex]
    }

    /// The query changed: rebuild the matches and jump to the first one.
    private func recomputeMatches() {
        findMatches = matchingIds()
        findIndex = 0
        scrollTarget = findMatches.first
    }

    /// A page landed: new matches may appear, but the reader is mid-navigation.
    /// The current match is re-found by id so the counter does not jump back to 1.
    private func refreshMatchesKeepingPosition() {
        let current = findMatches.indices.contains(findIndex) ? findMatches[findIndex] : nil
        findMatches = matchingIds()
        if let current, let index = findMatches.firstIndex(of: current) {
            findIndex = index
        } else {
            findIndex = min(findIndex, max(0, findMatches.count - 1))
        }
    }

    private func matchingIds() -> [String] {
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return renderableMessages
            .filter { message in
                message.blocks.contains {
                    $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
            .map(\.id)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if targetMissing { targetBanner }
                    ForEach(visibleMessages) { message in
                        SessionTurnView(
                            message: message,
                            results: results,
                            elapsed: elapsedById[message.id],
                            depth: 0,
                            highlighted: isMatch(message.id))
                            .id(message.id)
                            .onAppear {
                                guard message.id == prefetchTriggerId else { return }
                                Task { await loadNextPage() }
                            }
                    }
                    pagingFooter
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .top) }
            }
        }
    }

    private func isMatch(_ id: String) -> Bool {
        !findQuery.isEmpty && findMatches.contains(id)
    }

    /// The turn whose appearance asks for the next page. Set a little before the
    /// end so the reader never waits at the bottom; the footer button stays as the
    /// manual fallback when the whole page fits on screen at once.
    ///
    /// Taken from the unfiltered turns: the find filter can shrink the body to two
    /// rows, and paging must still track where the reader is in the transcript.
    private var prefetchTriggerId: String? {
        let shown = renderableMessages
        guard shown.count > 20 else { return shown.last?.id }
        return shown[shown.count - 20].id
    }

    /// Everything the renderer would show, before the find filter.
    private var renderableMessages: [SessionMessage] {
        messages.filter { message in
            if message.role == .system && !showSystemLines { return false }
            if message.isMeta && !showSystemLines { return false }
            return SessionTurnView.isRenderable(message)
        }
    }

    private var visibleMessages: [SessionMessage] {
        guard findVisible, !findQuery.isEmpty else { return renderableMessages }
        let matched = Set(findMatches)
        return renderableMessages.filter { matched.contains($0.id) }
    }

    private var targetBanner: some View {
        SourceBanner(
            kind: .info,
            message: isChasingTarget
                ? "Chargement du transcript jusqu'au message recherché…"
                : "Ce résultat est plus loin dans le transcript, au-delà des tours déjà chargés.",
            action: { Task { await chaseTarget() } },
            actionTitle: "Charger jusqu'au message")
    }

    @ViewBuilder
    private var pagingFooter: some View {
        VStack(spacing: 8) {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Chargement des tours…").font(.system(size: 11)).foregroundStyle(Theme.slate)
                }
            } else if !reachedEnd {
                Button("Charger la suite") { Task { await loadNextPage() } }
                    .controlSize(.small)
            }
            if total > 0 {
                // `sessionMessageCount` takes no `includeMeta`, so the total counts
                // transcript lines, not the turns actually rendered. Labelled as
                // lines rather than pretending the two denominators match.
                Text("\(FRFormat.integer(messages.count)) lignes chargées sur \(FRFormat.integer(total))")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.mist)
            } else if messages.isEmpty && !isLoading {
                Text("Aucun message indexé pour cette session.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .onAppear {
            // The footer entering the viewport is the signal to page ahead.
            Task { await loadNextPage() }
        }
    }

    // MARK: - Loading

    private func reload() async {
        messages = []
        results = [:]
        elapsedById = [:]
        reachedEnd = false
        targetMissing = false
        findMatches = []
        findIndex = 0
        total = await store.sessionMessageCount(session.id)
        await loadNextPage()
        health = await store.sessionHealth(session.id)
        resolveTarget()
    }

    private func loadNextPage() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        let page = await store.sessionMessages(session.id, offset: messages.count, limit: Self.pageSize)
        var previous = messages.last?.timestamp
        for message in page {
            if let previous {
                elapsedById[message.id] = message.timestamp.timeIntervalSince(previous)
            }
            previous = message.timestamp
            for block in message.blocks where block.kind == .toolResult {
                if let toolUseId = block.toolUseId { results[toolUseId] = block }
            }
        }
        messages.append(contentsOf: page)
        reachedEnd = page.count < Self.pageSize || (total > 0 && messages.count >= total)
        isLoading = false
        if !findQuery.isEmpty { refreshMatchesKeepingPosition() }
        resolveTarget()
    }

    /// Scrolls to the message the browser asked for, or says it is not loaded yet.
    ///
    /// The index gives no row offset for a message id, so the only honest options
    /// are "it is already loaded" or "page forward until it is". Paging from zero
    /// on every search hit of a 40 000-message session is not one of them, hence
    /// the explicit button.
    private func resolveTarget() {
        guard let target = targetMessageId else {
            targetMissing = false
            return
        }
        if messages.contains(where: { $0.id == target }) {
            targetMissing = false
            scrollTarget = target
            targetMessageId = nil
        } else {
            targetMissing = !reachedEnd
            if reachedEnd { targetMessageId = nil }
        }
    }

    private func chaseTarget() async {
        guard let target = targetMessageId, !isChasingTarget else { return }
        isChasingTarget = true
        while !reachedEnd && !messages.contains(where: { $0.id == target }) {
            await loadNextPage()
        }
        isChasingTarget = false
        resolveTarget()
    }
}
