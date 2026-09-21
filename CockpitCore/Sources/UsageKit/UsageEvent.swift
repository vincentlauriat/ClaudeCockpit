import Foundation

/// One assistant turn extracted from a Claude Code transcript, with its token usage.
///
/// Ported from ClaudeCodeUsage `Models/UsageEvent.swift`. The only added field is
/// `messageId`: the scanner uses it to drop the duplicate assistant lines that appear
/// when the same message is written both to a session transcript and to a sub-agent one.
public struct UsageEvent: Identifiable, Hashable, Codable, Sendable {
    /// Stable identity of the transcript line (`uuid`, else `message.id`, else a fresh UUID).
    public let id: String
    /// `message.id` when the line carried one — the dedupe key across files.
    public let messageId: String?
    public let sessionId: String
    public let model: String
    public let timestamp: Date
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    /// Real working directory the turn ran in (Claude Code's `cwd`). Present on sub-agent
    /// turns too (inherited from the parent session), so it doubles as the project key.
    public let cwd: String
    /// Only set on turns run by a sub-agent (`isSidechain: true`); `nil` on main-session turns.
    public let attributionAgent: String?
    /// Only set on turns run by a sub-agent that was itself invoked via a skill.
    public let attributionSkill: String?

    public init(
        id: String,
        messageId: String? = nil,
        sessionId: String,
        model: String,
        timestamp: Date,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        cwd: String,
        attributionAgent: String? = nil,
        attributionSkill: String? = nil
    ) {
        self.id = id
        self.messageId = messageId
        self.sessionId = sessionId
        self.model = model
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.cwd = cwd
        self.attributionAgent = attributionAgent
        self.attributionSkill = attributionSkill
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    public var day: Date {
        Calendar.current.startOfDay(for: timestamp)
    }

    public func day(in calendar: Calendar) -> Date {
        calendar.startOfDay(for: timestamp)
    }
}

/// Path helpers local to UsageKit (the source app's `Formatters.shortenPath`).
public enum UsagePath {
    /// Replaces the home directory prefix with `~`, matching how paths are shown in a terminal.
    public static func shorten(
        _ path: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let root = home.path
        guard path.hasPrefix(root) else { return path }
        return "~" + path.dropFirst(root.count)
    }
}
