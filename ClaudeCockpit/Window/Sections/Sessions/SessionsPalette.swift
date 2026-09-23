// Sessions UI palette — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import SwiftUI
import CockpitShared
import SessionsKit
import UsageKit

/// One rendered line of a file-edit diff.
struct DiffLine: Identifiable, Hashable {
    enum Kind { case added, removed }
    let id: Int
    let kind: Kind
    let text: String
}

/// Icons, tints and text helpers shared by the sessions browser, the transcript
/// renderer and the tool cards. Pure functions only: no state, no store access.
enum SessionsPalette {

    /// A transcript that moved less than this ago is shown as live.
    static let liveWindow: TimeInterval = 120
    /// Beyond this many bytes a block renders as plain monospaced text: parsing
    /// markdown on every redraw of a body that may reach `ContentBlock.bodyCap`
    /// (2 MB) would stall the scroll.
    static let markdownCap = 20_000
    /// Tool output longer than this is cut until the reader asks for the rest.
    static let outputCap = 4_000
    /// Diff lines rendered before the rest is summarised away.
    static let diffLineCap = 600

    // MARK: - Tools

    /// SF Symbol for a tool call. MCP tools are named `mcp__<server>__<tool>`.
    static func icon(forTool name: String?) -> String {
        guard let name, !name.isEmpty else { return "wrench.and.screwdriver" }
        if name.hasPrefix("mcp__") { return "puzzlepiece.extension" }
        switch name {
        case "Bash", "BashOutput", "KillShell": return "terminal"
        case "Read", "NotebookRead": return "doc.text"
        case "Write", "Edit", "MultiEdit", "NotebookEdit": return "square.and.pencil"
        case "Grep", "Glob", "Search": return "magnifyingglass"
        case "Agent", "Task": return "person.2"
        case "Skill", "SlashCommand": return "sparkles"
        case "WebFetch", "WebSearch": return "globe"
        case "TodoWrite": return "checklist"
        default: return "wrench.and.screwdriver"
        }
    }

    /// Tint of a tool's icon. Stays inside the Theme palette so the transcript
    /// keeps the same colour language as the rest of the window.
    static func tint(forTool name: String?) -> Color {
        guard let name, !name.isEmpty else { return Theme.slate }
        if name.hasPrefix("mcp__") { return Theme.violet }
        switch name {
        case "Bash", "BashOutput", "KillShell": return Theme.accent
        case "Write", "Edit", "MultiEdit", "NotebookEdit": return Theme.emerald
        case "Agent", "Task", "Skill", "SlashCommand": return Theme.violet
        default: return Theme.blue
        }
    }

    /// The one-line argument shown next to the tool name: the command for `Bash`,
    /// the path for the file tools, the pattern for `Grep`.
    static func argumentTag(toolName: String?, input: String, fileEdit: FileEdit?) -> String? {
        if let fileEdit { return oneLine(UsagePath.shorten(fileEdit.path)) }
        guard let object = inputObject(input) else {
            let flattened = oneLine(input)
            return flattened.isEmpty ? nil : flattened
        }
        for key in preferredKeys(for: toolName) {
            guard let value = object[key] as? String, !value.isEmpty else { continue }
            let shown = pathKeys.contains(key) ? UsagePath.shorten(value) : value
            return oneLine(shown)
        }
        return nil
    }

    private static let pathKeys: Set<String> = ["file_path", "path", "notebook_path", "cwd"]

    private static func preferredKeys(for toolName: String?) -> [String] {
        switch toolName {
        case "Bash": return ["command", "description"]
        case "Read", "Write", "Edit", "MultiEdit": return ["file_path", "path"]
        case "NotebookEdit", "NotebookRead": return ["notebook_path", "file_path"]
        case "Grep", "Glob": return ["pattern", "query", "path"]
        case "Agent", "Task": return ["description", "subagent_type", "prompt"]
        case "Skill": return ["skill", "command", "args"]
        case "SlashCommand": return ["command"]
        case "WebFetch": return ["url", "prompt"]
        case "WebSearch": return ["query"]
        default:
            return ["command", "file_path", "path", "pattern", "query", "url", "description", "prompt", "name"]
        }
    }

