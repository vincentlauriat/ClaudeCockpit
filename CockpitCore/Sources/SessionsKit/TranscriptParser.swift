// SessionsKit — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import Foundation

/// What one JSONL line of a transcript turned out to be.
///
/// Claude Code writes a dozen line types into the same file and adds new ones between
/// releases, so anything the viewer does not render becomes ``ignored`` rather than an error.
public enum ParsedLine: Sendable {
    /// A renderable turn: `user`, `assistant` or `system`.
    case message(ParsedMessage)
    /// A `user`/`system` line that marks a context compaction. Carries the message so the
    /// indexer stores it exactly like ``message``; `isCompactBoundary` is already set.
    case compactBoundary(ParsedMessage)
    case aiTitle(sessionId: String, title: String)
    case prLink(sessionId: String, link: PRLink)
    case costState(sessionId: String, costUSD: Double, linesAdded: Int, linesRemoved: Int)
    /// A file the user attached to their turn. Only its name is kept, and it belongs to the
    /// message the reader last saw — see ``TranscriptParser`` on why that is the parent.
    case attachment(name: String)
    case ignored
}

/// One transcript line turned into a message, with its blocks already split out.
///
/// `sessionId` is what the line itself carries. For a sub-agent transcript that is the
/// *parent* session, so the indexer overrides it with the `agentId`.
public struct ParsedMessage: Sendable {
    public var uuid: String
    public var parentUuid: String?
    public var sessionId: String
    public var agentId: String?
    public var timestamp: Date
    public var role: MessageRole
    public var isSidechain: Bool
    public var isMeta: Bool
    public var isCompactBoundary: Bool
    public var isApiError: Bool
    /// The turn was cut short: `isAbortedMidStream` on the assistant line, or the user line
    /// that carries the `interruptedMessageId` of the turn it stopped.
    public var isAborted: Bool
    public var systemSubtype: String?
    public var model: String?
    /// `message.id` — the key assistant turns are deduped on across files.
    public var apiMessageId: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int
    public var cwd: String?
    public var gitBranch: String?
    public var version: String?
    public var slug: String?
    public var blocks: [ParsedBlock]
    /// Tool-result blocks that name a sub-agent, as `toolUseId → reference`. The reference is
    /// either a bare `agentId` or a `name@session-…` handle; both forms exist in the corpus.
    public var agentReferences: [String: String]
}

/// A content block plus the extra bits only the indexer needs.
public struct ParsedBlock: Sendable {
    public var index: Int
    public var kind: BlockKind
    public var body: String
    public var toolName: String?
    public var toolUseId: String?
    public var isError: Bool
    public var fileEdit: FileEdit?
    public var imageMediaType: String?
    /// For an `Agent`/`Task` call, the `name` given in its input — the last-resort way to
    /// pair the call with its `subagents/agent-*.jsonl`.
    public var agentName: String?
}

/// Turns one raw JSONL line into a ``ParsedLine``.
///
/// ## Which turn an attachment belongs to
/// An attachment's `parentUuid` usually points at *another* attachment rather than at a
/// message: Claude Code chains them, up to nine deep in the real archive. Walking that chain
/// and taking the last message written before the attachment give the same answer on all 273
/// file attachments of the archive, with no exception, so the indexer uses the simpler of the
/// two and the parser does not need to report a parent at all.
///
/// Pure and stateless: the indexer owns every decision that needs more than one line.
/// Uses `JSONSerialization` rather than `Codable` because transcripts carry dozens of keys
/// that change between Claude Code releases and must not break the parse.
public struct TranscriptParser: Sendable {

    /// The only `attachment` kinds that name a file. Everything else under that line type is
    /// Claude Code's own plumbing — hook output, token reminders, the date, the skill listing
    /// — and amounts to 99,8 % of them: 112 015 attachment lines in the real archive, of which
    /// 412 name a file. Counting the rest put a phantom "1 pièce jointe" on nearly every turn.
    ///
    /// `edited_text_file` is deliberately absent although it names a file: it is the notice
    /// that a file changed on disk, not something anyone attached. Over the whole archive 196
    /// of its 205 occurrences land on a line whose only content is a `tool_result`, which is
    /// Claude Code bringing a tool's answer back. Do not add it back thinking it was forgotten.
    ///
    /// The list is an allow-list: a kind Claude Code adds tomorrow is ignored rather than
    /// counted, so the defect stays closed by construction.
    static let fileAttachmentTypes = ["file", "compact_file_reference"]

