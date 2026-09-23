// "Fichiers modifiés" tab of the Sessions section — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import AppKit
import SwiftUI
import CockpitShared
import SessionsKit
import UsageKit

/// Every file the assistant wrote to, across every session, grouped by project then
/// by path and ordered by the most recent edit. The feed is a plain index query: it
/// never reopens a transcript.
struct RecentEditsView: View {
    @Environment(CockpitStore.self) private var store
    @AppStorage(SettingsKey.sessionsIndexEnabled) private var indexEnabled = true
    @AppStorage("sessions.tab") private var sessionsTab = SessionsView.SessionsTab.browser.rawValue

    /// `nil` until the first query comes back — an empty array is a real answer.
    @State private var edits: [EditRecord]?
    @State private var projects: [ProjectCount] = []
    @State private var projectCwd: String?
    @State private var search = ""
    @State private var expanded: Set<String> = []

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
        // Keyed on the last index pass as well as on the project: a re-index adds edits
        // to the feed, and the tab must not keep showing the list it arrived with.
        .task(id: ReloadKey(project: projectCwd, indexedAt: store.sessionIndex.lastRun)) {
            edits = nil
            let fresh = await store.recentEdits(limit: 300, projectCwd: projectCwd)
            guard !Task.isCancelled else { return }
            edits = fresh
        }
    }

    private struct ReloadKey: Hashable {
        let project: String?
        let indexedAt: Date?
    }

    // MARK: Grouping

    /// One file, with every edit the archive knows about, newest first.
    private struct FileGroup: Identifiable {
        let id: String
        let path: String
        let edits: [EditRecord]

        var name: String { (path as NSString).lastPathComponent }
        var directory: String { UsagePath.shorten((path as NSString).deletingLastPathComponent) }
        var linesAdded: Int { edits.reduce(0) { $0 + $1.linesAdded } }
        var linesRemoved: Int { edits.reduce(0) { $0 + $1.linesRemoved } }
        var lastTimestamp: Date { edits.first?.timestamp ?? .distantPast }
    }

    private struct ProjectGroup: Identifiable {
        let id: String
        let cwd: String
        let files: [FileGroup]

        var lastTimestamp: Date { files.first?.lastTimestamp ?? .distantPast }
        var editCount: Int { files.reduce(0) { $0 + $1.edits.count } }
    }

    private var groups: [ProjectGroup] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = (edits ?? []).filter { needle.isEmpty || $0.path.lowercased().contains(needle) }
        return Dictionary(grouping: matching, by: \.projectCwd)
            .map { cwd, records in
                let files = Dictionary(grouping: records, by: \.path)
                    .map { path, list in
                        FileGroup(
                            id: cwd + "\u{1}" + path,
                            path: path,
                            edits: list.sorted { $0.timestamp > $1.timestamp })
                    }
                    .sorted { $0.lastTimestamp > $1.lastTimestamp }
                return ProjectGroup(id: cwd, cwd: cwd, files: files)
            }
            .sorted { $0.lastTimestamp > $1.lastTimestamp }
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Chemin")
                TextField("", text: $search, prompt: Text("Filtrer par chemin de fichier"))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 240, maxWidth: 360)
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
        .panelStyle()
    }

    // MARK: Body states

    @ViewBuilder
    private var content: some View {
        if !indexEnabled {
            ActivityPlaceholder(
                icon: "square.stack.3d.up.slash",
                title: "Indexation désactivée",
                message: "Activez « Indexer les transcripts » dans les réglages pour alimenter cette section.")
        } else if edits == nil {
            ActivityPlaceholder(
                icon: "hourglass",
                title: store.sessionIndex.isRunning ? "Indexation en cours" : "Lecture des modifications…",
                message: store.sessionIndex.isRunning
                    ? "\(FRFormat.integer(store.sessionIndex.filesDone)) transcripts sur \(FRFormat.integer(store.sessionIndex.filesTotal)) analysés."
                    : "Recherche des fichiers écrits par les sessions indexées.",
                isBusy: true)
        } else if groups.isEmpty {
            ActivityPlaceholder(
                icon: "doc.text.magnifyingglass",
                title: search.isEmpty ? "Aucun fichier modifié" : "Aucun fichier ne correspond",
                message: search.isEmpty
                    ? "Aucune session indexée n'a écrit de fichier pour ce projet."
                    : "Aucun chemin ne contient « \(search) ». Effacez le filtre pour tout revoir.")
        } else {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(groups) { project in
                    projectCard(project)
                }
            }
        }
    }

    private func projectCard(_ project: ProjectGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: UsagePath.shorten(project.cwd))
                Spacer()
                Text("\(FRFormat.plural(project.files.count, "fichier")) · \(FRFormat.plural(project.editCount, "modification"))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
                    .monospacedDigit()
            }
            VStack(spacing: 0) {
                ForEach(Array(project.files.enumerated()), id: \.element.id) { index, file in
                    if index > 0 { Divider().opacity(0.4) }
                    fileRow(file)
                }
            }
            .card()
        }
    }

    // MARK: File row

    private func fileRow(_ file: FileGroup) -> some View {
        let isExpanded = expanded.contains(file.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.mist)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(file.directory)
                        .font(.data(10))
                        .foregroundStyle(Theme.slate)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(file.path)
                }
                Spacer(minLength: 8)
                Text("\(FRFormat.integer(file.edits.count)) modif.")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.slate)
                lineDelta(added: file.linesAdded, removed: file.linesRemoved)
                Text(FRFormat.relative(file.lastTimestamp))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
                    .frame(width: 96, alignment: .trailing)
                    .help(FRFormat.dateTime(file.lastTimestamp))
                actions(file)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { toggle(file.id) }
            }
            if isExpanded {
                editList(file)
            }
        }
    }

    private func actions(_ file: FileGroup) -> some View {
        HStack(spacing: 4) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .disabled(!FileManager.default.fileExists(atPath: file.path))
            .help(FileManager.default.fileExists(atPath: file.path)
                ? "Révéler dans le Finder"
                : "Ce fichier n'existe plus sur le disque")

            Button {
                // TODO(team-lead): only switches tabs. Jumping to the exact message would
                // need the browser to expose a selection entry point taking
                // (sessionId, messageId) — the browser owns selection and is built by
                // another agent, so `EditRecord.sessionId` / `.messageId` stay unused here.
                sessionsTab = SessionsView.SessionsTab.browser.rawValue
            } label: {
                Image(systemName: "text.bubble")
            }
            .buttonStyle(.borderless)
            .help("Ouvrir la session")
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.slate)
    }

    private func editList(_ file: FileGroup) -> some View {
        VStack(spacing: 0) {
            ForEach(file.edits) { edit in
                HStack(spacing: 10) {
                    Text(edit.tool)
                        .font(.data(10))
                        .foregroundStyle(Theme.violet)
                        .frame(width: 92, alignment: .leading)
                    Text(FRFormat.dateTime(edit.timestamp))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.slate)
                    Spacer(minLength: 8)
                    lineDelta(added: edit.linesAdded, removed: edit.linesRemoved)
                    Text(FRFormat.relative(edit.timestamp))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.mist)
                        .frame(width: 96, alignment: .trailing)
                }
                .padding(.vertical, 5)
            }
        }
        .padding(.leading, 34)
        .padding(.trailing, 12)
        .padding(.bottom, 8)
    }

    private func lineDelta(added: Int, removed: Int) -> some View {
        HStack(spacing: 6) {
            Text("+\(FRFormat.integer(added))")
                .foregroundStyle(added > 0 ? Theme.emerald : Theme.mist)
            Text("−\(FRFormat.integer(removed))")
                .foregroundStyle(removed > 0 ? .red : Theme.mist)
        }
        .font(.system(size: 11, weight: .semibold))
        .monospacedDigit()
        .frame(width: 110, alignment: .trailing)
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}
