// SessionsKit — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import Foundation
import SQLite

/// The read side of the index: everything the Sessions list, detail, search, activity and
/// file feed ask for. All of it is plain SQL over the tables ``SessionStore`` builds.
extension SessionStore {

    // MARK: - Sessions

    private static let sessionColumns = """
        s.id, s.project_dir, s.cwd,
        COALESCE(NULLIF(s.custom_name, ''), NULLIF(s.ai_title, ''), NULLIF(s.slug, ''),
                 NULLIF(s.first_prompt, ''), substr(s.id, 1, 8)) AS title,
        s.custom_name, s.git_branch, s.cc_version, s.first_ts, s.last_ts,
        s.user_turns, s.assistant_turns, s.tool_calls, s.tool_errors,
        s.input_tokens, s.output_tokens, s.cache_read, s.cache_create,
        s.cost_state_usd, s.lines_added, s.lines_removed, s.parent_session_id, s.starred,
        s.api_errors, s.aborted_turns, s.repeated_failures, s.ended_on_error
        """

    func listSessions(_ filter: SessionFilter) throws -> [SessionRef] {
        var sql = "SELECT \(Self.sessionColumns) FROM sessions s WHERE s.deleted_at IS NULL"
        var bindings: [Binding?] = []
        appendFilters(filter, to: &sql, bindings: &bindings, prefix: "s.")

        let trimmed = filter.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let match = Self.ftsQuery(trimmed) {
            sql += """
                 AND s.id IN (SELECT m.session_id FROM blocks_fts
                              JOIN blocks b ON b.id = blocks_fts.rowid
                              JOIN messages m ON m.id = b.message_id
                              WHERE blocks_fts MATCH ?)
                """
            bindings.append(match)
        }

        sql += " ORDER BY s.last_ts DESC LIMIT ? OFFSET ?"
        bindings.append(max(0, filter.limit))
        bindings.append(max(0, filter.offset))

        let refs = try rows(sql, bindings).compactMap(Self.sessionRef(from:))
        return try attachPRLinks(to: refs)
    }

    func session(id: String) throws -> SessionRef? {
        // A hidden session is still returned by id: the caller asked for this one by name.
        guard let row = try rows(
            "SELECT \(Self.sessionColumns) FROM sessions s WHERE s.id = ?", [id]).first,
            let ref = Self.sessionRef(from: row)
        else { return nil }
        return try attachPRLinks(to: [ref]).first
    }

    /// Adds the filters shared by the list and the search. `prefix` is the alias of `sessions`.
    private func appendFilters(
        _ filter: SessionFilter, to sql: inout String, bindings: inout [Binding?], prefix: String
    ) {
        sql += " AND \(prefix)last_ts IS NOT NULL"
        if !filter.includeSubagents { sql += " AND \(prefix)parent_session_id IS NULL" }
        if let cwd = filter.projectCwd {
            sql += " AND \(prefix)cwd = ?"
            bindings.append(cwd)
        }
        if let since = filter.since {
            sql += " AND \(prefix)last_ts >= ?"
            bindings.append(since.timeIntervalSince1970)
        }
        if let until = filter.until {
            sql += " AND \(prefix)first_ts <= ?"
            bindings.append(until.timeIntervalSince1970)
        }
        if filter.starredOnly { sql += " AND \(prefix)starred = 1" }
        if filter.withErrorsOnly {
            sql += " AND (\(prefix)tool_errors > 0 OR \(prefix)api_errors > 0)"
        }
    }