    /// Line types that never reach the UI. Recognised on the raw bytes so a 200 KB hook
    /// payload is never handed to `JSONSerialization` — `attachment` alone is the most
    /// frequent line type in the corpus.
    static let skippedTypes = [
        "file-history-snapshot", "file-history-delta", "queue-operation",
        "last-prompt", "mode", "permission-mode", "atis-latch",
        "bridge-session", "agent-name",
    ]

    /// Largest body this parser emits per block.
    ///
    /// The indexer uses ``ContentBlock/storedBodyCap`` (8 KB), which is what keeps the
    /// database from growing with the size of tool outputs. The display path re-parses the
    /// same line with ``ContentBlock/bodyCap`` (2 MB) to fill in what was cut.
    public let bodyCap: Int

    public init(bodyCap: Int = ContentBlock.storedBodyCap) {
        self.bodyCap = bodyCap
    }

    /// - Parameter data: one line, without its trailing newline.
    public func parse(_ data: Data) -> ParsedLine {
        // Cheap pre-filter on the raw bytes, before any JSON work. An attachment line only
        // deserves decoding when it might carry a file, which fewer than three in a thousand
        // do — the others can hold 200 KB of hook output that never has to be parsed.
        if Self.contains(data, #""type":"attachment""#) {
            let mayHoldAFile = Self.fileAttachmentTypes.contains {
                Self.contains(data, #""type":"\#($0)""#)
            }
            guard mayHoldAFile else { return .ignored }
        }

        for type in Self.skippedTypes where Self.contains(data, #""type":"\#(type)""#) {
            return .ignored
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let line = object as? [String: Any]
        else { return .ignored }
        return parse(line: line)
    }

    /// The same parse, from an already decoded object. Tests use it directly.
    public func parse(line: [String: Any]) -> ParsedLine {
        let type = line["type"] as? String ?? ""
        let sessionId = (line["sessionId"] as? String) ?? (line["session_id"] as? String) ?? ""

        switch type {
        case "ai-title":
            guard let title = line["aiTitle"] as? String, !sessionId.isEmpty else { return .ignored }
            return .aiTitle(sessionId: sessionId, title: title)

        case "pr-link":
            guard !sessionId.isEmpty,
                  let number = Self.int(line["prNumber"]),
                  let raw = line["prUrl"] as? String,
                  let url = URL(string: raw)
            else { return .ignored }
            let timestamp = (line["timestamp"] as? String).flatMap(Self.date(from:)) ?? Date(timeIntervalSince1970: 0)
            return .prLink(sessionId: sessionId, link: PRLink(
                number: number,
                url: url,
                repository: line["prRepository"] as? String ?? "",
                timestamp: timestamp))

        case "cost-state":
            guard !sessionId.isEmpty else { return .ignored }
            return .costState(
                sessionId: sessionId,
                costUSD: Self.double(line["totalCostUSD"]) ?? 0,
                linesAdded: Self.int(line["totalLinesAdded"]) ?? 0,
                linesRemoved: Self.int(line["totalLinesRemoved"]) ?? 0)

        case "attachment":
            // The decode is what decides: the byte scan can match a kind quoted inside a hook's
            // own output, and the nested `type` is the only authority.
            guard let attachment = line["attachment"] as? [String: Any],
                  let kind = attachment["type"] as? String,
                  Self.fileAttachmentTypes.contains(kind),
                  let name = Self.attachmentName(attachment)
            else { return .ignored }
            return .attachment(name: name)

        case "user", "assistant", "system":
            guard let message = makeMessage(line: line, type: type, sessionId: sessionId) else {
                return .ignored
            }
            return message.isCompactBoundary ? .compactBoundary(message) : .message(message)

        default:
            return .ignored
        }
    }

    // MARK: - Messages

    private func makeMessage(line: [String: Any], type: String, sessionId: String) -> ParsedMessage? {
        guard let uuid = line["uuid"] as? String,
              let timestampString = line["timestamp"] as? String,
              let timestamp = Self.date(from: timestampString)
        else { return nil }

        let role: MessageRole = type == "assistant" ? .assistant : (type == "system" ? .system : .user)
        let subtype = line["subtype"] as? String
        // Two distinct mechanisms land on the same flag: the `system` marker Claude Code
        // writes when it compacts, and the synthetic `user` turn carrying the summary.
        let isCompact = subtype == "compact_boundary" || (line["isCompactSummary"] as? Bool ?? false)

        let message = line["message"] as? [String: Any]
        let usage = message?["usage"] as? [String: Any]

        var parsed = ParsedMessage(
            uuid: uuid,
            parentUuid: line["parentUuid"] as? String,
            sessionId: sessionId,
            agentId: line["agentId"] as? String,
            timestamp: timestamp,
            role: role,
            isSidechain: line["isSidechain"] as? Bool ?? false,
            isMeta: line["isMeta"] as? Bool ?? false,
            isCompactBoundary: isCompact,
            isApiError: line["isApiErrorMessage"] as? Bool ?? false,
            isAborted: (line["isAbortedMidStream"] as? Bool ?? false)
                || line["interruptedMessageId"] != nil,
            systemSubtype: subtype,
            model: message?["model"] as? String,
            apiMessageId: message?["id"] as? String,
            inputTokens: Self.int(usage?["input_tokens"]) ?? 0,
            outputTokens: Self.int(usage?["output_tokens"]) ?? 0,
            cacheReadTokens: Self.int(usage?["cache_read_input_tokens"]) ?? 0,
            cacheCreationTokens: Self.int(usage?["cache_creation_input_tokens"]) ?? 0,
            cwd: line["cwd"] as? String,
            gitBranch: line["gitBranch"] as? String,
            version: line["version"] as? String,
            slug: line["slug"] as? String,
            blocks: [],
            agentReferences: [:])

        var references: [String: String] = [:]
        parsed.blocks = blocks(
            from: message, systemContent: line["content"], references: &references)
        merge(toolUseResult: line["toolUseResult"], blocks: parsed.blocks, into: &references)
        parsed.agentReferences = references
        return parsed
    }

    /// `message.content` is a plain string on most user turns and an array of blocks
    /// otherwise; a `system` line carries its text in a top-level `content` instead.
    private func blocks(
        from message: [String: Any]?,
        systemContent: Any?,
        references: inout [String: String]
    ) -> [ParsedBlock] {
        if let content = message?["content"] {
            if let text = content as? String {
                return text.isEmpty ? [] : [ParsedBlock(
                    index: 0, kind: .text, body: capped(text),
                    toolName: nil, toolUseId: nil, isError: false,
                    fileEdit: nil, imageMediaType: nil, agentName: nil)]
            }
            if let array = content as? [Any] {
                var result: [ParsedBlock] = []
                result.reserveCapacity(array.count)
                for (index, element) in array.enumerated() {
                    if let block = block(at: index, raw: element, references: &references) {
                        result.append(block)
                    }
                }
                return result
            }
        }
        if let text = systemContent as? String, !text.isEmpty {
            return [ParsedBlock(
                index: 0, kind: .text, body: capped(text),
                toolName: nil, toolUseId: nil, isError: false,
                fileEdit: nil, imageMediaType: nil, agentName: nil)]
        }
        return []
    }

    private func block(
        at index: Int, raw: Any, references: inout [String: String]
    ) -> ParsedBlock? {
        guard let object = raw as? [String: Any] else { return nil }
        switch object["type"] as? String {
        case "text":
            let text = object["text"] as? String ?? ""
            guard !text.isEmpty else { return nil }
            return ParsedBlock(index: index, kind: .text, body: capped(text),
                               toolName: nil, toolUseId: nil, isError: false,
                               fileEdit: nil, imageMediaType: nil, agentName: nil)

        case "thinking":
            let text = object["thinking"] as? String ?? ""
            guard !text.isEmpty else { return nil }
            return ParsedBlock(index: index, kind: .thinking, body: capped(text),
                               toolName: nil, toolUseId: nil, isError: false,
                               fileEdit: nil, imageMediaType: nil, agentName: nil)

        case "tool_use", "server_tool_use":
            let name = object["name"] as? String ?? "?"
            let input = object["input"] as? [String: Any] ?? [:]
            return ParsedBlock(
                index: index, kind: .toolUse, body: capped(Self.prettyJSON(input)),
                toolName: name, toolUseId: object["id"] as? String, isError: false,
                fileEdit: Self.fileEdit(tool: name, input: input),
                imageMediaType: nil,
                agentName: Self.isAgentTool(name) ? input["name"] as? String : nil)

        case "tool_result":
            let text = Self.flatten(object["content"])
            let toolUseId = object["tool_use_id"] as? String
            if let toolUseId, let reference = Self.agentReference(in: text) {
                references[toolUseId] = reference
            }
            return ParsedBlock(
                index: index, kind: .toolResult, body: capped(text),
                toolName: nil, toolUseId: toolUseId,
                isError: object["is_error"] as? Bool ?? false,
                fileEdit: nil, imageMediaType: nil, agentName: nil)

        case "image":
            let source = object["source"] as? [String: Any]
            let bytes = (source?["data"] as? String)?.count ?? 0
            return ParsedBlock(
                index: index, kind: .image, body: "",
                toolName: nil, toolUseId: nil, isError: false, fileEdit: nil,
                imageMediaType: source?["media_type"] as? String ?? "image", agentName: nil)
                .withImageBytes(bytes)

        default:
            // `advisor_tool_result` and anything Claude Code adds later: redacted upstream
            // or unknown to the viewer. Dropped rather than rendered as a mystery block.
            return nil
        }
    }

    /// The `toolUseResult` sitting on the same line as a `tool_result` block. It is a
    /// dictionary for most tools and a bare string for some, hence the two shapes.
    private func merge(
        toolUseResult: Any?, blocks: [ParsedBlock], into references: inout [String: String]
    ) {
        guard let result = toolUseResult as? [String: Any] else { return }
        let reference = (result["agentId"] as? String)
            ?? (result["agent_id"] as? String)
            ?? (result["teammate_id"] as? String)
            ?? (result["name"] as? String)
        guard let reference else { return }
        // Attach it to whichever tool_result block this line carries; there is exactly one.
        for block in blocks where block.kind == .toolResult {
            guard let toolUseId = block.toolUseId, references[toolUseId] == nil else { continue }
            references[toolUseId] = reference
        }
    }

    /// `agentId: a1e17712abe09e8df` and `agent_id: dev-1-4@session-3818b05e` both appear
    /// verbatim in tool results; the indexer normalises whichever form comes back.
    static func agentReference(in text: String) -> String? {
        for marker in ["agentId:", "agent_id:"] {
            guard let range = text.range(of: marker) else { continue }
            let rest = text[range.upperBound...].drop(while: { $0 == " " })
            let token = rest.prefix(while: { !$0.isWhitespace && $0 != "(" && $0 != "," })
            if !token.isEmpty { return String(token) }
        }
        return nil
    }

    static func isAgentTool(_ name: String) -> Bool { name == "Agent" || name == "Task" }

    /// What to show for an attached file: the path relative to the project when the line
    /// carries one, otherwise the file's own name, since a full absolute path is too long to
    /// sit in a turn header. Both allowed kinds carry `displayPath`; the fallback is defensive.
    static func attachmentName(_ attachment: [String: Any]) -> String? {
        if let display = (attachment["displayPath"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !display.isEmpty {
            return display
        }
        guard let filename = (attachment["filename"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !filename.isEmpty
        else { return nil }
        let last = filename.split(separator: "/").last.map(String.init) ?? filename
        return last.isEmpty ? filename : last
    }

    // MARK: - File edits

    /// The file-touching tools, with the input keys each of them actually uses.
    static func fileEdit(tool: String, input: [String: Any]) -> FileEdit? {
        switch tool {
        case "Edit":
            guard let path = input["file_path"] as? String else { return nil }
            let old = input["old_string"] as? String
            let new = input["new_string"] as? String
            return FileEdit(
                tool: tool, path: path, oldString: old, newString: new, content: nil,
                linesAdded: lineCount(new), linesRemoved: lineCount(old))

        case "MultiEdit":
            guard let path = input["file_path"] as? String else { return nil }
            let edits = input["edits"] as? [[String: Any]] ?? []
            var added = 0, removed = 0
            for edit in edits {
                added += lineCount(edit["new_string"] as? String)
                removed += lineCount(edit["old_string"] as? String)
            }
            return FileEdit(
                tool: tool, path: path,
                oldString: edits.first?["old_string"] as? String,
                newString: edits.first?["new_string"] as? String,
                content: nil, linesAdded: added, linesRemoved: removed)

        case "Write":
            guard let path = input["file_path"] as? String else { return nil }
            let content = input["content"] as? String
            return FileEdit(
                tool: tool, path: path, oldString: nil, newString: nil, content: content,
                linesAdded: lineCount(content), linesRemoved: 0)

        case "NotebookEdit":
            guard let path = (input["notebook_path"] as? String) ?? (input["file_path"] as? String)
            else { return nil }
            let new = input["new_source"] as? String
            let old = input["old_source"] as? String
            return FileEdit(
                tool: tool, path: path, oldString: old, newString: new, content: nil,
                linesAdded: lineCount(new), linesRemoved: lineCount(old))

        default:
            return nil
        }
    }

    /// Lines in a replacement string: newlines plus one, and zero for nothing at all.
    static func lineCount(_ text: String?) -> Int {
        guard let text, !text.isEmpty else { return 0 }
        var count = 1
        for character in text where character == "\n" { count += 1 }
        // A trailing newline does not open a new line.
        if text.hasSuffix("\n") { count -= 1 }
        return count
    }

    // MARK: - Helpers

    /// `tool_result.content` is a string for simple tools and an array of blocks otherwise.
    static func flatten(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let array = content as? [Any] else { return "" }
        var parts: [String] = []
        for element in array {
            guard let object = element as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "text": parts.append(object["text"] as? String ?? "")
            case "image":
                let media = (object["source"] as? [String: Any])?["media_type"] as? String ?? "image"
                parts.append("[image \(media)]")
            default: break
            }
        }
        return parts.joined(separator: "\n")
    }

    static func prettyJSON(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return String(describing: object) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Keeps one block under ``bodyCap`` bytes, marking what it cut.
    func capped(_ text: String) -> String { Self.capped(text, cap: bodyCap) }

    static func capped(_ text: String, cap: Int) -> String {
        guard text.utf8.count > cap else { return text }
        // Cutting mid-character would leave a replacement glyph in the middle of an accented
        // French word, so the cut backs up to the nearest character boundary.
        var cut = text.utf8.index(text.utf8.startIndex, offsetBy: cap)
        while cut > text.utf8.startIndex, String.Index(cut, within: text) == nil {
            cut = text.utf8.index(before: cut)
        }
        let boundary = String.Index(cut, within: text) ?? text.startIndex
        return String(text[..<boundary]) + ContentBlock.truncationMarker
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: return v
        case let v as Double: return Int(v)
        case let v as NSNumber: return v.intValue
        case let v as String: return Int(v)
        default: return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as NSNumber: return v.doubleValue
        case let v as String: return Double(v)
        default: return nil
        }
    }

    // MARK: - Raw byte scanning

    /// Substring search on the raw line, used before any JSON decoding.
    static func contains(_ data: Data, _ needle: String) -> Bool {
        data.range(of: Data(needle.utf8)) != nil
    }

    // MARK: - Timestamps

    /// Claude Code always writes `2026-09-22T08:19:19.200Z`. Decoding three million of those
    /// through `ISO8601DateFormatter` costs seconds, so the fixed shape is read by hand and
    /// the formatter is only the fallback for anything else.
    static func date(from string: String) -> Date? {
        if let fast = fastDate(from: string) { return fast }
        return isoWithFraction.date(from: string) ?? iso.date(from: string)
    }

    static func fastDate(from string: String) -> Date? {
        let utf8 = Array(string.utf8)
        guard utf8.count >= 20, utf8[4] == 0x2D, utf8[7] == 0x2D, utf8[10] == 0x54,
              utf8[13] == 0x3A, utf8[16] == 0x3A, utf8.last == 0x5A  // 'Z'
        else { return nil }

        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let byte = utf8[index]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19)
        else { return nil }

        var milliseconds = 0
        if utf8.count >= 24, utf8[19] == 0x2E, let fraction = number(20..<23) {
            milliseconds = fraction
        } else if utf8.count != 20 {
            return nil  // some other shape — let the formatter decide
        }

        // Days since the Unix epoch, civil-from-days (Howard Hinnant's algorithm).
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468

        let seconds = Double(days) * 86_400 + Double(hour * 3600 + minute * 60 + second)
        return Date(timeIntervalSince1970: seconds + Double(milliseconds) / 1000)
    }

    static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

extension ParsedBlock {
    /// Images keep their byte size in the body so the UI can show "image, 1,2 Mo" without
    /// the base64 payload ever reaching the database.
    func withImageBytes(_ bytes: Int) -> ParsedBlock {
        var copy = self
        copy.body = bytes > 0 ? "\(bytes)" : ""
        return copy
    }
}
