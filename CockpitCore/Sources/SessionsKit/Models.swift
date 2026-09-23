// SessionsKit — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import Foundation

// MARK: - Sessions

/// One indexed transcript: a Claude Code session, or a sub-agent transcript
/// (`…/<sessionId>/subagents/agent-<agentId>.jsonl`).
///
/// Sub-agent lines carry the *parent* `sessionId`, so a sub-agent's `id` is its
/// `agentId` instead and `parentSessionId` points back at the session that spawned it.
public struct SessionRef: Identifiable, Hashable, Sendable, Codable {
    /// `sessionId` for a session, `agentId` for a sub-agent transcript.
    public let id: String
    /// The encoded directory name under `~/.claude/projects`.
    public let projectDir: String
    public let cwd: String
    /// `customName ?? aiTitle ?? slug ?? first prompt (≤80 chars) ?? id prefix`.
    public let title: String
    public let customName: String?
    public let gitBranch: String?
    public let claudeVersion: String?
    public let firstTimestamp: Date
    public let lastTimestamp: Date
    public let userTurns: Int
    public let assistantTurns: Int
    public let toolCalls: Int
    public let toolErrors: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int
    /// From the transcript's `cost-state` line, when it has one.
    public let costStateUSD: Double?
    public let linesAdded: Int
    public let linesRemoved: Int
    /// Set only on sub-agent transcripts.
    public let parentSessionId: String?
    public let isStarred: Bool
    public let prLinks: [PRLink]
    /// Derived from the counters the indexer stores, so the badge in the list and the verdict
    /// in the detail can never disagree. Never optional: a session with nothing wrong is an A.
    public let healthGrade: HealthGrade
    /// Tokens consumed per model. ``costStateUSD`` is authoritative when Claude Code wrote a
    /// `cost-state` line, which it does for about one session in ten; everywhere else the
    /// view prices these tokens with the rates configured in Réglages.
    public let tokensByModel: [String: ModelTokens]

    public var duration: TimeInterval { lastTimestamp.timeIntervalSince(firstTimestamp) }
    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
    /// True for a `subagents/agent-*.jsonl` transcript.
    public var isSubagent: Bool { parentSessionId != nil }

    public init(
        id: String,
        projectDir: String,
        cwd: String,
        title: String,
        customName: String? = nil,
        gitBranch: String? = nil,
        claudeVersion: String? = nil,
        firstTimestamp: Date,
        lastTimestamp: Date,
        userTurns: Int = 0,
        assistantTurns: Int = 0,
        toolCalls: Int = 0,
        toolErrors: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        costStateUSD: Double? = nil,
        linesAdded: Int = 0,
        linesRemoved: Int = 0,
        parentSessionId: String? = nil,
        isStarred: Bool = false,
        prLinks: [PRLink] = [],
        healthGrade: HealthGrade = .a,
        tokensByModel: [String: ModelTokens] = [:]
    ) {
        self.id = id
        self.projectDir = projectDir
        self.cwd = cwd
        self.title = title
        self.customName = customName
        self.gitBranch = gitBranch
        self.claudeVersion = claudeVersion
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.userTurns = userTurns
        self.assistantTurns = assistantTurns
        self.toolCalls = toolCalls
        self.toolErrors = toolErrors
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.costStateUSD = costStateUSD
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.parentSessionId = parentSessionId
        self.isStarred = isStarred
        self.prLinks = prLinks
        self.healthGrade = healthGrade
        self.tokensByModel = tokensByModel
    }
}

/// A `pr-link` line: a pull request opened from the session.
public struct PRLink: Hashable, Sendable, Codable {
    public let number: Int
    public let url: URL
    public let repository: String
    public let timestamp: Date

    public init(number: Int, url: URL, repository: String, timestamp: Date) {
        self.number = number
        self.url = url
        self.repository = repository
        self.timestamp = timestamp
    }
}

// MARK: - Messages

public enum MessageRole: String, Sendable, Codable, CaseIterable {
    case user, assistant, system
}