    private static func sessionRef(from row: [Binding?]) -> SessionRef? {
        guard let id = row[0] as? String,
              let first = row[7] as? Double, let last = row[8] as? Double
        else { return nil }
        return SessionRef(
            id: id,
            projectDir: row[1] as? String ?? "",
            cwd: row[2] as? String ?? "",
            title: row[3] as? String ?? String(id.prefix(8)),
            customName: row[4] as? String,
            gitBranch: row[5] as? String,
            claudeVersion: row[6] as? String,
            firstTimestamp: Date(timeIntervalSince1970: first),
            lastTimestamp: Date(timeIntervalSince1970: last),
            userTurns: int(row[9]), assistantTurns: int(row[10]),
            toolCalls: int(row[11]), toolErrors: int(row[12]),
            inputTokens: int(row[13]), outputTokens: int(row[14]),
            cacheReadTokens: int(row[15]), cacheCreationTokens: int(row[16]),
            costStateUSD: row[17] as? Double,
            linesAdded: int(row[18]), linesRemoved: int(row[19]),
            parentSessionId: row[20] as? String,
            isStarred: int(row[21]) != 0,
            prLinks: [],
            healthGrade: SessionHealthRule.evaluate(counters(from: row)).grade)
    }

    /// The health counters as the indexer stored them, read straight off a `sessions` row.
    /// Both the list badge and the detail verdict come through here, so they cannot diverge.
    static func counters(from row: [Binding?]) -> SessionHealthCounters {
        SessionHealthCounters(
            toolCalls: int(row[11]),
            toolErrors: int(row[12]),
            apiErrors: int(row[22]),
            assistantTurns: int(row[10]),
            abortedTurns: int(row[23]),
            repeatedFailures: int(row[24]),
            endedOnError: int(row[25]) != 0)
    }

    /// The counters of one session, for the detailed verdict.
    func healthCounters(sessionId: String) throws -> SessionHealthCounters? {
        guard let row = try rows(
            "SELECT \(Self.sessionColumns) FROM sessions s WHERE s.id = ?", [sessionId]).first
        else { return nil }
        return Self.counters(from: row)
    }

    /// Two extra queries for the whole page rather than two per row.
    private func attachPRLinks(to refs: [SessionRef]) throws -> [SessionRef] {
        guard !refs.isEmpty else { return [] }
        var bySession: [String: [PRLink]] = [:]
        var tokens: [String: [String: ModelTokens]] = [:]
        for start in stride(from: 0, to: refs.count, by: Self.inClauseChunk) {
            let chunk = refs[start..<min(refs.count, start + Self.inClauseChunk)]
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            for row in try rows("""
                SELECT session_id, number, url, repo, ts FROM pr_links
                WHERE session_id IN (\(placeholders)) ORDER BY ts
                """, chunk.map { $0.id as Binding? }) {
                guard let sessionId = row[0] as? String,
                      let raw = row[2] as? String, let url = URL(string: raw)
                else { continue }
                bySession[sessionId, default: []].append(PRLink(
                    number: int(row[1]),
                    url: url,
                    repository: row[3] as? String ?? "",
                    timestamp: Date(timeIntervalSince1970: row[4] as? Double ?? 0)))
            }
        }
        for start in stride(from: 0, to: refs.count, by: Self.inClauseChunk) {
            let chunk = refs[start..<min(refs.count, start + Self.inClauseChunk)]
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            for row in try rows("""
                SELECT session_id, model, input_tokens, output_tokens, cache_read, cache_create
                FROM session_models WHERE session_id IN (\(placeholders))
                """, chunk.map { $0.id as Binding? }) {
                guard let sessionId = row[0] as? String, let model = row[1] as? String
                else { continue }
                tokens[sessionId, default: [:]][model] = ModelTokens(
                    inputTokens: int(row[2]), outputTokens: int(row[3]),
                    cacheReadTokens: int(row[4]), cacheCreationTokens: int(row[5]))
            }
        }

        guard !bySession.isEmpty || !tokens.isEmpty else { return refs }
        return refs.map { ref in
            let links = bySession[ref.id] ?? ref.prLinks
            let byModel = tokens[ref.id] ?? [:]
            guard !links.isEmpty || !byModel.isEmpty else { return ref }
            return SessionRef(
                id: ref.id, projectDir: ref.projectDir, cwd: ref.cwd, title: ref.title,
                customName: ref.customName, gitBranch: ref.gitBranch,
                claudeVersion: ref.claudeVersion,
                firstTimestamp: ref.firstTimestamp, lastTimestamp: ref.lastTimestamp,
                userTurns: ref.userTurns, assistantTurns: ref.assistantTurns,
                toolCalls: ref.toolCalls, toolErrors: ref.toolErrors,
                inputTokens: ref.inputTokens, outputTokens: ref.outputTokens,
                cacheReadTokens: ref.cacheReadTokens,
                cacheCreationTokens: ref.cacheCreationTokens,
                costStateUSD: ref.costStateUSD,
                linesAdded: ref.linesAdded, linesRemoved: ref.linesRemoved,
                parentSessionId: ref.parentSessionId, isStarred: ref.isStarred,
                prLinks: links, healthGrade: ref.healthGrade, tokensByModel: byModel)
        }
    }

