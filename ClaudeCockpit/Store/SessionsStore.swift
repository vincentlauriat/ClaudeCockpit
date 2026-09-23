// Sessions side of the store — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import AppKit
import Foundation
import CockpitShared
import SessionsKit

extension CockpitStore {

    // MARK: Indexing

    /// Brings the index up to date and refreshes the visible list.
    ///
    /// Incremental by default: only transcripts whose size or mtime moved are read.
    /// `full` drops the database and rebuilds it, which is the "Reconstruire l'index"
    /// button and the only way to recover from a corrupted file.
    /// How long a deleted transcript may linger before a complete walk removes it.
    static let fullWalkInterval: TimeInterval = 300

    /// `changedPaths` is what the watcher hands us: only those transcripts are
    /// re-read. An empty list walks the whole archive, which is also what the
    /// watcher sends when the kernel reports dropped events.
    ///
    /// A targeted pass prunes nothing, so a complete walk still runs at least
    /// every `fullWalkInterval`, otherwise a transcript deleted on disk would
    /// stay in the list until the next launch.
    func indexSessions(full: Bool = false, changedPaths: [String] = []) async {
        if sessions.isEmpty && !full { sessionsState = .loading }
        if full { sessionsState = .loading }
        let due = Date().timeIntervalSince(lastFullSessionWalk) >= Self.fullWalkInterval
        let targeted = !full && !changedPaths.isEmpty && !due
        do {
            let report: @Sendable (IndexProgress) -> Void = { [weak self] step in
                // The closure is called from the indexer's own context; the UI owns
                // `sessionIndex`, so hop to the main actor rather than mutating here.
                Task { @MainActor in self?.sessionIndex = step }
            }
            let progress: IndexProgress
            if targeted {
                progress = try await sessionService.index(changedPaths: changedPaths, progress: report)
            } else {
                progress = try await sessionService.index(full: full, progress: report)
                lastFullSessionWalk = Date()
            }
            sessionIndex = progress
            await refreshSessionList()
            sessionsState = .ready(progress.lastRun ?? Date())
        } catch {
            sessionsState = .failed(error.localizedDescription)
        }
    }

    /// Wipes and rebuilds the index. The transcripts are never touched.
    func rebuildSessionIndex() async {
        await indexSessions(full: true)
    }

    /// Re-runs the current filter. Cheap: it is one indexed query, not a scan.
    func refreshSessionList() async {
        let filter = sessionFilter
        let service = sessionService
        do {
            let rows = try await service.listSessions(filter)
            guard !Task.isCancelled else { return }
            sessions = rows
            // A page filled to the brim almost certainly has more behind it. Saying so is
            // the point: a silent cut makes the archive look smaller than it is.
            sessionsTruncated = rows.count >= filter.limit
        } catch {
            sessionsState = .failed(error.localizedDescription)
        }
    }

    // MARK: Reads used by the views

    func sessionMessages(_ sessionId: String, offset: Int = 0, limit: Int = 400) async -> [SessionMessage] {
        let showSystem = UserDefaults.standard.bool(forKey: SettingsKey.sessionsShowSystemLines)
        return (try? await sessionService.messages(
            sessionId: sessionId, includeMeta: showSystem, offset: offset, limit: limit)) ?? []
    }

    /// Counts exactly what `sessionMessages` returns.
    ///
    /// Reads the same setting on purpose: a total counted over a different set than the
    /// pages would make the detail view believe it had reached the end early and silently
    /// truncate the transcript.
    func sessionMessageCount(_ sessionId: String) async -> Int {
        let showSystem = UserDefaults.standard.bool(forKey: SettingsKey.sessionsShowSystemLines)
        return (try? await sessionService.messageCount(sessionId: sessionId, includeMeta: showSystem)) ?? 0
    }

    /// Where a message sits in the sequence `sessionMessages` pages through, or `nil` when
    /// the current filter excludes it. One indexed query, no transcript read.
    func sessionMessageIndex(_ sessionId: String, messageId: String) async -> Int? {
        let showSystem = UserDefaults.standard.bool(forKey: SettingsKey.sessionsShowSystemLines)
        return try? await sessionService.messageIndex(
            sessionId: sessionId, messageId: messageId, includeMeta: showSystem)
    }

    func subagentMessages(_ agentId: String) async -> [SessionMessage] {
        (try? await sessionService.subagentMessages(agentId: agentId)) ?? []
    }

    func sessionHealth(_ sessionId: String) async -> SessionHealth? {
        try? await sessionService.health(sessionId: sessionId)
    }