/// One transcript line rendered as a turn, with its content blocks already parsed.
public struct SessionMessage: Identifiable, Hashable, Sendable, Codable {
    /// The line's `uuid`.
    public let id: String
    /// Owning session — the `agentId` for a sub-agent transcript.
    public let sessionId: String
    public let parentId: String?
    /// 0-based order within the transcript file.
    public let sequence: Int
    public let timestamp: Date
    public let role: MessageRole
    public let isSidechain: Bool
    public let isMeta: Bool
    public let isCompactBoundary: Bool
    public let isApiError: Bool
    /// The turn was cut short — `isAbortedMidStream`, or the user interrupted it.
    public let isAborted: Bool
    public let model: String?
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int
    public let blocks: [ContentBlock]
    /// For `role == .system`, e.g. `stop_hook_summary`, `compact_boundary`, `turn_duration`.
    public let systemSubtype: String?
    /// Files the user attached to this turn, by display path or file name.
    ///
    /// Only real files: `attachment` is also the line type Claude Code uses for hook output,
    /// token reminders and the skill listing, which are 99,76 % of them and are dropped.
    public let attachments: [String]

    /// Kept as a convenience; it is exactly `attachments.count`, so the two cannot disagree.
    public var attachmentCount: Int { attachments.count }

    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }

    public init(
        id: String,
        sessionId: String,
        parentId: String? = nil,
        sequence: Int,
        timestamp: Date,
        role: MessageRole,
        isSidechain: Bool = false,
        isMeta: Bool = false,
        isCompactBoundary: Bool = false,
        isApiError: Bool = false,
        isAborted: Bool = false,
        model: String? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        blocks: [ContentBlock] = [],
        systemSubtype: String? = nil,
        attachments: [String] = []
    ) {
        self.id = id
        self.sessionId = sessionId
        self.parentId = parentId
        self.sequence = sequence
        self.timestamp = timestamp
        self.role = role
        self.isSidechain = isSidechain
        self.isMeta = isMeta
        self.isCompactBoundary = isCompactBoundary
        self.isApiError = isApiError
        self.isAborted = isAborted
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.blocks = blocks
        self.systemSubtype = systemSubtype
        self.attachments = attachments
    }
}

public enum BlockKind: String, Sendable, Codable, CaseIterable {
    case text, thinking, toolUse, toolResult, image
}

/// One content block of a message. `text` carries whatever the UI has to render:
/// the text itself, the thinking, the tool input as pretty JSON, or the tool output.
public struct ContentBlock: Identifiable, Hashable, Sendable, Codable {
    /// `"<messageUuid>#<idx>"`.
    public let id: String
    public let index: Int
    public let kind: BlockKind
    /// Capped at ``ContentBlock/bodyCap`` bytes; a longer body ends with ``ContentBlock/truncationMarker``.
    public let text: String
    /// `tool_use` only.
    public let toolName: String?
    /// `tool_use` and `tool_result`.
    public let toolUseId: String?
    /// `tool_result.is_error`.
    public let isError: Bool
    /// Present for `Edit`/`Write`/`MultiEdit`/`NotebookEdit` tool calls.
    public let fileEdit: FileEdit?
    public let imageMediaType: String?
    /// For an `Agent`/`Task` `tool_use` whose sub-agent transcript was found.
    public let subagentId: String?

    /// Largest body kept in the index for one block. Beyond it the text is cut and marked,
    /// and the full version is read back from the transcript when the block is displayed.
    /// This cap is what keeps the database growing slower than the corpus.
    public static let storedBodyCap = 8 * 1024
    /// Largest body ever materialised in memory, even when read back from the transcript.
    public static let bodyCap = 2 * 1024 * 1024
    public static let truncationMarker = "\n… [tronqué]"

    public var isTruncated: Bool { text.hasSuffix(Self.truncationMarker) }

    public init(
        id: String,
        index: Int,
        kind: BlockKind,
        text: String,
        toolName: String? = nil,
        toolUseId: String? = nil,
        isError: Bool = false,
        fileEdit: FileEdit? = nil,
        imageMediaType: String? = nil,
        subagentId: String? = nil
    ) {
        self.id = id
        self.index = index
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.toolUseId = toolUseId
        self.isError = isError
        self.fileEdit = fileEdit
        self.imageMediaType = imageMediaType
        self.subagentId = subagentId
    }
}

/// The file-touching part of an `Edit`/`Write`/`MultiEdit`/`NotebookEdit` tool call.
public struct FileEdit: Hashable, Sendable, Codable {
    public let tool: String
    public let path: String
    /// `Edit`/`MultiEdit` (first hunk).
    public let oldString: String?
    public let newString: String?
    /// `Write` only.
    public let content: String?
    public let linesAdded: Int
    public let linesRemoved: Int

    public init(
        tool: String,
        path: String,
        oldString: String? = nil,
        newString: String? = nil,
        content: String? = nil,
        linesAdded: Int,
        linesRemoved: Int
    ) {
        self.tool = tool
        self.path = path
        self.oldString = oldString
        self.newString = newString
        self.content = content
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
    }
}