    // MARK: - Messages

    func messages(
        sessionId: String, includeMeta: Bool, offset: Int, limit: Int, bodyLimit: Int? = nil
    ) throws -> [SessionMessage] {
        let sql = """
            SELECT id, uuid, parent_uuid, seq, ts, role, is_sidechain, is_meta,
                   is_compact_boundary, is_api_error, is_aborted, system_subtype, model,
                   input_tokens, output_tokens, cache_read, cache_create, attachment_count,
                   file_id, line_offset, line_len
            FROM messages WHERE session_id = ?\(Self.visibility(includeMeta))
            ORDER BY seq LIMIT ? OFFSET ?
            """

        let messageRows = try rows(sql, [sessionId, max(0, limit), max(0, offset)])
        guard !messageRows.isEmpty else { return [] }

        var order: [Int64] = []
        var drafts: [Int64: SessionMessage] = [:]
        var lines: [Int64: LineLocation] = [:]
        for row in messageRows {
            guard let rowid = row[0] as? Int64, let uuid = row[1] as? String,
                  let ts = row[4] as? Double, let role = (row[5] as? String).flatMap(MessageRole.init)
            else { continue }
            order.append(rowid)
            lines[rowid] = LineLocation(
                fileId: int(row[18]), offset: row[19] as? Int64 ?? 0, length: int(row[20]))
            drafts[rowid] = SessionMessage(
                id: uuid, sessionId: sessionId, parentId: row[2] as? String,
                sequence: int(row[3]), timestamp: Date(timeIntervalSince1970: ts), role: role,
                isSidechain: int(row[6]) != 0, isMeta: int(row[7]) != 0,
                isCompactBoundary: int(row[8]) != 0, isApiError: int(row[9]) != 0,
                isAborted: int(row[10]) != 0,
                model: row[12] as? String,
                inputTokens: int(row[13]), outputTokens: int(row[14]),
                cacheReadTokens: int(row[15]), cacheCreationTokens: int(row[16]),
                blocks: [], systemSubtype: row[11] as? String,
                attachmentCount: int(row[17]))
        }

        var blocksByMessage = try blocks(forMessages: order, drafts: drafts, bodyLimit: bodyLimit)
        // `bodyLimit` means the caller wants identities, not content (the health pass), so
        // there is nothing to restore.
        if bodyLimit == nil {
            try restoreTruncatedBodies(in: &blocksByMessage, lines: lines, drafts: drafts)
        }
        return order.compactMap { rowid in
            guard let draft = drafts[rowid] else { return nil }
            return draft.withBlocks(blocksByMessage[rowid] ?? [])
        }
    }

