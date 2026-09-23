import Foundation
import CockpitShared
@testable import SessionsKit

/// Builds a throwaway `$HOME` holding Claude Code style transcripts, so SessionsKit can be
/// exercised without ever touching the developer's real `~/.claude`.
final class TranscriptFixture {
    let home: URL
    private let manager = FileManager.default

    var paths: ClaudePaths { ClaudePaths(home: home) }
    /// The index always lives inside the throwaway home, never in the real app support folder.
    var databaseURL: URL { home.appendingPathComponent("sessions.db") }

    init() throws {
        home = manager.temporaryDirectory
            .appendingPathComponent("SessionsKitTests-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(
            at: home.appendingPathComponent(".claude/projects", isDirectory: true),
            withIntermediateDirectories: true)
    }

    deinit { try? manager.removeItem(at: home) }

    func url(_ relativePath: String) -> URL {
        paths.projectsDir.appendingPathComponent(relativePath)
    }

    func write(_ lines: [String], to relativePath: String) throws {
        let target = url(relativePath)
        try manager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: target, atomically: true, encoding: .utf8)
    }

    func append(_ line: String, to relativePath: String) throws {
        try appendRaw(line + "\n", to: relativePath)
    }

    /// Writes without the closing newline, simulating a transcript caught mid-write.
    func appendPartial(_ text: String, to relativePath: String) throws {
        try appendRaw(text, to: relativePath)
    }

    private func appendRaw(_ text: String, to relativePath: String) throws {
        let handle = try FileHandle(forWritingTo: url(relativePath))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func service() -> SessionService {
        SessionService(paths: paths, databaseURL: databaseURL)
    }
}

// MARK: - Line builders

/// Every line kind the viewer has to survive, written the way Claude Code writes it.
enum Line {
    static let project = "-Users-test-DevApps-Demo"
    static let session = "sess-1"
    static let cwd = "/Users/test/DevApps/Demo"
    static let agentId = "ahelper-0123456789abcdef"
    static let stuckSession = "sess-stuck"

    /// One assistant turn running the same failing command, plus the error it gets back.
    /// Repeating it is what a stuck agent looks like to the health counter.
    static func stuckFailure(index: Int) -> [String] {
        [
            assistant(uuid: "stuck-a\(index)", at: TestClock.offset(index * 2),
                      blocks: [toolUse(id: "stuck-t\(index)", name: "Bash",
                                       input: ["command": "swift build"])],
                      messageId: "msg-stuck-\(index)", sessionId: stuckSession),
            toolResult(uuid: "stuck-u\(index)", at: TestClock.offset(index * 2 + 1),
                       toolUseId: "stuck-t\(index)", text: "error: build failed",
                       isError: true, sessionId: stuckSession),
        ]
    }