    func searchSessions(_ query: String) async -> [SearchHit] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return (try? await sessionService.search(query, filter: sessionFilter)) ?? []
    }

    /// Today's sessions, read with a filter of their own.
    ///
    /// The overview card must not reuse `sessionFilter`: that one belongs to the browser,
    /// the user changes it, and it is capped at 200 rows — today's sessions could silently
    /// fall off the page and the card would undercount without ever looking wrong.
    func todaySessions(now: Date = Date(), calendar: Calendar = .current) async -> [SessionRef] {
        var filter = SessionFilter()
        filter.since = calendar.startOfDay(for: now)
        filter.limit = 500
        return (try? await sessionService.listSessions(filter)) ?? []
    }

    func sessionProjects() async -> [ProjectCount] {
        (try? await sessionService.projects()) ?? []
    }

    func recentEdits(limit: Int = 300, projectCwd: String? = nil) async -> [EditRecord] {
        (try? await sessionService.recentEdits(limit: limit, projectCwd: projectCwd)) ?? []
    }

    func sessionActivity(since: Date, until: Date, projectCwd: String? = nil) async -> ActivityReport {
        (try? await sessionService.activity(since: since, until: until, projectCwd: projectCwd)) ?? .empty
    }

    /// Shows more sessions. The listing is one indexed query, so widening the page is cheap;
    /// it stays a deliberate step rather than an unbounded load of a very large archive.
    func loadMoreSessions() async {
        sessionFilter.limit += 200
    }

    // MARK: Mutations

    func setSessionStarred(_ starred: Bool, sessionId: String) async {
        do {
            try await sessionService.setStarred(starred, sessionId: sessionId)
            await refreshSessionList()
        } catch {
            notice = "Impossible de modifier le favori : \(error.localizedDescription)"
        }
    }

    func renameSession(_ sessionId: String, to name: String?) async {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await sessionService.rename(sessionId: sessionId, customName: (trimmed?.isEmpty ?? true) ? nil : trimmed)
            await refreshSessionList()
        } catch {
            notice = "Renommage impossible : \(error.localizedDescription)"
        }
    }

    /// Hides a session from the list. This is a flag in the index: the transcript on
    /// disk is never modified, and "Reconstruire l'index" brings it back.
    func hideSession(_ sessionId: String) async {
        do {
            try await sessionService.hide(sessionId: sessionId)
            await refreshSessionList()
            notice = "Session masquée. Elle réapparaîtra après une reconstruction de l'index."
        } catch {
            notice = "Impossible de masquer la session : \(error.localizedDescription)"
        }
    }

    // MARK: Actions

    /// True when `claude --resume` can be offered: the working directory the session
    /// ran in must still exist, or the command would open a shell nowhere useful.
    func canResume(_ session: SessionRef) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: session.cwd, isDirectory: &isDir) && isDir.boolValue
    }

    /// Opens Terminal on `claude --resume <id>` in the session's own directory.
    ///
    /// Goes through a temporary `.command` script rather than an AppleScript: no
    /// automation permission prompt, and the quoting stays under our control. The
    /// flag was checked against the installed binary before being wired here.
    func resumeSession(_ session: SessionRef) {
        guard canResume(session) else {
            notice = "Le dossier de cette session n'existe plus : \(session.cwd)"
            return
        }
        let script = """
        #!/bin/zsh
        cd \(shellQuoted(session.cwd)) || exit 1
        exec claude --resume \(shellQuoted(session.id))
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reprendre-session-\(session.id.prefix(8)).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            notice = "Impossible de lancer la reprise : \(error.localizedDescription)"
        }
    }

    /// Single-quote for `zsh`, closing and reopening around any embedded quote.
    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func revealTranscript(_ session: SessionRef) async {
        guard let url = try? await sessionService.transcriptURL(sessionId: session.id) else {
            notice = "Transcript introuvable pour cette session."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    enum SessionExportFormat { case markdown, html }

    /// Exports one session to a file the user picks. Sub-agent transcripts referenced
    /// by the session are pulled in so the export is self-contained.
    func exportSession(_ session: SessionRef, format: SessionExportFormat) async {
        let messages = await sessionMessages(session.id, offset: 0, limit: 100_000)
        var subagents: [String: [SessionMessage]] = [:]
        for id in Set(messages.flatMap { $0.blocks.compactMap(\.subagentId) }) {
            subagents[id] = await subagentMessages(id)
        }
        let text: String
        let ext: String
        switch format {
        case .markdown:
            text = SessionExporter.markdown(session: session, messages: messages, subagents: subagents)
            ext = "md"
        case .html:
            text = SessionExporter.html(session: session, messages: messages, subagents: subagents)
            ext = "html"
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(safeFileName(session.title)).\(ext)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            notice = "Session exportée : \(url.lastPathComponent)"
        } catch {
            notice = "Export impossible : \(error.localizedDescription)"
        }
    }

    private func safeFileName(_ raw: String) -> String {
        let cleaned = raw.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "session" : String(trimmed.prefix(80))
    }
}