    /// Fills in what the 8 KB storage cap cut, by re-reading and re-parsing the transcript
    /// lines concerned.
    ///
    /// Only messages holding a truncated block are touched, so an ordinary page does no I/O
    /// at all: a block below the cap was stored whole. A transcript that has since been
    /// deleted simply leaves the truncated text in place rather than failing the page.
    private func restoreTruncatedBodies(
        in blocksByMessage: inout [Int64: [ContentBlock]],
        lines: [Int64: LineLocation],
        drafts: [Int64: SessionMessage]
    ) throws {
        let needing = blocksByMessage.filter { $0.value.contains(where: \.isTruncated) }
        guard !needing.isEmpty else { return }

        var handles: [Int: FileHandle] = [:]
        defer { for handle in handles.values { try? handle.close() } }
        let parser = TranscriptParser(bodyCap: ContentBlock.bodyCap)

        for (rowid, stored) in needing {
            guard let line = lines[rowid], line.length > 0 else { continue }
            if handles[line.fileId] == nil {
                guard let path = try scalar(
                    "SELECT path FROM files WHERE id = ?", [line.fileId]) as? String,
                    let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                else { continue }
                handles[line.fileId] = handle
            }
            guard let handle = handles[line.fileId] else { continue }
            try? handle.seek(toOffset: UInt64(line.offset))
            guard let data = try? handle.read(upToCount: line.length),
                  data.count == line.length,
                  let parsed = Self.reparse(data, with: parser),
                  parsed.uuid == drafts[rowid]?.id
            else { continue }
            // The uuid check is the point: an offset is only as good as the assumption that
            // transcripts are append-only. If one ever shifts, splicing a neighbouring
            // message's text into this one would be a silent, invisible corruption — far
            // worse than leaving the block truncated, which the reader can at least see.

            // The re-parsed blocks carry the full strings, so a `Write` or a long `Edit`
            // recovers its diff and not only its text.
            let fresh = Dictionary(
                parsed.blocks.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
            blocksByMessage[rowid] = stored.map { block in
                guard block.isTruncated, let replacement = fresh[block.index] else { return block }
                return block.withText(
                    replacement.body, fileEdit: replacement.fileEdit ?? block.fileEdit)
            }
        }
    }

    /// The message a line holds, whether it is an ordinary turn or a compaction marker.
    private static func reparse(_ data: Data, with parser: TranscriptParser) -> ParsedMessage? {
        switch parser.parse(data) {
        case .message(let message), .compactBoundary(let message): return message
        default: return nil
        }
    }

    /// - Parameter bodyLimit: truncates bodies in SQL. Used by the health pass, which needs
    ///   every block of a session but none of their content beyond identifying them.
    private func blocks(
        forMessages order: [Int64], drafts: [Int64: SessionMessage], bodyLimit: Int?
    ) throws -> [Int64: [ContentBlock]] {
        guard !order.isEmpty else { return [:] }
        let body = bodyLimit.map { "substr(body, 1, \($0))" } ?? "body"
        var result: [Int64: [ContentBlock]] = [:]

        // One bound parameter per message, so the `IN` list is chunked rather than sized by
        // the caller's page. `health` asks for a whole session at once, and SQLite caps a
        // statement at 32766 variables — comfortably above today's largest transcript
        // (~11 000 lines), which is exactly why this is a bound and not a bug fix.
        for chunk in stride(from: 0, to: order.count, by: Self.inClauseChunk).map({ start in
            order[start..<min(order.count, start + Self.inClauseChunk)]
        }) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            for row in try rows("""
                SELECT message_id, idx, kind, tool_name, tool_use_id, is_error, \(body),
                       meta, subagent_id
                FROM blocks WHERE message_id IN (\(placeholders)) ORDER BY message_id, idx
                """, chunk.map { $0 as Binding? }) {
                guard let messageRowid = row[0] as? Int64,
                      let kind = (row[2] as? String).flatMap(BlockKind.init),
                      let uuid = drafts[messageRowid]?.id
                else { continue }
                let index = int(row[1])
                let text = row[6] as? String ?? ""
                let meta = Self.decodeMeta(row[7] as? String)
                result[messageRowid, default: []].append(ContentBlock(
                    id: "\(uuid)#\(index)",
                    index: index,
                    kind: kind,
                    text: text,
                    toolName: row[3] as? String,
                    toolUseId: row[4] as? String,
                    isError: int(row[5]) != 0,
                    fileEdit: Self.fileEdit(meta: meta, body: text, kind: kind),
                    imageMediaType: kind == .image ? (meta["mediaType"] as? String ?? "image") : nil,
                    subagentId: row[8] as? String))
            }
        }
        return result
    }