    static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func encode(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// The keys every renderable line carries.
    private static func envelope(
        type: String, uuid: String, at date: Date, sessionId: String, agentId: String?,
        cwd: String = cwd
    ) -> [String: Any] {
        var object: [String: Any] = [
            "type": type,
            "uuid": uuid,
            "sessionId": sessionId,
            "timestamp": iso.string(from: date),
            "cwd": cwd,
            "gitBranch": "feat/sessions-viewer",
            "version": "2.1.278",
            "slug": "demo-slug",
        ]
        if let agentId {
            object["agentId"] = agentId
            object["isSidechain"] = true
        }
        return object
    }

    static func user(
        uuid: String, text: String, at date: Date,
        sessionId: String = session, agentId: String? = nil, isMeta: Bool = false,
        cwd: String = cwd
    ) -> String {
        var object = envelope(
            type: "user", uuid: uuid, at: date, sessionId: sessionId, agentId: agentId, cwd: cwd)
        object["message"] = ["role": "user", "content": text]
        if isMeta { object["isMeta"] = true }
        return encode(object)
    }

    /// A user line carrying the summary Claude Code writes when it compacts the context.
    static func compactSummary(uuid: String, at date: Date, sessionId: String = session) -> String {
        var object = envelope(type: "user", uuid: uuid, at: date, sessionId: sessionId, agentId: nil)
        object["message"] = ["role": "user", "content": "This session is being continued…"]
        object["isCompactSummary"] = true
        return encode(object)
    }

    /// A `system` line the reader never wants — and which carries `isMeta: false`, exactly
    /// like every system line in the real corpus.
    static func systemNote(
        uuid: String, subtype: String, at date: Date, sessionId: String = session
    ) -> String {
        var object = envelope(type: "system", uuid: uuid, at: date, sessionId: sessionId, agentId: nil)
        object["subtype"] = subtype
        object["content"] = "durée du tour : 12 s"
        return encode(object)
    }

    static func compactBoundary(uuid: String, at date: Date, sessionId: String = session) -> String {
        var object = envelope(type: "system", uuid: uuid, at: date, sessionId: sessionId, agentId: nil)
        object["subtype"] = "compact_boundary"
        object["content"] = "Conversation compacted"
        object["compactMetadata"] = ["trigger": "manual", "preTokens": 393_620, "postTokens": 62_067]
        return encode(object)
    }

    static func assistant(
        uuid: String, at date: Date, blocks: [[String: Any]],
        messageId: String? = nil, model: String = "claude-opus-5",
        sessionId: String = session, agentId: String? = nil,
        inputTokens: Int = 10, outputTokens: Int = 20,
        cacheReadTokens: Int = 5, cacheCreationTokens: Int = 2,
        isApiError: Bool = false, isAborted: Bool = false, cwd: String = cwd
    ) -> String {
        var object = envelope(
            type: "assistant", uuid: uuid, at: date, sessionId: sessionId, agentId: agentId, cwd: cwd)
        var message: [String: Any] = [
            "role": "assistant",
            "model": model,
            "content": blocks,
            "usage": [
                "input_tokens": inputTokens,
                "output_tokens": outputTokens,
                "cache_read_input_tokens": cacheReadTokens,
                "cache_creation_input_tokens": cacheCreationTokens,
            ],
        ]
        if let messageId { message["id"] = messageId }
        object["message"] = message
        if isApiError { object["isApiErrorMessage"] = true }
        if isAborted { object["isAbortedMidStream"] = true }
        return encode(object)
    }

    /// The `user` line that carries a tool's answer back, with its structured `toolUseResult`.
    static func toolResult(
        uuid: String, at date: Date, toolUseId: String, text: String,
        isError: Bool = false, sessionId: String = session, agentId: String? = nil,
        toolUseResult: [String: Any]? = nil
    ) -> String {
        var object = envelope(type: "user", uuid: uuid, at: date, sessionId: sessionId, agentId: agentId)
        var block: [String: Any] = [
            "type": "tool_result", "tool_use_id": toolUseId, "content": text,
        ]
        if isError { block["is_error"] = true }
        object["message"] = ["role": "user", "content": [block]]
        if let toolUseResult { object["toolUseResult"] = toolUseResult }
        return encode(object)
    }

    static func attachment(parentUuid: String, sessionId: String = session) -> String {
        encode([
            "type": "attachment",
            "uuid": UUID().uuidString,
            "parentUuid": parentUuid,
            "sessionId": sessionId,
            "attachment": ["type": "hook_success", "stdout": String(repeating: "x", count: 4000)],
        ])
    }

    static func aiTitle(_ title: String, sessionId: String = session) -> String {
        encode(["type": "ai-title", "aiTitle": title, "sessionId": sessionId])
    }

    static func prLink(number: Int, at date: Date, sessionId: String = session) -> String {
        encode([
            "type": "pr-link", "sessionId": sessionId, "prNumber": number,
            "prUrl": "https://github.com/test/demo/pull/\(number)",
            "prRepository": "test/demo",
            "timestamp": iso.string(from: date),
        ])
    }

    static func costState(_ cost: Double, sessionId: String = session) -> String {
        encode([
            "type": "cost-state", "sessionId": sessionId, "totalCostUSD": cost,
            "totalLinesAdded": 12, "totalLinesRemoved": 3, "startTime": 1_790_089_678_658,
        ])
    }

    /// A line type the viewer never renders — it must be skipped without a JSON decode.
    static func noise(sessionId: String = session) -> String {
        encode(["type": "file-history-snapshot", "sessionId": sessionId,
                "snapshot": String(repeating: "y", count: 2000)])
    }

    // MARK: Content blocks

    static func text(_ value: String) -> [String: Any] { ["type": "text", "text": value] }
    static func thinking(_ value: String) -> [String: Any] { ["type": "thinking", "thinking": value] }

    static func toolUse(id: String, name: String, input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    static func image(mediaType: String = "image/png") -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": "AAAA"]]
    }
}

/// A fixed clock so nothing in the suite depends on when it runs.
enum TestClock {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    static func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: value)!
    }

    /// Wednesday 2026-09-23, 10:00 UTC.
    static let start = date("2026-09-23T10:00:00Z")

    static func offset(_ minutes: Int) -> Date { start.addingTimeInterval(Double(minutes) * 60) }
}

// MARK: - A complete demo session

extension TranscriptFixture {

