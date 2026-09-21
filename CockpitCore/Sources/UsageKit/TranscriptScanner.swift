import Foundation
import CockpitShared

/// Incrementally scans Claude Code's JSONL transcripts under `~/.claude/projects/**` and
/// extracts `UsageEvent`s from assistant turns. The tree holds both session transcripts
/// (`<encoded cwd>/<session>.jsonl`) and sub-agent ones (`…/subagents/agent-*.jsonl`);
/// both are read, and assistant messages carrying a `message.id` are deduped across files.
///
/// Transcripts are append-only, so each scan only reads the bytes appended since the last
/// scan of a given file (tracked by byte offset + mtime). Call `reset()` to force a full
/// re-read.
public actor TranscriptScanner {
    /// Everything a scan produces: the flat event list (for stats/charts/breakdowns) plus the
    /// session-level metadata collected along the way (for the sessions list).
    public struct ScanResult: Sendable {
        /// Every deduped event known so far, oldest file first.
        public let events: [UsageEvent]
        public let sessionInfo: [String: SessionInfo]
        /// Events parsed during this scan only — lets callers (and tests) see that an
        /// incremental scan re-read nothing it had already read.
        public let newEvents: [UsageEvent]
        /// Bytes actually read from disk during this scan.
        public let bytesRead: Int
    }

    private struct FileState: Codable {
        var offset: UInt64
        var mtime: Date
        var events: [UsageEvent]
    }

    /// Everything persisted to disk between launches, so a relaunch doesn't have to re-read
    /// every transcript from byte zero.
    private struct PersistedCache: Codable {
        var fileStates: [String: FileState]
        var sessionInfo: [String: SessionInfo]
    }

    public let paths: ClaudePaths

    private var fileStates: [String: FileState] = [:]
    /// Keyed by sessionId. `ai-title`/`slug`/`cwd` don't appear on every line (unlike the
    /// fields on `UsageEvent`), so they're accumulated separately while scanning every line
    /// type, not just assistant turns.
    private var sessionInfoBySessionId: [String: SessionInfo] = [:]
    private var didLoadPersistedCache = false

    private let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public init(paths: ClaudePaths = .live) {
        self.paths = paths
    }

    public var cacheFileURL: URL {
        paths.appSupportDir.appendingPathComponent("scan-cache.json")
    }

    /// Clears all cached offsets, forcing a full re-read of every transcript on the next scan.
    /// Also drops the on-disk cache so a relaunch after a rescan doesn't reload stale data.
    public func reset() {
        fileStates.removeAll()
        sessionInfoBySessionId.removeAll()
        didLoadPersistedCache = true
        try? FileManager.default.removeItem(at: cacheFileURL)
    }

    /// Scans every `.jsonl` transcript and returns the full accumulated set of usage events
    /// plus per-session metadata (title/slug/project).
    @discardableResult
    public func scan() -> ScanResult {
        loadPersistedCacheIfNeeded()

        var didChange = false
        var newEvents: [UsageEvent] = []
        var bytesRead = 0

        let fm = FileManager.default
        if let enumerator = fm.enumerator(
            at: paths.projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            // Sorted so dedupe keeps a deterministic winner when the same `message.id`
            // appears in more than one transcript.
            let urls = (enumerator.allObjects as? [URL] ?? [])
                .filter { $0.pathExtension == "jsonl" }
                .sorted { $0.path < $1.path }
            for url in urls {
                let outcome = scanFile(at: url)
                if outcome.changed { didChange = true }
                newEvents.append(contentsOf: outcome.events)
                bytesRead += outcome.bytesRead
            }
        }

        if didChange {
            persistCache()
        }

        return ScanResult(
            events: dedupedEvents(),
            sessionInfo: sessionInfoBySessionId,
            newEvents: newEvents,
            bytesRead: bytesRead
        )
    }

    /// Flattens the per-file caches in path order, dropping assistant messages already seen
    /// under the same `message.id`. Lines without a `message.id` are always kept: there is no
    /// key to dedupe them on.
    private func dedupedEvents() -> [UsageEvent] {
        var seen = Set<String>()
        var result: [UsageEvent] = []
        for path in fileStates.keys.sorted() {
            guard let state = fileStates[path] else { continue }
            for event in state.events {
                if let messageId = event.messageId {
                    if seen.contains(messageId) { continue }
                    seen.insert(messageId)
                }
                result.append(event)
            }
        }
        return result
    }

    /// Loads the on-disk cache (if any) once per instance, so the very first scan after launch
    /// only has to read bytes appended since the app was last quit.
    private func loadPersistedCacheIfNeeded() {
        guard !didLoadPersistedCache else { return }
        didLoadPersistedCache = true
        guard let data = try? Data(contentsOf: cacheFileURL),
              let persisted = try? JSONDecoder().decode(PersistedCache.self, from: data)
        else { return }
        fileStates = persisted.fileStates
        sessionInfoBySessionId = persisted.sessionInfo
    }

    private func persistCache() {
        let payload = PersistedCache(fileStates: fileStates, sessionInfo: sessionInfoBySessionId)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: paths.appSupportDir, withIntermediateDirectories: true)
        try? data.write(to: cacheFileURL, options: .atomic)
    }

    private struct FileOutcome {
        /// Whether this file's cached state actually changed — callers skip writing the
        /// persisted cache back to disk when nothing happened, the common case on a 30 s
        /// auto-refresh with no new Claude Code activity.
        var changed: Bool
        var events: [UsageEvent]
        var bytesRead: Int
    }

    private func scanFile(at url: URL) -> FileOutcome {
        let path = url.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.uint64Value
        else { return FileOutcome(changed: false, events: [], bytesRead: 0) }

        if let existing = fileStates[path], existing.mtime == mtime, existing.offset == size {
            return FileOutcome(changed: false, events: [], bytesRead: 0) // unchanged since last scan
        }

        var startOffset: UInt64 = 0
        var priorEvents: [UsageEvent] = []
        if let existing = fileStates[path], size >= existing.offset {
            startOffset = existing.offset
            priorEvents = existing.events
        }
        // Otherwise the file shrank or was replaced (unexpected for append-only transcripts):
        // re-read from the start.

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return FileOutcome(changed: false, events: [], bytesRead: 0)
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: startOffset)

        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else {
            fileStates[path] = FileState(offset: startOffset, mtime: mtime, events: priorEvents)
            return FileOutcome(changed: true, events: [], bytesRead: 0)
        }

        guard let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) else {
            // No complete line yet in this chunk (mid-write) — retry from the same offset later.
            fileStates[path] = FileState(offset: startOffset, mtime: mtime, events: priorEvents)
            return FileOutcome(changed: true, events: [], bytesRead: 0)
        }

        let completeData = chunk[chunk.startIndex...lastNewline]
        let newOffset = startOffset + UInt64(completeData.count)
        let text = String(decoding: completeData, as: UTF8.self)

        var newEvents: [UsageEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = Self.parseJSON(line) else { continue }

            if let event = parseEvent(from: obj) {
                newEvents.append(event)
            }
            if let sessionId = (obj["sessionId"] as? String) ?? (obj["session_id"] as? String) {
                updateSessionInfo(sessionId: sessionId, obj: obj)
            }
        }

        fileStates[path] = FileState(
            offset: newOffset, mtime: mtime, events: priorEvents + newEvents)
        return FileOutcome(changed: true, events: newEvents, bytesRead: completeData.count)
    }

    /// Merges any of `title`/`slug`/`cwd` found on this line into that session's accumulated
    /// info. Called for every line type (not just assistant turns), since a human-readable
    /// name only ever appears on a standalone `type: "ai-title"` line.
    private func updateSessionInfo(sessionId: String, obj: [String: Any]) {
        var info = sessionInfoBySessionId[sessionId] ?? SessionInfo()
        if (obj["type"] as? String) == "ai-title", let aiTitle = obj["aiTitle"] as? String {
            info.title = aiTitle
        }
        if let slug = obj["slug"] as? String {
            info.slug = slug
        }
        if let cwd = obj["cwd"] as? String {
            info.cwd = cwd
        }
        sessionInfoBySessionId[sessionId] = info
    }

    private static func parseJSON(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func parseEvent(from obj: [String: Any]) -> UsageEvent? {
        guard (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String,
              let sessionId = (obj["sessionId"] as? String) ?? (obj["session_id"] as? String),
              let timestampString = obj["timestamp"] as? String,
              let timestamp = date(from: timestampString),
              let cwd = obj["cwd"] as? String
        else { return nil }

        let messageId = message["id"] as? String
        let id = (obj["uuid"] as? String) ?? messageId ?? UUID().uuidString

        return UsageEvent(
            id: id,
            messageId: messageId,
            sessionId: sessionId,
            model: model,
            timestamp: timestamp,
            inputTokens: usage["input_tokens"] as? Int ?? 0,
            outputTokens: usage["output_tokens"] as? Int ?? 0,
            cacheCreationTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
            cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
            cwd: cwd,
            attributionAgent: obj["attributionAgent"] as? String,
            attributionSkill: obj["attributionSkill"] as? String
        )
    }

    private func date(from string: String) -> Date? {
        isoWithFraction.date(from: string) ?? iso.date(from: string)
    }
}
