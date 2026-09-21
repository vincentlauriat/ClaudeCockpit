import Foundation
import XCTest
import CockpitShared
@testable import UsageKit

/// Builds a throwaway `$HOME` containing Claude Code style JSONL transcripts, so the scanner
/// can be exercised without touching the developer's real `~/.claude`.
final class TranscriptFixture {
    let home: URL
    private let fm = FileManager.default

    var paths: ClaudePaths { ClaudePaths(home: home) }

    init() throws {
        home = fm.temporaryDirectory
            .appendingPathComponent("UsageKitTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home.appendingPathComponent(".claude/projects", isDirectory: true),
                               withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(at: home) }

    /// `~/.claude/projects/<encodedProject>/<file>`; intermediate directories are created.
    func url(_ relativePath: String) -> URL {
        paths.projectsDir.appendingPathComponent(relativePath)
    }

    func write(_ lines: [String], to relativePath: String) throws {
        let target = url(relativePath)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: target, atomically: true, encoding: .utf8)
    }

    func append(_ line: String, to relativePath: String) throws {
        let target = url(relativePath)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Truncates the last newline, simulating a transcript caught mid-write.
    func appendPartial(_ text: String, to relativePath: String) throws {
        let target = url(relativePath)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: - Line builders

    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func assistantLine(
        uuid: String,
        messageId: String?,
        sessionId: String,
        model: String,
        timestamp: Date,
        cwd: String,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        attributionAgent: String? = nil,
        attributionSkill: String? = nil
    ) -> String {
        var message: [String: Any] = [
            "model": model,
            "usage": [
                "input_tokens": inputTokens,
                "output_tokens": outputTokens,
                "cache_read_input_tokens": cacheReadTokens,
                "cache_creation_input_tokens": cacheCreationTokens,
            ],
        ]
        if let messageId { message["id"] = messageId }

        var obj: [String: Any] = [
            "type": "assistant",
            "uuid": uuid,
            "sessionId": sessionId,
            "timestamp": isoFormatter.string(from: timestamp),
            "cwd": cwd,
            "message": message,
        ]
        if let attributionAgent { obj["attributionAgent"] = attributionAgent }
        if let attributionSkill { obj["attributionSkill"] = attributionSkill }
        return encode(obj)
    }

    static func aiTitleLine(sessionId: String, title: String, cwd: String? = nil) -> String {
        var obj: [String: Any] = ["type": "ai-title", "sessionId": sessionId, "aiTitle": title]
        if let cwd { obj["cwd"] = cwd }
        return encode(obj)
    }

    static func userLine(sessionId: String, cwd: String, timestamp: Date) -> String {
        encode([
            "type": "user",
            "sessionId": sessionId,
            "cwd": cwd,
            "timestamp": isoFormatter.string(from: timestamp),
            "message": ["role": "user", "content": "bonjour"],
        ])
    }

    private static func encode(_ obj: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - In-memory event helper

enum EventFactory {
    /// A `UsageEvent` with sensible zeroes, for aggregator tests that don't need files.
    static func make(
        id: String = UUID().uuidString,
        messageId: String? = nil,
        sessionId: String = "sess",
        model: String = "claude-sonnet-5",
        timestamp: Date,
        cwd: String = "/Users/test/DevApps/ProjA",
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        attributionAgent: String? = nil,
        attributionSkill: String? = nil
    ) -> UsageEvent {
        UsageEvent(
            id: id,
            messageId: messageId,
            sessionId: sessionId,
            model: model,
            timestamp: timestamp,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            cwd: cwd,
            attributionAgent: attributionAgent,
            attributionSkill: attributionSkill)
    }
}

/// Fixed clock and calendar so date-window assertions never depend on when the suite runs.
enum TestClock {
    /// 2026-09-21 is a Monday — the ISO week starts exactly there.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: iso)!
    }

    /// Wednesday 2026-09-23, 12:00 UTC.
    static let now = date("2026-09-23T12:00:00Z")
}