/// One row of the "Fichiers modifiés" feed.
public struct EditRecord: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let sessionId: String
    public let messageId: String
    public let timestamp: Date
    public let tool: String
    public let path: String
    public let linesAdded: Int
    public let linesRemoved: Int
    public let projectCwd: String

    public init(
        id: String,
        sessionId: String,
        messageId: String,
        timestamp: Date,
        tool: String,
        path: String,
        linesAdded: Int,
        linesRemoved: Int,
        projectCwd: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.messageId = messageId
        self.timestamp = timestamp
        self.tool = tool
        self.path = path
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.projectCwd = projectCwd
    }
}

// MARK: - Querying

/// Everything the list and the search share. `query` switches the store to FTS5.
public struct SessionFilter: Hashable, Sendable {
    public var query: String = ""
    public var projectCwd: String?
    public var since: Date?
    public var until: Date?
    public var starredOnly = false
    public var withErrorsOnly = false
    /// Sub-agent transcripts are hidden unless this is on.
    public var includeSubagents = false
    public var limit = 200
    public var offset = 0

    public init() {}
}

/// One FTS5 hit, with the `snippet()` SQLite produced.
public struct SearchHit: Identifiable, Hashable, Sendable {
    /// The matching message's uuid.
    public let id: String
    public let sessionId: String
    public let messageId: String
    public let snippet: String
    public let timestamp: Date

    public init(sessionId: String, messageId: String, snippet: String, timestamp: Date) {
        self.id = messageId
        self.sessionId = sessionId
        self.messageId = messageId
        self.snippet = snippet
        self.timestamp = timestamp
    }
}

/// One project (working directory) with its session count.
public struct ProjectCount: Identifiable, Hashable, Sendable {
    public var id: String { cwd }
    public let cwd: String
    public let sessions: Int
    public let lastTimestamp: Date

    public init(cwd: String, sessions: Int, lastTimestamp: Date) {
        self.cwd = cwd
        self.sessions = sessions
        self.lastTimestamp = lastTimestamp
    }
}

// MARK: - Health

public enum HealthGrade: String, Sendable, Codable, CaseIterable {
    case a = "A", b = "B", c = "C", d = "D", f = "F"
}

/// Everything the health verdict is computed from, kept up to date by the indexer so that
/// grading a session never has to read its transcript.
///
/// One source of truth: the list badge and the detail popover both come from these numbers
/// through ``SessionHealthRule/evaluate(_:)``.
public struct SessionHealthCounters: Hashable, Sendable, Codable {
    public var toolCalls: Int
    public var toolErrors: Int
    public var apiErrors: Int
    /// The denominator the API-error and interruption rates are taken against.
    public var assistantTurns: Int
    public var abortedTurns: Int
    /// Longest run of consecutive failing tool calls that were the same call.
    public var repeatedFailures: Int
    /// The session's last assistant turn was itself an error.
    public var endedOnError: Bool

    public static let clean = SessionHealthCounters()

    public init(
        toolCalls: Int = 0,
        toolErrors: Int = 0,
        apiErrors: Int = 0,
        assistantTurns: Int = 0,
        abortedTurns: Int = 0,
        repeatedFailures: Int = 0,
        endedOnError: Bool = false
    ) {
        self.toolCalls = toolCalls
        self.toolErrors = toolErrors
        self.apiErrors = apiErrors
        self.assistantTurns = assistantTurns
        self.abortedTurns = abortedTurns
        self.repeatedFailures = repeatedFailures
        self.endedOnError = endedOnError
    }
}

/// A deterministic, LLM-free verdict on how a session went, with its reasons in French.
public struct SessionHealth: Hashable, Sendable, Codable {
    public let grade: HealthGrade
    /// 0–100, clamped.
    public let score: Int
    /// French sentences, in the order the rules fired.
    public let evidence: [String]

    public init(grade: HealthGrade, score: Int, evidence: [String]) {
        self.grade = grade
        self.score = score
        self.evidence = evidence
    }
}

// MARK: - Activity

/// One cell of the hour × weekday heatmap.
public struct ActivityBucket: Hashable, Sendable, Codable {
    /// `Calendar` weekday: 1 = Sunday.
    public let weekday: Int
    /// 0–23.
    public let hour: Int
    public let assistantTurns: Int

    public init(weekday: Int, hour: Int, assistantTurns: Int) {
        self.weekday = weekday
        self.hour = hour
        self.assistantTurns = assistantTurns
    }
}