    private static func inputObject(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// Collapses a value onto one line and cuts it to a header-sized tag.
    static func oneLine(_ raw: String, limit: Int = 140) -> String {
        let flattened = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }

    // MARK: - Text

    /// Markdown-lite: inline syntax only, so the source line breaks of a transcript
    /// survive. Bodies over ``markdownCap`` are left as plain text.
    static func markdown(_ raw: String) -> AttributedString {
        guard raw.utf8.count <= markdownCap else { return AttributedString(raw) }
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: raw, options: options)) ?? AttributedString(raw)
    }

    /// `sonnet-4-5` out of `claude-sonnet-4-5-20250929`.
    static func modelLabel(_ model: String?) -> String {
        guard let model, !model.isEmpty else { return "—" }
        var name = model
        if name.hasPrefix("claude-") { name = String(name.dropFirst(7)) }
        let parts = name.split(separator: "-")
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            name = parts.dropLast().joined(separator: "-")
        }
        return name
    }

    // MARK: - Health

    static func color(for grade: HealthGrade) -> Color {
        switch grade {
        case .a: return Theme.emerald
        case .b: return Theme.emerald
        case .c: return .orange
        case .d: return .orange
        case .f: return .red
        }
    }

    // MARK: - Diffs

    /// `oldString` as removed lines then `newString` as added ones; a `Write`
    /// shows its whole `content` as added.
    static func diffLines(for edit: FileEdit) -> [DiffLine] {
        var lines: [DiffLine] = []
        var index = 0
        func append(_ text: String, kind: DiffLine.Kind) {
            for line in text.components(separatedBy: "\n") {
                guard lines.count < diffLineCap else { return }
                lines.append(DiffLine(id: index, kind: kind, text: line))
                index += 1
            }
        }
        if let old = edit.oldString, !old.isEmpty { append(old, kind: .removed) }
        if let new = edit.newString, !new.isEmpty { append(new, kind: .added) }
        if edit.oldString == nil, edit.newString == nil, let content = edit.content, !content.isEmpty {
            append(content, kind: .added)
        }
        return lines
    }

    /// `+12 −3`, with a true minus sign.
    static func editCounters(_ edit: FileEdit) -> String {
        "+\(edit.linesAdded) \u{2212}\(edit.linesRemoved)"
    }

    // MARK: - Cost

    /// Estimated cost of one assistant turn, from its own model's tier.
    static func turnCost(_ message: SessionMessage, pricing: PricingSettings) -> Double {
        guard let model = message.model else { return 0 }
        return pricing.pricing(forModel: model).cost(
            inputTokens: message.inputTokens,
            outputTokens: message.outputTokens,
            cacheCreationTokens: message.cacheCreationTokens,
            cacheReadTokens: message.cacheReadTokens)
    }
}

// MARK: - Shared small views

/// Health grade in a capsule. The popover with the evidence is the caller's job.
struct HealthBadge: View {
    let grade: HealthGrade
    var compact = false

    var body: some View {
        Text(grade.rawValue)
            .font(.system(size: compact ? 9 : 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: compact ? 16 : 20, height: compact ? 16 : 20)
            .background(Circle().fill(SessionsPalette.color(for: grade)))
            .accessibilityLabel("Santé de la session : \(grade.rawValue)")
    }
}

/// Small pill used for filters, tags and counters.
struct SessionChip: View {
    let title: String
    var systemImage: String? = nil
    var active = false
    var tint: Color = Theme.violet
    var action: (() -> Void)? = nil

    var body: some View {
        let content = HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
            }
            Text(title).font(.label(11))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .foregroundStyle(active ? Color.white : Theme.slate)
        .background(Capsule().fill(active ? tint : Theme.cardFill))
        .contentShape(Capsule())

        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .help(title)
        } else {
            content
        }
    }
}

/// Monospaced body in a box that scrolls on its own rather than stretching the turn.
struct MonospacedBox: View {
    let text: String
    var maxHeight: CGFloat = 320
    var tint: Color = Theme.ink

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.data(11))
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: maxHeight)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