    /// Well under SQLite's variable cap, and small enough that the chunking path is exercised
    /// by any session of a few hundred turns rather than only by a record-breaking one.
    static let inClauseChunk = 400

    func messageCount(sessionId: String, includeMeta: Bool) throws -> Int {
        int(try scalar("""
            SELECT COUNT(*) FROM messages WHERE session_id = ?\(Self.visibility(includeMeta))
            """, [sessionId]))
    }

    /// The 0-based rank of one message in the order ``messages(sessionId:includeMeta:offset:limit:)``
    /// returns, so a search hit can be turned into a page to open. Indexed count, not a read.
    func messageIndex(sessionId: String, messageId: String, includeMeta: Bool) throws -> Int? {
        let visibility = Self.visibility(includeMeta)
        guard let seq = try scalar("""
            SELECT seq FROM messages WHERE session_id = ? AND uuid = ?\(visibility)
            """, [sessionId, messageId]) as? Int64
        else { return nil }
        return int(try scalar("""
            SELECT COUNT(*) FROM messages WHERE session_id = ? AND seq < ?\(visibility)
            """, [sessionId, seq]))
    }

    /// What "Afficher les lignes système" is off means, in one place: the readable transcript.
    ///
    /// `is_meta` alone is not enough — every `system` line in the corpus carries
    /// `isMeta: false`, so `stop_hook_summary`, `turn_duration` and friends would still land
    /// in the transcript. The compaction marker is the one system line the reader wants,
    /// since it draws the divider.
    static func visibility(_ includeMeta: Bool) -> String {
        includeMeta ? "" : " AND is_meta = 0 AND (role <> 'system' OR is_compact_boundary = 1)"
    }

