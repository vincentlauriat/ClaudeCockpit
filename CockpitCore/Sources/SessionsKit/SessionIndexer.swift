// SessionsKit — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import Foundation
import SQLite

/// One `.jsonl` found under `~/.claude/projects`, with the identity the index gives it.
struct TranscriptFile: Sendable, Hashable {
    let url: URL
    /// The `sessionId` for a session file, the `agentId` for a sub-agent one.
    let sessionId: String
    /// Only set for a sub-agent transcript.
    let parentSessionId: String?
    /// The encoded directory name, e.g. `-Users-vincentlauriat-DevApps-Foo`.
    let projectDir: String
    var isSubagent: Bool { parentSessionId != nil }
}

/// Finds the transcripts and works out what each one is from its place in the tree.
///
/// Two shapes exist, both verified on the real corpus:
/// - `<projectDir>/<sessionId>.jsonl` — a session;
/// - `<projectDir>/<sessionId>/subagents/agent-<agentId>.jsonl` — a sub-agent of it.
///
/// Sub-agent lines carry the *parent* `sessionId`, so the id has to come from the path:
/// indexing them under the id they claim would merge them into their parent.
enum TranscriptWalker {

    static func files(in projectsDir: URL) -> [TranscriptFile] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let root = projectsDir.standardizedFileURL.pathComponents
        var found: [TranscriptFile] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let components = Array(url.standardizedFileURL.pathComponents.dropFirst(root.count))
            guard let file = describe(url: url, components: components) else { continue }
            found.append(file)
        }
        // Sorted so that a `message.id` seen in two transcripts always dedupes the same way.
        return found.sorted { $0.url.path < $1.url.path }
    }

    static func describe(url: URL, components: [String]) -> TranscriptFile? {
        let name = url.deletingPathExtension().lastPathComponent
        switch components.count {
        case 2:
            return TranscriptFile(
                url: url, sessionId: name, parentSessionId: nil, projectDir: components[0])
        case 4 where components[2] == "subagents" && name.hasPrefix("agent-"):
            return TranscriptFile(
                url: url,
                sessionId: String(name.dropFirst("agent-".count)),
                parentSessionId: components[1],
                projectDir: components[0])
        default:
            return nil
        }
    }

    /// `aimpl-t1-2-01b9429ddddff833` → `impl-t1-2`: the name the parent's `Agent` call used.
    ///
    /// Claude Code builds an agent id as `a` + the call's `name` + `-` + a hex suffix, so the
    /// name is what is left once both are stripped. Returns `nil` when the id has no suffix
    /// to strip, in which case only an exact match is meaningful.
    static func agentName(fromAgentId agentId: String) -> String? {
        guard agentId.hasPrefix("a") else { return nil }
        let body = agentId.dropFirst()
        guard let dash = body.lastIndex(of: "-") else { return nil }
        let suffix = body[body.index(after: dash)...]
        guard suffix.count >= 8, suffix.allSatisfy({ $0.isHexDigit }) else { return nil }
        let name = body[..<dash]
        return name.isEmpty ? nil : String(name)
    }
}

// MARK: - Indexing

extension SessionStore {

    /// What one indexing pass did.
    struct IndexOutcome {
        var filesDone = 0
        var bytesRead: Int64 = 0
    }

    /// Brings every transcript up to date, then links sub-agents to the calls that spawned them.
    ///
    /// Each file is resumed from the byte offset reached last time; a file whose mtime **and**
    /// size are unchanged is not even opened. A partially written trailing line is left for the
    /// next pass, exactly like `UsageKit.TranscriptScanner`.
    func index(
        files: [TranscriptFile],
        onFile: (Int, Int64) -> Void = { _, _ in }
    ) throws -> IndexOutcome {
        var outcome = IndexOutcome()
        for file in files {
            outcome.bytesRead += try indexOne(file)
            outcome.filesDone += 1
            onFile(outcome.filesDone, outcome.bytesRead)
        }
        try forgetDisappearedFiles(keeping: files)
        try linkSubagents()
        return outcome
    }

