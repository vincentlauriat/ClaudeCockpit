// SessionsKit — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import Foundation
import CockpitShared

/// Reads Claude Code's transcripts into a rebuildable SQLite index, then answers every
/// question the Sessions section asks of it.
///
/// The index is a cache: `~/.claude` is never written to, and `index(full: true)` drops the
/// database and rebuilds it from the transcripts. Scanning is incremental — each file is
/// resumed from the byte offset reached last time, exactly like `UsageKit.TranscriptScanner`.
///
/// Indexing runs inside the actor, so the caller drives it from its own detached task and
/// follows it through the `progress` callback rather than by polling ``progress()``.
public actor SessionService {

    public let paths: ClaudePaths
    /// Where the index lives. `nil` at init → `appSupportDir/sessions.db`.
    public nonisolated let databaseURL: URL

    private var openStore: SessionStore?
    private var currentProgress: IndexProgress = .idle

    public init(paths: ClaudePaths = .live, databaseURL: URL? = nil) {
        self.paths = paths
        self.databaseURL = databaseURL ?? paths.appSupportDir.appendingPathComponent("sessions.db")
    }

    /// Opens the database, rebuilding it from scratch when it was written by an older schema.
    private func store() throws -> SessionStore {
        if let openStore { return openStore }
        if let stored = SessionStore.storedSchemaVersion(at: databaseURL),
           stored != SessionStore.schemaVersion {
            removeDatabaseFiles()
        }
        let store = try SessionStore(databaseURL: databaseURL)
        openStore = store
        return store
    }

    private func removeDatabaseFiles() {
        openStore = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
        }
    }

    // MARK: - Indexing

    /// Brings the index up to date and returns the final progress snapshot.
    ///
    /// - Parameters:
    ///   - full: drops the database first, forcing a complete rebuild. Stars, custom names and
    ///     hidden sessions are carried over — they live nowhere else.
    ///   - progress: called after each file, from the actor's executor.
    @discardableResult
    public func index(
        full: Bool = false,
        progress: (@Sendable (IndexProgress) -> Void)? = nil
    ) async throws -> IndexProgress {
        if full {
            let preserved = (try? store().userState()) ?? []
            removeDatabaseFiles()
            let fresh = try store()
            try fresh.restore(preserved)
        }
        let store = try store()
        let files = TranscriptWalker.files(in: paths.projectsDir)

        var snapshot = IndexProgress(
            filesTotal: files.count, filesDone: 0, bytesRead: 0, isRunning: true,
            lastRun: currentProgress.lastRun, dbSizeBytes: store.databaseSizeBytes)
        currentProgress = snapshot
        progress?(snapshot)

        let outcome = try store.index(files: files) { done, bytes in
            snapshot.filesDone = done
            snapshot.bytesRead = bytes
            progress?(snapshot)
        }

        snapshot.filesDone = outcome.filesDone
        snapshot.bytesRead = outcome.bytesRead
        snapshot.isRunning = false
        snapshot.lastRun = Date()
        snapshot.dbSizeBytes = store.databaseSizeBytes
        currentProgress = snapshot
        try? store.setMetaValue(String(snapshot.lastRun!.timeIntervalSince1970), for: "last_run")
        progress?(snapshot)
        return snapshot
    }

    /// The last known progress. Reading it while an index pass runs is not possible from
    /// outside — the pass holds the actor — so follow a running pass through `index`'s callback.
    public func progress() -> IndexProgress {
        var snapshot = currentProgress
        if let openStore {
            snapshot.dbSizeBytes = openStore.databaseSizeBytes
        }
        if snapshot.lastRun == nil,
           let raw = try? store().metaValue("last_run"), let seconds = Double(raw) {
            snapshot.lastRun = Date(timeIntervalSince1970: seconds)
            currentProgress = snapshot
        }
        return snapshot
    }

    // MARK: - Reading

    public func listSessions(_ filter: SessionFilter) throws -> [SessionRef] {
        try store().listSessions(filter)
    }

    public func session(id: String) throws -> SessionRef? {
        try store().session(id: id)
    }

    /// One page of a session's transcript, oldest first.
    ///
    /// - Parameter includeMeta: `false` (the default) returns the readable transcript —
    ///   `isMeta` lines and `system` bookkeeping such as `stop_hook_summary` or
    ///   `turn_duration` are left out, while the compaction marker is kept so the UI can draw
    ///   its divider. `true` is the "Afficher les lignes système" toggle and holds nothing back.
    public func messages(
        sessionId: String,
        includeMeta: Bool = false,
        offset: Int = 0,
        limit: Int = 400
    ) throws -> [SessionMessage] {
        try store().messages(
            sessionId: sessionId, includeMeta: includeMeta, offset: offset, limit: limit)
    }

    public func messageCount(sessionId: String) throws -> Int {
        try store().messageCount(sessionId: sessionId)
    }

    /// Every message of one sub-agent transcript, oldest first. A sub-agent is indexed as its
    /// own session keyed by `agentId`, so this is `messages(sessionId: agentId)` with the
    /// paging removed — sub-agent transcripts are short by construction.
    public func subagentMessages(agentId: String) throws -> [SessionMessage] {
        try store().messages(
            sessionId: agentId, includeMeta: false, offset: 0, limit: Self.subagentPageLimit)
    }

    /// Every sub-agent spawned by one session, by `agentId`.
    public func subagentIds(ofSession sessionId: String) throws -> [String] {
        try store().subagentIds(ofSession: sessionId)
    }

    /// FTS5 search over message text and tool bodies, newest hit first.
    public func search(_ query: String, filter: SessionFilter) throws -> [SearchHit] {
        try store().search(query, filter: filter)
    }

    /// Distinct working directories with a session count, most recently active first.
    public func projects() throws -> [ProjectCount] {
        try store().projects()
    }

    /// The most recent file edits across every session, newest first.
    public func recentEdits(limit: Int = 300, projectCwd: String? = nil) throws -> [EditRecord] {
        try store().recentEdits(limit: limit, projectCwd: projectCwd)
    }

    public func activity(
        since: Date,
        until: Date,
        projectCwd: String? = nil,
        calendar: Calendar = .current
    ) throws -> ActivityReport {
        try store().activity(
            since: since, until: until, projectCwd: projectCwd, calendar: calendar)
    }

    /// Grades one session. Block bodies are truncated on the way out of SQLite: the rules
    /// only need to tell two tool calls apart, never to read them, and a 35 MB transcript
    /// must not be pulled into memory to answer "how did it go".
    public func health(sessionId: String) throws -> SessionHealth {
        let store = try store()
        guard let session = try store.session(id: sessionId) else {
            throw SessionsError.unknownSession(sessionId)
        }
        let messages = try store.messages(
            sessionId: sessionId, includeMeta: true, offset: 0,
            limit: Self.healthPageLimit, bodyLimit: Self.healthBodyLimit)
        return SessionHealthRule.evaluate(messages: messages, session: session)
    }

    // MARK: - Mutating (index only — transcripts are never touched)

    public func setStarred(_ starred: Bool, sessionId: String) throws {
        try store().setStarred(starred, sessionId: sessionId)
    }

    /// `nil` clears the custom name and falls back to the ai-title / slug / first prompt.
    public func rename(sessionId: String, customName: String?) throws {
        try store().rename(sessionId: sessionId, customName: customName)
    }

    /// Soft delete: the row keeps a `deleted_at` and drops out of every listing.
    /// The transcript on disk is never modified.
    public func hide(sessionId: String) throws {
        try store().hide(sessionId: sessionId)
    }

    /// The `.jsonl` this session was indexed from, if it is still there.
    public func transcriptURL(sessionId: String) throws -> URL? {
        try store().transcriptURL(sessionId: sessionId)
    }

    /// How many sub-agent transcripts were paired with the `Agent` call that spawned them.
    /// Diagnostics for the corpus benchmark; the UI reads the link through
    /// ``ContentBlock/subagentId``.
    func linkedSubagentCount() throws -> Int {
        SessionStore.int(try store().scalar(
            "SELECT COUNT(*) FROM subagents WHERE parent_tool_use_id IS NOT NULL"))
    }

    // MARK: - Limits

    /// A sub-agent transcript is a single task; anything past this is a runaway.
    static let subagentPageLimit = 20_000
    /// Health looks at the whole session, so the cap is generous…
    static let healthPageLimit = 200_000
    /// …and the bodies are cut instead. Enough to tell two calls of the same tool apart.
    static let healthBodyLimit = 400
}

// MARK: - Export

/// Renders one session as a document. Pure and synchronous; the caller supplies the
/// messages it already paged in, plus the sub-agent transcripts to inline (keyed by agent id).
public enum SessionExporter {
    public static func markdown(
        session: SessionRef,
        messages: [SessionMessage],
        subagents: [String: [SessionMessage]] = [:]
    ) -> String {
        renderMarkdown(session: session, messages: messages, subagents: subagents)
    }

    /// Self-contained HTML: inline CSS, `<details>` for tool calls and thinking, everything escaped.
    public static func html(
        session: SessionRef,
        messages: [SessionMessage],
        subagents: [String: [SessionMessage]] = [:]
    ) -> String {
        renderHTML(session: session, messages: messages, subagents: subagents)
    }
}

// MARK: - Health rules

/// The scoring rules behind ``SessionHealth``. Pure, so they are tested directly.
public enum SessionHealthRule {
    public static func evaluate(messages: [SessionMessage], session: SessionRef) -> SessionHealth {
        evaluateRules(messages: messages, session: session)
    }
}