    private static func decodeMeta(_ raw: String?) -> [String: Any] {
        guard let raw, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// Rebuilds a ``FileEdit`` from the counters in `meta` plus the strings still sitting in
    /// the block body, which holds the tool input as JSON. Storing the strings twice would
    /// double the size of the index for no gain.
    private static func fileEdit(meta: [String: Any], body: String, kind: BlockKind) -> FileEdit? {
        guard kind == .toolUse, let edit = meta["edit"] as? [String: Any],
              let tool = edit["tool"] as? String, let path = edit["path"] as? String
        else { return nil }
        let input = (body.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        let firstHunk = (input["edits"] as? [[String: Any]])?.first
        return FileEdit(
            tool: tool,
            path: path,
            oldString: (input["old_string"] as? String)
                ?? (input["old_source"] as? String)
                ?? (firstHunk?["old_string"] as? String),
            newString: (input["new_string"] as? String)
                ?? (input["new_source"] as? String)
                ?? (firstHunk?["new_string"] as? String),
            content: input["content"] as? String,
            linesAdded: TranscriptParser.int(edit["linesAdded"]) ?? 0,
            linesRemoved: TranscriptParser.int(edit["linesRemoved"]) ?? 0)
    }

    // MARK: - Search

    func search(_ query: String, filter: SessionFilter) throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = Self.ftsQuery(trimmed) else { return [] }

        var sql = """
            SELECT m.session_id, m.uuid,
                   snippet(blocks_fts, 0, '«', '»', '…', 14) AS excerpt, m.ts
            FROM blocks_fts
            JOIN blocks b ON b.id = blocks_fts.rowid
            JOIN messages m ON m.id = b.message_id
            JOIN sessions s ON s.id = m.session_id
            WHERE blocks_fts MATCH ? AND s.deleted_at IS NULL
            """
        var bindings: [Binding?] = [match]
        appendFilters(filter, to: &sql, bindings: &bindings, prefix: "s.")
        // No `GROUP BY` here: FTS5 refuses its auxiliary functions — `snippet()` included —
        // in a grouped query. A message with several matching blocks therefore comes back
        // several times, and the first hit of each wins once the rows are back in Swift.
        sql += " ORDER BY m.ts DESC LIMIT ?"
        let offset = max(0, filter.offset)
        let limit = max(0, filter.limit)
        bindings.append((offset + limit) * Self.searchOverfetch + Self.searchOverfetch)

        var seen = Set<String>()
        var hits: [SearchHit] = []
        for row in try rows(sql, bindings) {
            guard let sessionId = row[0] as? String, let uuid = row[1] as? String,
                  let ts = row[3] as? Double, seen.insert(uuid).inserted
            else { continue }
            hits.append(SearchHit(
                sessionId: sessionId, messageId: uuid,
                snippet: row[2] as? String ?? "",
                timestamp: Date(timeIntervalSince1970: ts)))
        }
        guard offset < hits.count else { return [] }
        return Array(hits[offset..<min(hits.count, offset + limit)])
    }

    /// How many rows to pull per requested hit, to leave room for the duplicates that the
    /// missing `GROUP BY` lets through.
    private static let searchOverfetch = 4

    /// Turns what someone typed into a safe FTS5 expression.
    ///
    /// Every token is quoted, so `AND`, `OR`, `NEAR`, `*`, `:` and `-` are matched as text
    /// rather than reinterpreted as operators — a raw `MATCH` on user input throws on the
    /// first stray quote. A trailing `*` is kept as the prefix operator, which is the one
    /// piece of syntax worth exposing.
    static func ftsQuery(_ input: String) -> String? {
        let tokens = input
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "*" })
            .map(String.init)
            .filter { $0 != "*" }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { token -> String in
            let isPrefix = token.hasSuffix("*")
            let word = isPrefix ? String(token.dropLast()) : token
            let escaped = word.replacingOccurrences(of: "\"", with: "\"\"")
            return isPrefix ? "\"\(escaped)\"*" : "\"\(escaped)\""
        }.joined(separator: " AND ")
    }

    // MARK: - Projects and edits

    func projects() throws -> [ProjectCount] {
        try rows("""
            SELECT cwd, COUNT(*), MAX(last_ts) FROM sessions
            WHERE deleted_at IS NULL AND parent_session_id IS NULL
              AND cwd <> '' AND last_ts IS NOT NULL
            GROUP BY cwd ORDER BY MAX(last_ts) DESC
            """).compactMap { row in
            guard let cwd = row[0] as? String, let last = row[2] as? Double else { return nil }
            return ProjectCount(
                cwd: cwd, sessions: int(row[1]), lastTimestamp: Date(timeIntervalSince1970: last))
        }
    }

    func recentEdits(limit: Int, projectCwd: String?) throws -> [EditRecord] {
        var sql = """
            SELECT e.id, e.session_id, e.message_uuid, e.ts, e.tool, e.path,
                   e.lines_added, e.lines_removed, e.project_cwd
            FROM edits e JOIN sessions s ON s.id = e.session_id
            WHERE s.deleted_at IS NULL
            """
        var bindings: [Binding?] = []
        if let projectCwd {
            sql += " AND e.project_cwd = ?"
            bindings.append(projectCwd)
        }
        sql += " ORDER BY e.ts DESC LIMIT ?"
        bindings.append(max(0, limit))

        return try rows(sql, bindings).compactMap { row in
            guard let id = row[0] as? String, let sessionId = row[1] as? String,
                  let messageId = row[2] as? String, let ts = row[3] as? Double,
                  let tool = row[4] as? String, let path = row[5] as? String
            else { return nil }
            return EditRecord(
                id: id, sessionId: sessionId, messageId: messageId,
                timestamp: Date(timeIntervalSince1970: ts), tool: tool, path: path,
                linesAdded: int(row[6]), linesRemoved: int(row[7]),
                projectCwd: row[8] as? String ?? "")
        }
    }

    // MARK: - Activity

    /// Buckets are computed in Swift rather than in SQL because the weekday and the hour
    /// depend on the caller's `Calendar` and time zone, which SQLite knows nothing about.
    ///
    /// Two windows coexist on purpose. Turns, tools and models are counted on the timestamp
    /// of each message, so a session that began before the range still contributes the work
    /// it did inside it. `sessions` and `costUSD` are counted on the session's start, because
    /// the only cost Claude Code records is one total per session and it cannot be split
    /// across days. A long-running session therefore shows its turns without its cost.
    func activity(
        since: Date, until: Date, projectCwd: String?, calendar: Calendar
    ) throws -> ActivityReport {
        let lower = since.timeIntervalSince1970
        let upper = until.timeIntervalSince1970
        let scope = projectCwd == nil ? "" : " AND s.cwd = ?"
        var scoped: [Binding?] = [lower, upper]
        if let projectCwd { scoped.append(projectCwd) }

        var buckets: [ActivityBucket.Key: Int] = [:]
        var turnsPerDay: [String: Int] = [:]
        var sessionsPerDay: [String: Set<String>] = [:]
        var turns = 0
        for row in try rows("""
            SELECT m.ts, m.session_id FROM messages m JOIN sessions s ON s.id = m.session_id
            WHERE m.role = 'assistant' AND m.is_duplicate = 0 AND s.deleted_at IS NULL
              AND m.ts >= ? AND m.ts < ?\(scope)
            """, scoped) {
            guard let ts = row[0] as? Double, let sessionId = row[1] as? String else { continue }
            let date = Date(timeIntervalSince1970: ts)
            let parts = calendar.dateComponents([.weekday, .hour], from: date)
            buckets[.init(weekday: parts.weekday ?? 1, hour: parts.hour ?? 0), default: 0] += 1
            let day = Self.dayLabel(date, calendar: calendar)
            turnsPerDay[day, default: 0] += 1
            sessionsPerDay[day, default: []].insert(sessionId)
            turns += 1
        }

        // The only cost Claude Code records is the session-level `cost-state` total, so it is
        // charged to the day the session started rather than spread across its turns.
        var costPerDay: [String: Double] = [:]
        var sessionCount = 0
        var cost = 0.0
        for row in try rows("""
            SELECT s.first_ts, s.cost_state_usd FROM sessions s
            WHERE s.deleted_at IS NULL AND s.parent_session_id IS NULL
              AND s.first_ts IS NOT NULL AND s.first_ts >= ? AND s.first_ts < ?\(scope)
            """, scoped) {
            guard let first = row[0] as? Double else { continue }
            sessionCount += 1
            let amount = row[1] as? Double ?? 0
            cost += amount
            costPerDay[Self.dayLabel(Date(timeIntervalSince1970: first), calendar: calendar),
                       default: 0] += amount
        }

        var tools: [ToolMixRow] = []
        var toolCalls = 0
        for row in try rows("""
            SELECT b.tool_name,
                   COALESCE(SUM(b.kind = 'toolUse'), 0),
                   COALESCE(SUM(b.kind = 'toolResult' AND b.is_error = 1), 0)
            FROM blocks b
            JOIN messages m ON m.id = b.message_id
            JOIN sessions s ON s.id = m.session_id
            WHERE b.tool_name IS NOT NULL AND s.deleted_at IS NULL
              AND m.ts >= ? AND m.ts < ?\(scope)
            GROUP BY b.tool_name ORDER BY 2 DESC
            """, scoped) {
            guard let name = row[0] as? String else { continue }
            let calls = int(row[1])
            toolCalls += calls
            tools.append(ToolMixRow(id: name, calls: calls, errors: int(row[2])))
        }

        // Tokens as well as turns: `cost_state_usd` covers about one session in ten, so the
        // view prices these with the user's rates to show a figure for the rest.
        let models = try rows("""
            SELECT m.model, COUNT(*),
                   COALESCE(SUM(m.input_tokens), 0), COALESCE(SUM(m.output_tokens), 0),
                   COALESCE(SUM(m.cache_read), 0), COALESCE(SUM(m.cache_create), 0)
            FROM messages m JOIN sessions s ON s.id = m.session_id
            WHERE m.role = 'assistant' AND m.model IS NOT NULL AND m.is_duplicate = 0
              AND s.deleted_at IS NULL AND m.ts >= ? AND m.ts < ?\(scope)
            GROUP BY m.model ORDER BY 2 DESC
            """, scoped).compactMap { row -> ModelCount? in
            guard let model = row[0] as? String else { return nil }
            return ModelCount(model: model, turns: int(row[1]), tokens: ModelTokens(
                inputTokens: int(row[2]), outputTokens: int(row[3]),
                cacheReadTokens: int(row[4]), cacheCreationTokens: int(row[5])))
        }

        let days = Self.days(
            from: since, to: until, calendar: calendar,
            cost: costPerDay, turns: turnsPerDay, sessions: sessionsPerDay)

        return ActivityReport(
            buckets: buckets
                .map { ActivityBucket(weekday: $0.key.weekday, hour: $0.key.hour, assistantTurns: $0.value) }
                .sorted { ($0.weekday, $0.hour) < ($1.weekday, $1.hour) },
            days: days,
            tools: tools,
            models: models,
            sessions: sessionCount,
            turns: turns,
            toolCalls: toolCalls,
            costUSD: cost)
    }

    /// Every day of the range, including the empty ones, so a bar chart keeps a regular axis.
    private static func days(
        from: Date, to: Date, calendar: Calendar,
        cost: [String: Double], turns: [String: Int], sessions: [String: Set<String>]
    ) -> [DayCost] {
        var result: [DayCost] = []
        var cursor = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        while cursor <= end, result.count < 800 {
            let label = dayLabel(cursor, calendar: calendar)
            result.append(DayCost(
                id: label, day: cursor,
                costUSD: cost[label] ?? 0,
                sessions: sessions[label]?.count ?? 0,
                turns: turns[label] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    static func dayLabel(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Sub-agents and transcripts

    func subagentIds(ofSession sessionId: String) throws -> [String] {
        try rows("SELECT agent_id FROM subagents WHERE session_id = ? ORDER BY agent_id",
                 [sessionId]).compactMap { $0[0] as? String }
    }

    func transcriptURL(sessionId: String) throws -> URL? {
        guard let path = try scalar(
            "SELECT path FROM files WHERE session_id = ? LIMIT 1", [sessionId]) as? String,
            FileManager.default.fileExists(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Helpers

    func int(_ value: Binding?) -> Int { Self.int(value) }
}

extension ActivityBucket {
    /// Weekday and hour as one dictionary key while the buckets are being tallied.
    struct Key: Hashable {
        let weekday: Int
        let hour: Int
    }
}

extension ContentBlock {
    /// The same block with its body replaced by the full version read back from the transcript.
    func withText(_ text: String, fileEdit: FileEdit?) -> ContentBlock {
        ContentBlock(
            id: id, index: index, kind: kind, text: text, toolName: toolName,
            toolUseId: toolUseId, isError: isError, fileEdit: fileEdit,
            imageMediaType: imageMediaType, subagentId: subagentId)
    }
}

extension SessionMessage {
    /// The messages come back from one query and their blocks from another; this is where
    /// the two halves meet.
    func withBlocks(_ blocks: [ContentBlock]) -> SessionMessage {
        SessionMessage(
            id: id, sessionId: sessionId, parentId: parentId, sequence: sequence,
            timestamp: timestamp, role: role, isSidechain: isSidechain, isMeta: isMeta,
            isCompactBoundary: isCompactBoundary, isApiError: isApiError, isAborted: isAborted,
            model: model, inputTokens: inputTokens, outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens, cacheCreationTokens: cacheCreationTokens,
            blocks: blocks, systemSubtype: systemSubtype, attachmentCount: attachmentCount)
    }
}