public struct DayCost: Hashable, Sendable, Codable, Identifiable {
    /// `yyyy-MM-dd`.
    public let id: String
    public let day: Date
    public let costUSD: Double
    public let sessions: Int
    public let turns: Int

    public init(id: String, day: Date, costUSD: Double, sessions: Int, turns: Int) {
        self.id = id
        self.day = day
        self.costUSD = costUSD
        self.sessions = sessions
        self.turns = turns
    }
}

public struct ToolMixRow: Hashable, Sendable, Codable, Identifiable {
    /// The tool name.
    public let id: String
    public let calls: Int
    public let errors: Int

    public var errorRate: Double { calls > 0 ? Double(errors) / Double(calls) : 0 }

    public init(id: String, calls: Int, errors: Int) {
        self.id = id
        self.calls = calls
        self.errors = errors
    }
}

/// The four token counters, for one model.
///
/// Sessions carry these per model rather than a cost, because pricing is edited in Réglages
/// and applied at display time. Freezing a cost at indexing would make a rate change
/// invisible and let two sections show different money for the same tokens.
public struct ModelTokens: Hashable, Sendable, Codable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int

    public var total: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }

    public static let zero = ModelTokens(
        inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)

    public init(
        inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheCreationTokens: Int
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }
}

/// One model and how many assistant turns used it.
public struct ModelCount: Hashable, Sendable, Codable, Identifiable {
    public var id: String { model }
    public let model: String
    public let turns: Int
    /// What this model consumed over the range, for the view to price.
    public let tokens: ModelTokens

    public init(model: String, turns: Int, tokens: ModelTokens = .zero) {
        self.model = model
        self.turns = turns
        self.tokens = tokens
    }
}

/// Everything the "Activité" tab shows for one range.
public struct ActivityReport: Hashable, Sendable, Codable {
    public let buckets: [ActivityBucket]
    public let days: [DayCost]
    public let tools: [ToolMixRow]
    public let models: [ModelCount]
    public let sessions: Int
    public let turns: Int
    public let toolCalls: Int
    public let costUSD: Double

    /// The range's tokens keyed by model, for applying the user's pricing.
    ///
    /// `costUSD` only adds up the `cost-state` lines Claude Code wrote, and it writes one for
    /// barely a tenth of sessions — so on its own it misses most of the spend.
    public var tokensByModel: [String: ModelTokens] {
        Dictionary(models.map { ($0.model, $0.tokens) }, uniquingKeysWith: { first, _ in first })
    }

    public static let empty = ActivityReport(
        buckets: [], days: [], tools: [], models: [],
        sessions: 0, turns: 0, toolCalls: 0, costUSD: 0)

    public init(
        buckets: [ActivityBucket],
        days: [DayCost],
        tools: [ToolMixRow],
        models: [ModelCount],
        sessions: Int,
        turns: Int,
        toolCalls: Int,
        costUSD: Double
    ) {
        self.buckets = buckets
        self.days = days
        self.tools = tools
        self.models = models
        self.sessions = sessions
        self.turns = turns
        self.toolCalls = toolCalls
        self.costUSD = costUSD
    }
}

// MARK: - Indexing

/// Progress of an index pass, published to the UI while it runs.
public struct IndexProgress: Sendable, Equatable, Codable {
    public var filesTotal: Int
    public var filesDone: Int
    public var bytesRead: Int64
    public var isRunning: Bool
    public var lastRun: Date?
    public var dbSizeBytes: Int64

    public var fraction: Double {
        filesTotal > 0 ? min(1, Double(filesDone) / Double(filesTotal)) : 0
    }

    public static let idle = IndexProgress(
        filesTotal: 0, filesDone: 0, bytesRead: 0, isRunning: false, lastRun: nil, dbSizeBytes: 0)

    public init(
        filesTotal: Int,
        filesDone: Int,
        bytesRead: Int64,
        isRunning: Bool,
        lastRun: Date?,
        dbSizeBytes: Int64
    ) {
        self.filesTotal = filesTotal
        self.filesDone = filesDone
        self.bytesRead = bytesRead
        self.isRunning = isRunning
        self.lastRun = lastRun
        self.dbSizeBytes = dbSizeBytes
    }
}

// MARK: - Errors

public enum SessionsError: Error, LocalizedError, Sendable, Equatable {
    case sqlite(String)
    case unknownSession(String)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let message): return "Erreur SQLite : \(message)"
        case .unknownSession(let id): return "Session inconnue : \(id)"
        }
    }
}
