// SessionsKit — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import Foundation
import SQLite

/// The SQLite index behind the Sessions section: schema, connection and the writes that are
/// not part of indexing (star, rename, hide).
///
/// Deliberately a reference type and deliberately **not** `Sendable`: it owns one connection
/// and a set of prepared statements, and lives inside ``SessionService``'s actor isolation.
///
/// Everything here is a cache. `~/.claude` is only ever read, and the whole database can be
/// thrown away and rebuilt from the transcripts.
final class SessionStore {

    let databaseURL: URL
    let db: Connection

    /// Bumped whenever the schema changes shape; a mismatch triggers a full rebuild.
    static let schemaVersion = 1

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            db = try Connection(databaseURL.path)
        } catch {
            throw SessionsError.sqlite(error.localizedDescription)
        }
        try configure()
        try createSchema()
    }

    private func configure() throws {
        try run("PRAGMA journal_mode = WAL")
        try run("PRAGMA synchronous = NORMAL")
        try run("PRAGMA temp_store = MEMORY")
        // 64 MB of page cache: the indexer touches four tables at once and the default 2 MB
        // turns every transaction into a read-back from disk.
        try run("PRAGMA cache_size = -65536")
        try run("PRAGMA foreign_keys = OFF")
    }

    // MARK: - Schema

    /// Tables are keyed so that the index is rebuildable at any time from the transcripts.
    ///
    /// `messages` uses a surrogate rowid with `UNIQUE(session_id, uuid)` rather than
    /// `uuid PRIMARY KEY`: a resumed or forked session can replay a uuid that already exists
    /// under another session, and a bare uuid key would silently attribute it to one of them.
    /// The surrogate rowid is also what the FTS index points at.
    private func createSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS files (
                path TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                is_subagent INTEGER NOT NULL DEFAULT 0,
                byte_offset INTEGER NOT NULL DEFAULT 0,
                mtime REAL NOT NULL DEFAULT 0,
                size INTEGER NOT NULL DEFAULT 0,
                inode INTEGER NOT NULL DEFAULT 0,
                next_seq INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                project_dir TEXT NOT NULL DEFAULT '',
                cwd TEXT NOT NULL DEFAULT '',
                slug TEXT,
                ai_title TEXT,
                custom_name TEXT,
                first_prompt TEXT,
                git_branch TEXT,
                cc_version TEXT,
                first_ts REAL,
                last_ts REAL,
                user_turns INTEGER NOT NULL DEFAULT 0,
                assistant_turns INTEGER NOT NULL DEFAULT 0,
                tool_calls INTEGER NOT NULL DEFAULT 0,
                tool_errors INTEGER NOT NULL DEFAULT 0,
                api_errors INTEGER NOT NULL DEFAULT 0,
                input_tokens INTEGER NOT NULL DEFAULT 0,
                output_tokens INTEGER NOT NULL DEFAULT 0,
                cache_read INTEGER NOT NULL DEFAULT 0,
                cache_create INTEGER NOT NULL DEFAULT 0,
                cost_state_usd REAL,
                lines_added INTEGER NOT NULL DEFAULT 0,
                lines_removed INTEGER NOT NULL DEFAULT 0,
                parent_session_id TEXT,
                starred INTEGER NOT NULL DEFAULT 0,
                deleted_at REAL
            );
            CREATE INDEX IF NOT EXISTS sessions_last_ts ON sessions(last_ts DESC);
            CREATE INDEX IF NOT EXISTS sessions_cwd ON sessions(cwd);

            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY,
                uuid TEXT NOT NULL,
                session_id TEXT NOT NULL,
                parent_uuid TEXT,
                seq INTEGER NOT NULL,
                ts REAL NOT NULL,
                role TEXT NOT NULL,
                is_sidechain INTEGER NOT NULL DEFAULT 0,
                is_meta INTEGER NOT NULL DEFAULT 0,
                is_compact_boundary INTEGER NOT NULL DEFAULT 0,
                is_api_error INTEGER NOT NULL DEFAULT 0,
                is_aborted INTEGER NOT NULL DEFAULT 0,
                system_subtype TEXT,
                model TEXT,
                api_message_id TEXT,
                is_duplicate INTEGER NOT NULL DEFAULT 0,
                input_tokens INTEGER NOT NULL DEFAULT 0,
                output_tokens INTEGER NOT NULL DEFAULT 0,
                cache_read INTEGER NOT NULL DEFAULT 0,
                cache_create INTEGER NOT NULL DEFAULT 0,
                attachment_count INTEGER NOT NULL DEFAULT 0
            );
            CREATE UNIQUE INDEX IF NOT EXISTS messages_session_uuid ON messages(session_id, uuid);
            CREATE INDEX IF NOT EXISTS messages_session_seq ON messages(session_id, seq);
            CREATE INDEX IF NOT EXISTS messages_ts ON messages(ts);
            CREATE INDEX IF NOT EXISTS messages_api_id ON messages(api_message_id);

            CREATE TABLE IF NOT EXISTS blocks (
                id INTEGER PRIMARY KEY,
                message_id INTEGER NOT NULL,
                idx INTEGER NOT NULL,
                kind TEXT NOT NULL,
                tool_name TEXT,
                tool_use_id TEXT,
                is_error INTEGER NOT NULL DEFAULT 0,
                body TEXT NOT NULL DEFAULT '',
                meta TEXT,
                subagent_id TEXT
            );
            CREATE INDEX IF NOT EXISTS blocks_message ON blocks(message_id);
            CREATE INDEX IF NOT EXISTS blocks_tool_use ON blocks(tool_use_id);
            CREATE INDEX IF NOT EXISTS blocks_tool_name ON blocks(tool_name);

            CREATE TABLE IF NOT EXISTS edits (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                message_uuid TEXT NOT NULL,
                ts REAL NOT NULL,
                tool TEXT NOT NULL,
                path TEXT NOT NULL,
                lines_added INTEGER NOT NULL DEFAULT 0,
                lines_removed INTEGER NOT NULL DEFAULT 0,
                project_cwd TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS edits_ts ON edits(ts DESC);
            CREATE INDEX IF NOT EXISTS edits_session ON edits(session_id);

            CREATE TABLE IF NOT EXISTS pr_links (
                session_id TEXT NOT NULL,
                number INTEGER NOT NULL,
                url TEXT NOT NULL,
                repo TEXT NOT NULL DEFAULT '',
                ts REAL NOT NULL DEFAULT 0,
                PRIMARY KEY (session_id, number)
            );

            CREATE TABLE IF NOT EXISTS subagents (
                agent_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                parent_tool_use_id TEXT,
                file_path TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS subagents_session ON subagents(session_id);
            """)

        // External-content FTS over `blocks`: the searchable text is block bodies, and
        // duplicating a gigabyte of transcript into the index is not an option. The price is
        // that deletes are manual — see `purge(sessionId:)`.
        try execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS blocks_fts USING fts5(
                body,
                content='blocks',
                content_rowid='id',
                tokenize="unicode61 remove_diacritics 2"
            );
            """)

        try run("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)",
                ["schema_version", String(Self.schemaVersion)])
    }

    /// The schema version already on disk, or `nil` for a database this code never wrote.
    static func storedSchemaVersion(at url: URL) -> Int? {
        guard FileManager.default.fileExists(atPath: url.path),
              let db = try? Connection(url.path),
              let raw = try? db.scalar(
                  "SELECT value FROM meta WHERE key = 'schema_version'") as? String
        else { return nil }
        return Int(raw)
    }

    // MARK: - Raw helpers

    func run(_ sql: String, _ bindings: [Binding?] = []) throws {
        do { try db.run(sql, bindings) } catch { throw SessionsError.sqlite(error.localizedDescription) }
    }

    func execute(_ sql: String) throws {
        do { try db.execute(sql) } catch { throw SessionsError.sqlite(error.localizedDescription) }
    }

    func prepare(_ sql: String) throws -> Statement {
        do { return try db.prepare(sql) } catch { throw SessionsError.sqlite(error.localizedDescription) }
    }

    private var cachedStatements: [String: Statement] = [:]

    /// A statement prepared once and re-bound on every call, keyed by the accessor's name.
    /// Compiling the indexer's inserts three million times would cost more than running them.
    func statement(_ key: String, _ sql: String) -> Statement {
        if let cached = cachedStatements[key] { return cached }
        // The SQL here is a compile-time constant, so a failure would be a programming error.
        guard let prepared = try? db.prepare(sql) else {
            preconditionFailure("SessionsKit: statement failed to compile — \(sql)")
        }
        cachedStatements[key] = prepared
        return prepared
    }

    func rows(_ sql: String, _ bindings: [Binding?] = []) throws -> [[Binding?]] {
        do {
            var result: [[Binding?]] = []
            for row in try db.prepare(sql, bindings) { result.append(row) }
            return result
        } catch {
            throw SessionsError.sqlite(error.localizedDescription)
        }
    }

    func scalar(_ sql: String, _ bindings: [Binding?] = []) throws -> Binding? {
        do { return try db.scalar(sql, bindings) }
        catch { throw SessionsError.sqlite(error.localizedDescription) }
    }

    func transaction(_ body: () throws -> Void) throws {
        do { try db.transaction { try body() } }
        catch let error as SessionsError { throw error }
        catch { throw SessionsError.sqlite(error.localizedDescription) }
    }

    var databaseSizeBytes: Int64 {
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
               let size = (attributes[.size] as? NSNumber)?.int64Value {
                total += size
            }
        }
        return total
    }

    // MARK: - Purging

    /// Drops everything indexed for one session, keeping the `sessions` row so a star, a
    /// custom name or a hide survives a re-read of its transcript.
    ///
    /// The FTS table is external-content, so its rows must be removed **before** the blocks
    /// they mirror: the `'delete'` command needs the original text to undo the tokenisation.
    /// Skipping this leaves phantom hits that match nothing, with no error anywhere.
    func purge(sessionId: String) throws {
        try run("""
            INSERT INTO blocks_fts(blocks_fts, rowid, body)
            SELECT 'delete', b.id, b.body
            FROM blocks b JOIN messages m ON b.message_id = m.id
            WHERE m.session_id = ?
            """, [sessionId])
        try run("""
            DELETE FROM blocks WHERE message_id IN (SELECT id FROM messages WHERE session_id = ?)
            """, [sessionId])
        try run("DELETE FROM messages WHERE session_id = ?", [sessionId])
        try run("DELETE FROM edits WHERE session_id = ?", [sessionId])
        try run("DELETE FROM pr_links WHERE session_id = ?", [sessionId])
        // The blocks just deleted carried the `subagent_id` that made an `Agent` card
        // openable. Clearing the pairing puts these sub-agents back in front of
        // `linkSubagents()`, which only ever looks at the ones still unpaired.
        try run("UPDATE subagents SET parent_tool_use_id = NULL WHERE session_id = ?", [sessionId])
        try run("""
            UPDATE sessions SET
                first_ts = NULL, last_ts = NULL, user_turns = 0, assistant_turns = 0,
                tool_calls = 0, tool_errors = 0, api_errors = 0,
                input_tokens = 0, output_tokens = 0, cache_read = 0, cache_create = 0,
                lines_added = 0, lines_removed = 0, first_prompt = NULL
            WHERE id = ?
            """, [sessionId])
    }

    // MARK: - User actions

    func setStarred(_ starred: Bool, sessionId: String) throws {
        try run("UPDATE sessions SET starred = ? WHERE id = ?", [starred ? 1 : 0, sessionId])
    }

    func rename(sessionId: String, customName: String?) throws {
        let trimmed = customName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: Binding? = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try run("UPDATE sessions SET custom_name = ? WHERE id = ?", [value, sessionId])
    }

    /// Soft delete. Transcripts on disk are never touched.
    func hide(sessionId: String) throws {
        try run("UPDATE sessions SET deleted_at = ? WHERE id = ?",
                [Date().timeIntervalSince1970, sessionId])
    }

    /// What ``hide(sessionId:)`` and ``rename(sessionId:customName:)`` must survive across a
    /// full rebuild, since that deletes the database file.
    struct UserState {
        let id: String
        let starred: Bool
        let customName: String?
        let deletedAt: Double?
    }

    func userState() throws -> [UserState] {
        try rows("""
            SELECT id, starred, custom_name, deleted_at FROM sessions
            WHERE starred = 1 OR custom_name IS NOT NULL OR deleted_at IS NOT NULL
            """).compactMap { row in
            guard let id = row[0] as? String else { return nil }
            return UserState(
                id: id,
                starred: (row[1] as? Int64 ?? 0) != 0,
                customName: row[2] as? String,
                deletedAt: row[3] as? Double)
        }
    }

    func restore(_ states: [UserState]) throws {
        for state in states {
            try run("""
                INSERT INTO sessions (id, starred, custom_name, deleted_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    starred = excluded.starred,
                    custom_name = excluded.custom_name,
                    deleted_at = excluded.deleted_at
                """, [state.id, state.starred ? 1 : 0, state.customName, state.deletedAt])
        }
    }

    // MARK: - Meta

    func metaValue(_ key: String) throws -> String? {
        try scalar("SELECT value FROM meta WHERE key = ?", [key]) as? String
    }

    func setMetaValue(_ value: String, for key: String) throws {
        try run("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", [key, value])
    }
}