    /// - Returns: bytes actually read from disk.
    private func indexOne(_ file: TranscriptFile) throws -> Int64 {
        let path = file.url.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970,
              let size = (attributes[.size] as? NSNumber)?.int64Value
        else { return 0 }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.int64Value ?? 0

        var startOffset: Int64 = 0
        var nextSequence = 0
        var isKnown = false
        if let row = try rows("""
            SELECT byte_offset, mtime, size, next_seq, inode FROM files WHERE path = ?
            """, [path]).first {
            isKnown = true
            let knownOffset = row[0] as? Int64 ?? 0
            let knownMtime = row[1] as? Double ?? 0
            let knownSize = row[2] as? Int64 ?? 0
            let knownInode = row[4] as? Int64 ?? 0
            if knownMtime == mtime && knownSize == size && knownInode == inode { return 0 }
            // A transcript is append-only, so resuming from the last offset is safe — unless
            // the file shrank, or a new one took its place at the same path (which is what an
            // atomic rewrite does, and which mtime and size alone cannot tell from an append).
            // Either way the only honest answer is to read it again from byte zero.
            if size >= knownOffset && inode == knownInode {
                startOffset = knownOffset
                nextSequence = Int(row[3] as? Int64 ?? 0)
            }
        }

        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return 0 }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(startOffset))
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else {
            try rememberFile(file, offset: startOffset, mtime: mtime, size: size,
                             inode: inode, nextSeq: nextSequence)
            return 0
        }
        guard let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) else {
            // Caught mid-write: no complete line yet. Retry from the same offset next pass.
            try rememberFile(file, offset: startOffset, mtime: mtime, size: size,
                             inode: inode, nextSeq: nextSequence)
            return 0
        }
        let complete = chunk[chunk.startIndex...lastNewline]
        let newOffset = startOffset + Int64(complete.count)

        try transaction {
            if startOffset == 0 && isKnown { try purge(sessionId: file.sessionId) }
            try ensureSession(file)
            try rememberFile(file, offset: startOffset, mtime: mtime, size: size,
                             inode: inode, nextSeq: nextSequence)
            let fileId = Self.int(try scalar("SELECT id FROM files WHERE path = ?", [path]))
            let sequence = try ingest(
                complete, file: file, fileId: fileId,
                fileOffset: startOffset, firstSequence: nextSequence)
            try rememberFile(file, offset: newOffset, mtime: mtime, size: size,
                             inode: inode, nextSeq: sequence)
            try recomputeAggregates(sessionId: file.sessionId)
        }
        return Int64(complete.count)
    }

    // MARK: - One chunk of lines

    /// Accumulates what only becomes known once the whole chunk has been read.
    private struct SessionFacts {
        var failures = SessionHealthRule.FailureRun()
        var cwd: String?
        var gitBranch: String?
        var version: String?
        var slug: String?
        var aiTitle: String?
        var costUSD: Double?
        var costLinesAdded: Int?
        var costLinesRemoved: Int?
    }

    /// - Parameters:
    ///   - fileId: row id of the transcript in `files`, stamped on every message so its line
    ///     can be found again.
    ///   - fileOffset: where `data` starts in that file, so line offsets come out absolute.
    /// - Returns: the sequence number the next chunk should start from.
    private func ingest(
        _ data: Data, file: TranscriptFile, fileId: Int, fileOffset: Int64, firstSequence: Int
    ) throws -> Int {
        let parser = TranscriptParser()
        var sequence = firstSequence
        var facts = SessionFacts()
        facts.failures = try loadFailureRun(sessionId: file.sessionId)
        // `tool_result` blocks name only the call they answer, never the tool. Carrying the
        // name across from the `tool_use` that precedes them turns the tool mix and the error
        // rate into plain `GROUP BY tool_name` queries.
        var toolNames: [String: String] = [:]
        /// `toolUseId` → hash of the call's name and input, for the repeated-failure counter.
        var identities: [String: Int64] = [:]

        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            let lineStart = start
            defer { start = end < data.endIndex ? data.index(after: end) : data.endIndex }
            guard end > lineStart else { continue }
            let line = Data(data[lineStart..<end])
            let location = LineLocation(
                fileId: fileId,
                offset: fileOffset + Int64(lineStart - data.startIndex),
                length: line.count)

            switch parser.parse(line) {
            case .message(let message), .compactBoundary(let message):
                try store(message, file: file, sequence: sequence, at: location,
                          facts: &facts, toolNames: &toolNames, identities: &identities)
                sequence += 1

            case .aiTitle(_, let title):
                facts.aiTitle = title

            case .prLink(_, let link):
                try run("""
                    INSERT OR REPLACE INTO pr_links(session_id, number, url, repo, ts)
                    VALUES (?, ?, ?, ?, ?)
                    """, [file.sessionId, link.number, link.url.absoluteString,
                          link.repository, link.timestamp.timeIntervalSince1970])

            case .costState(_, let cost, let added, let removed):
                facts.costUSD = cost
                facts.costLinesAdded = added
                facts.costLinesRemoved = removed

            case .attachment(let parentUuid):
                guard let parentUuid else { continue }
                try run("""
                    UPDATE messages SET attachment_count = attachment_count + 1
                    WHERE session_id = ? AND uuid = ?
                    """, [file.sessionId, parentUuid])

            case .ignored:
                continue
            }
        }

        try apply(facts, to: file.sessionId)
        return sequence
    }

    /// Where one JSONL line sits on disk.
    struct LineLocation {
        let fileId: Int
        let offset: Int64
        let length: Int
    }

    private func store(
        _ message: ParsedMessage, file: TranscriptFile, sequence: Int, at location: LineLocation,
        facts: inout SessionFacts, toolNames: inout [String: String],
        identities: inout [String: Int64]
    ) throws {
        if let cwd = message.cwd { facts.cwd = cwd }
        if let branch = message.gitBranch { facts.gitBranch = branch }
        if let version = message.version { facts.version = version }
        if let slug = message.slug { facts.slug = slug }

        // Assistant turns are deduped on `message.id`, the same rule UsageKit uses: one API
        // response can be written into more than one transcript, and its tokens must be
        // counted once. The row is still stored so the transcript reads in full.
        var isDuplicate = false
        if let apiMessageId = message.apiMessageId, message.role == .assistant {
            isDuplicate = try scalar(
                "SELECT 1 FROM messages WHERE api_message_id = ? LIMIT 1", [apiMessageId]) != nil
        }

        try insertMessage.run([
            message.uuid, file.sessionId, message.parentUuid, sequence,
            message.timestamp.timeIntervalSince1970, message.role.rawValue,
            message.isSidechain ? 1 : 0, message.isMeta ? 1 : 0,
            message.isCompactBoundary ? 1 : 0, message.isApiError ? 1 : 0,
            message.isAborted ? 1 : 0,
            message.systemSubtype, message.model, message.apiMessageId, isDuplicate ? 1 : 0,
            message.inputTokens, message.outputTokens,
            message.cacheReadTokens, message.cacheCreationTokens,
            location.fileId, location.offset, location.length,
        ])
        guard db.changes > 0 else { return }  // uuid already stored for this session
        let messageId = db.lastInsertRowid

        for block in message.blocks {
            let meta = Self.meta(for: block, reference: message.agentReferences[block.toolUseId ?? ""])
            var toolName = block.toolName
            if let toolUseId = block.toolUseId {
                switch block.kind {
                case .toolUse:
                    if let name = block.toolName { toolNames[toolUseId] = name }
                    identities[toolUseId] = SessionHealthRule.identityHash(
                        toolName: block.toolName, input: block.body)
                case .toolResult:
                    // The map covers the common case; the query is the fallback for a result
                    // whose call landed in an earlier chunk of the same transcript.
                    if let known = toolNames[toolUseId] {
                        toolName = known
                    } else {
                        toolName = try scalar("""
                            SELECT tool_name FROM blocks
                            WHERE tool_use_id = ? AND kind = 'toolUse' LIMIT 1
                            """, [toolUseId]) as? String
                    }
                    // A result whose call landed in an earlier chunk has no identity in
                    // memory; the run simply restarts rather than pairing on a guess.
                    facts.failures.record(failed: block.isError, identity: identities[toolUseId])
                default:
                    break
                }
            }
            try insertBlock.run([
                messageId, block.index, block.kind.rawValue, toolName, block.toolUseId,
                block.isError ? 1 : 0, block.body, meta, nil,
            ])
            if block.kind != .image && !block.body.isEmpty {
                try insertFTS.run([db.lastInsertRowid, block.body])
            }
            if let edit = block.fileEdit {
                try insertEdit.run([
                    "\(message.uuid)#\(block.index)", file.sessionId, message.uuid,
                    message.timestamp.timeIntervalSince1970, edit.tool, edit.path,
                    edit.linesAdded, edit.linesRemoved, message.cwd ?? facts.cwd ?? "",
                ])
            }
        }
    }

    /// The small JSON kept beside a block: what the readers need without re-parsing `body`.
    private static func meta(for block: ParsedBlock, reference: String?) -> String? {
        var fields: [String: Any] = [:]
        if let edit = block.fileEdit {
            fields["edit"] = [
                "tool": edit.tool, "path": edit.path,
                "linesAdded": edit.linesAdded, "linesRemoved": edit.linesRemoved,
            ]
        }
        if let agentName = block.agentName { fields["agentName"] = agentName }
        if let reference, block.kind == .toolResult { fields["agentRef"] = reference }
        if let media = block.imageMediaType { fields["mediaType"] = media }
        guard !fields.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The run of identical failures still in progress, as the previous chunk left it.
    private func loadFailureRun(sessionId: String) throws -> SessionHealthRule.FailureRun {
        guard let row = try rows("""
            SELECT repeated_failures, failure_run, failure_key FROM sessions WHERE id = ?
            """, [sessionId]).first
        else { return SessionHealthRule.FailureRun() }
        return SessionHealthRule.FailureRun(
            longest: Self.int(row[0]), current: Self.int(row[1]), key: row[2] as? Int64)
    }

    private func apply(_ facts: SessionFacts, to sessionId: String) throws {
        // COALESCE keeps whatever a previous chunk already established when this one is silent.
        try run("""
            UPDATE sessions SET
                cwd = COALESCE(?, NULLIF(cwd, '')  , ''),
                git_branch = COALESCE(?, git_branch),
                cc_version = COALESCE(?, cc_version),
                slug = COALESCE(?, slug),
                ai_title = COALESCE(?, ai_title),
                cost_state_usd = COALESCE(?, cost_state_usd),
                repeated_failures = ?, failure_run = ?, failure_key = ?
            WHERE id = ?
            """, [facts.cwd, facts.gitBranch, facts.version, facts.slug,
                  facts.aiTitle, facts.costUSD,
                  facts.failures.longest, facts.failures.current, facts.failures.key,
                  sessionId])
    }

    private func ensureSession(_ file: TranscriptFile) throws {
        try run("""
            INSERT INTO sessions (id, project_dir, parent_session_id) VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                project_dir = excluded.project_dir,
                parent_session_id = excluded.parent_session_id
            """, [file.sessionId, file.projectDir, file.parentSessionId])
        if file.isSubagent {
            try run("""
                INSERT INTO subagents (agent_id, session_id, file_path) VALUES (?, ?, ?)
                ON CONFLICT(agent_id) DO UPDATE SET
                    session_id = excluded.session_id, file_path = excluded.file_path
                """, [file.sessionId, file.parentSessionId ?? "", file.url.path])
        }
    }

    private func rememberFile(
        _ file: TranscriptFile, offset: Int64, mtime: Double, size: Int64,
        inode: Int64, nextSeq: Int
    ) throws {
        try run("""
            INSERT INTO files
                (path, session_id, is_subagent, byte_offset, mtime, size, inode, next_seq)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                session_id = excluded.session_id, is_subagent = excluded.is_subagent,
                byte_offset = excluded.byte_offset, mtime = excluded.mtime,
                size = excluded.size, inode = excluded.inode, next_seq = excluded.next_seq
            """, [file.url.path, file.sessionId, file.isSubagent ? 1 : 0,
                  offset, mtime, size, inode, nextSeq])
    }

    // MARK: - Aggregates

    /// Recomputes one session's counters from its rows rather than adding deltas as lines
    /// arrive. One session lives in exactly one file, so this runs once per changed file, and
    /// a recount can never drift the way an accumulated delta can.
    func recomputeAggregates(sessionId: String) throws {
        var userTurns = 0, assistantTurns = 0, apiErrors = 0
        var input = 0, output = 0, cacheRead = 0, cacheCreate = 0
        for row in try rows("""
            SELECT role, COUNT(*),
                   COALESCE(SUM(CASE WHEN is_duplicate = 0 THEN input_tokens ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN is_duplicate = 0 THEN output_tokens ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN is_duplicate = 0 THEN cache_read ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN is_duplicate = 0 THEN cache_create ELSE 0 END), 0),
                   COALESCE(SUM(is_api_error), 0)
            FROM messages WHERE session_id = ? GROUP BY role
            """, [sessionId]) {
            let count = Self.int(row[1])
            switch row[0] as? String {
            case MessageRole.user.rawValue: userTurns = count
            case MessageRole.assistant.rawValue: assistantTurns = count
            default: break
            }
            input += Self.int(row[2]); output += Self.int(row[3])
            cacheRead += Self.int(row[4]); cacheCreate += Self.int(row[5])
            apiErrors += Self.int(row[6])
        }

        let span = try rows("SELECT MIN(ts), MAX(ts) FROM messages WHERE session_id = ?", [sessionId]).first
        let toolCounts = try rows("""
            SELECT COALESCE(SUM(b.kind = 'toolUse'), 0),
                   COALESCE(SUM(b.kind = 'toolResult' AND b.is_error = 1), 0)
            FROM blocks b JOIN messages m ON b.message_id = m.id
            WHERE m.session_id = ?
            """, [sessionId]).first
        let editTotals = try rows("""
            SELECT COALESCE(SUM(lines_added), 0), COALESCE(SUM(lines_removed), 0)
            FROM edits WHERE session_id = ?
            """, [sessionId]).first
        let abortedTurns = Self.int(try scalar(
            "SELECT COUNT(*) FROM messages WHERE session_id = ? AND is_aborted = 1", [sessionId]))
        // "Ended on an error" is about the closing assistant turn, which is the one the
        // reader was left looking at.
        let endedOnError = Self.int(try scalar("""
            SELECT is_api_error FROM messages
            WHERE session_id = ? AND role = 'assistant' ORDER BY seq DESC LIMIT 1
            """, [sessionId])) != 0

        // Tokens per model, recomputed with the rest so a re-read can never double them.
        try run("DELETE FROM session_models WHERE session_id = ?", [sessionId])
        try run("""
            INSERT INTO session_models
                (session_id, model, turns, input_tokens, output_tokens, cache_read, cache_create)
            SELECT session_id, model, COUNT(*),
                   COALESCE(SUM(input_tokens), 0), COALESCE(SUM(output_tokens), 0),
                   COALESCE(SUM(cache_read), 0), COALESCE(SUM(cache_create), 0)
            FROM messages
            WHERE session_id = ? AND role = 'assistant' AND model IS NOT NULL AND is_duplicate = 0
            GROUP BY session_id, model
            """, [sessionId])

        let firstPrompt = try scalar("""
            SELECT b.body FROM blocks b JOIN messages m ON b.message_id = m.id
            WHERE m.session_id = ? AND m.role = 'user' AND m.is_meta = 0
              AND m.is_compact_boundary = 0 AND b.kind = 'text'
            ORDER BY m.seq, b.idx LIMIT 1
            """, [sessionId]) as? String

        try run("""
            UPDATE sessions SET
                first_ts = ?, last_ts = ?, user_turns = ?, assistant_turns = ?,
                tool_calls = ?, tool_errors = ?, api_errors = ?,
                input_tokens = ?, output_tokens = ?, cache_read = ?, cache_create = ?,
                lines_added = ?, lines_removed = ?, first_prompt = ?,
                aborted_turns = ?, ended_on_error = ?
            WHERE id = ?
            """, [
                span?[0] as? Double, span?[1] as? Double, userTurns, assistantTurns,
                Self.int(toolCounts?[0]), Self.int(toolCounts?[1]), apiErrors,
                input, output, cacheRead, cacheCreate,
                Self.int(editTotals?[0]), Self.int(editTotals?[1]),
                firstPrompt.map { Self.preview($0) },
                abortedTurns, endedOnError ? 1 : 0, sessionId,
            ])
    }

    /// The first 80 characters of the first prompt, on one line.
    static func preview(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count <= 80 ? flat : String(flat.prefix(79)) + "…"
    }

    static func int(_ value: Binding?) -> Int {
        switch value {
        case let v as Int64: return Int(v)
        case let v as Double: return Int(v)
        case let v as Int: return v
        default: return 0
        }
    }

    // MARK: - Sub-agent linking

    /// Pairs each `subagents/agent-*.jsonl` with the `Agent` call that spawned it.
    ///
    /// Three rules, most reliable first — all three forms occur in the real corpus:
    /// 1. the tool result names the `agentId` outright;
    /// 2. it names a `<name>@session-<prefix>` handle whose name matches the agent id;
    /// 3. the `Agent` call's own `name` input matches it.
    ///
    /// The link can legitimately fail, so `parent_tool_use_id` stays nullable: the sub-agent
    /// transcript is still listed and readable on its own.
    func linkSubagents() throws {
        let pending = try rows("""
            SELECT agent_id, session_id FROM subagents
            WHERE parent_tool_use_id IS NULL AND session_id <> ''
            """)
        for row in pending {
            guard let agentId = row[0] as? String, let sessionId = row[1] as? String else { continue }
            let name = TranscriptWalker.agentName(fromAgentId: agentId)
            let byResult = try scalar("""
                SELECT b.tool_use_id FROM blocks b JOIN messages m ON b.message_id = m.id
                WHERE m.session_id = ? AND b.kind = 'toolResult' AND b.meta IS NOT NULL
                  AND (json_extract(b.meta, '$.agentRef') = ?
                       OR json_extract(b.meta, '$.agentRef') = ?
                       OR json_extract(b.meta, '$.agentRef') LIKE ? || '@%')
                ORDER BY m.seq LIMIT 1
                """, [sessionId, agentId, name, name]) as? String
            var toolUseId = byResult
            if toolUseId == nil, let name {
                toolUseId = try scalar("""
                    SELECT b.tool_use_id FROM blocks b JOIN messages m ON b.message_id = m.id
                    WHERE m.session_id = ? AND b.kind = 'toolUse'
                      AND json_extract(b.meta, '$.agentName') = ?
                    ORDER BY m.seq LIMIT 1
                    """, [sessionId, name]) as? String
            }
            guard let toolUseId else { continue }
            try run("UPDATE subagents SET parent_tool_use_id = ? WHERE agent_id = ?",
                    [toolUseId, agentId])
            try run("UPDATE blocks SET subagent_id = ? WHERE tool_use_id = ? AND kind = 'toolUse'",
                    [agentId, toolUseId])
        }
    }

    // MARK: - Housekeeping

    /// Drops sessions whose transcript is gone, so a deleted project stops showing up.
    private func forgetDisappearedFiles(keeping files: [TranscriptFile]) throws {
        let known = Set(files.map(\.url.path))
        let stale = try rows("SELECT path, session_id FROM files").compactMap { row -> (String, String)? in
            guard let path = row[0] as? String, let sessionId = row[1] as? String else { return nil }
            return known.contains(path) ? nil : (path, sessionId)
        }
        guard !stale.isEmpty else { return }
        try transaction {
            for (path, sessionId) in stale {
                try purge(sessionId: sessionId)
                try run("DELETE FROM sessions WHERE id = ?", [sessionId])
                try run("DELETE FROM subagents WHERE agent_id = ?", [sessionId])
                try run("DELETE FROM files WHERE path = ?", [path])
            }
        }
    }
}

// MARK: - Prepared statements

/// The four inserts the indexer runs millions of times. Preparing them once and re-binding
/// is what keeps a full pass over a gigabyte of transcripts in the tens of seconds.
extension SessionStore {

    var insertMessage: Statement {
        statement(#function, """
            INSERT OR IGNORE INTO messages
                (uuid, session_id, parent_uuid, seq, ts, role, is_sidechain, is_meta,
                 is_compact_boundary, is_api_error, is_aborted, system_subtype, model,
                 api_message_id, is_duplicate, input_tokens, output_tokens, cache_read,
                 cache_create, file_id, line_offset, line_len)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
    }

    var insertBlock: Statement {
        statement(#function, """
            INSERT INTO blocks
                (message_id, idx, kind, tool_name, tool_use_id, is_error, body, meta, subagent_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
    }

    var insertFTS: Statement {
        statement(#function, "INSERT INTO blocks_fts(rowid, body) VALUES (?, ?)")
    }

    var insertEdit: Statement {
        statement(#function, """
            INSERT OR REPLACE INTO edits
                (id, session_id, message_uuid, ts, tool, path, lines_added, lines_removed, project_cwd)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
    }
}