    /// A session that keeps running the same command and keeps getting the same error.
    @discardableResult
    func writeStuckSession(failures: Int = 3) throws -> String {
        let path = "\(Line.project)/\(Line.stuckSession).jsonl"
        var lines = [Line.user(uuid: "stuck-start", text: "Répare le build", at: TestClock.offset(0),
                               sessionId: Line.stuckSession)]
        for index in 0..<failures { lines += Line.stuckFailure(index: index) }
        try write(lines, to: path)
        return path
    }

    /// One session covering every line kind and block kind the spec calls out, plus the
    /// sub-agent transcript spawned from it.
    @discardableResult
    func writeDemoSession() throws -> String {
        let path = "\(Line.project)/\(Line.session).jsonl"
        try write([
            Line.user(uuid: "u1", text: "Corrige le parseur de transcripts", at: TestClock.offset(0)),
            Line.assistant(uuid: "a1", at: TestClock.offset(1), blocks: [
                Line.thinking("Il faut regarder le fichier d'abord."),
                Line.text("Je regarde le fichier."),
                Line.toolUse(id: "tool-bash", name: "Bash", input: ["command": "ls -la"]),
            ], messageId: "msg-a1"),
            Line.toolResult(uuid: "u2", at: TestClock.offset(2), toolUseId: "tool-bash",
                            text: "total 24\ndrwxr-xr-x"),
            Line.attachment(parentUuid: "u2"),
            Line.noise(),

            Line.assistant(uuid: "a2", at: TestClock.offset(3), blocks: [
                Line.toolUse(id: "tool-edit", name: "Edit", input: [
                    "file_path": "/Users/test/DevApps/Demo/Parser.swift",
                    "old_string": "let a = 1\nlet b = 2",
                    "new_string": "let a = 1\nlet b = 3\nlet c = 4",
                ]),
            ], messageId: "msg-a2"),
            Line.toolResult(uuid: "u3", at: TestClock.offset(4), toolUseId: "tool-edit",
                            text: "Edit applied"),

            Line.assistant(uuid: "a3", at: TestClock.offset(5), blocks: [
                Line.toolUse(id: "tool-write", name: "Write", input: [
                    "file_path": "/Users/test/DevApps/Demo/Notes.md",
                    "content": "# Notes\nune ligne\nune autre",
                ]),
            ], messageId: "msg-a3"),
            Line.toolResult(uuid: "u4", at: TestClock.offset(6), toolUseId: "tool-write",
                            text: "File created"),

            Line.assistant(uuid: "a4", at: TestClock.offset(7), blocks: [
                Line.toolUse(id: "tool-agent", name: "Agent", input: [
                    "name": "helper", "subagent_type": "general-purpose", "prompt": "Va vérifier.",
                ]),
            ], messageId: "msg-a4"),
            Line.toolResult(
                uuid: "u5", at: TestClock.offset(8), toolUseId: "tool-agent",
                text: "Spawned successfully.\nagentId: \(Line.agentId) (internal ID)",
                toolUseResult: ["status": "teammate_spawned", "name": "helper"]),

            Line.assistant(uuid: "a5", at: TestClock.offset(9), blocks: [
                Line.toolUse(id: "tool-bash-2", name: "Bash", input: ["command": "swift build"]),
            ], messageId: "msg-a5"),
            Line.toolResult(uuid: "u6", at: TestClock.offset(10), toolUseId: "tool-bash-2",
                            text: "error: build failed", isError: true),

            Line.systemNote(uuid: "s0", subtype: "turn_duration", at: TestClock.offset(10)),
            Line.compactBoundary(uuid: "s1", at: TestClock.offset(11)),
            Line.compactSummary(uuid: "u7", at: TestClock.offset(12)),

            Line.assistant(uuid: "a6", at: TestClock.offset(13), blocks: [
                Line.text("La requête a échoué."), Line.image(),
            ], messageId: "msg-a6", model: "<synthetic>", isApiError: true),

            Line.aiTitle("Correction du parseur"),
            Line.prLink(number: 42, at: TestClock.offset(14)),
            Line.costState(1.2345),
        ], to: path)

        try write([
            Line.user(uuid: "s-u1", text: "<teammate-message>Va vérifier.</teammate-message>",
                      at: TestClock.offset(8), agentId: Line.agentId),
            Line.assistant(uuid: "s-a1", at: TestClock.offset(9), blocks: [
                Line.text("Vérification terminée, tout est vert."),
            ], messageId: "msg-sub-1", agentId: Line.agentId),
        ], to: "\(Line.project)/\(Line.session)/subagents/agent-\(Line.agentId).jsonl")

        return path
    }
}
