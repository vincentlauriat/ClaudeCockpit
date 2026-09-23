// SessionsKit — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import Foundation

extension SessionExporter {

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return formatter
    }()

    static func header(_ session: SessionRef) -> [(String, String)] {
        var fields: [(String, String)] = [
            ("Projet", session.cwd.isEmpty ? session.projectDir : session.cwd),
            ("Début", dateFormatter.string(from: session.firstTimestamp)),
            ("Durée", duration(session.duration)),
            ("Tours", "\(session.userTurns) utilisateur · \(session.assistantTurns) assistant"),
            ("Outils", "\(session.toolCalls) appels · \(session.toolErrors) en erreur"),
            ("Jetons", "\(session.totalTokens)"),
        ]
        if let branch = session.gitBranch { fields.append(("Branche", branch)) }
        if let version = session.claudeVersion { fields.append(("Claude Code", version)) }
        if let cost = session.costStateUSD {
            fields.append(("Coût", String(format: "%.4f $", cost)))
        }
        if session.linesAdded > 0 || session.linesRemoved > 0 {
            fields.append(("Lignes", "+\(session.linesAdded) / −\(session.linesRemoved)"))
        }
        return fields
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) h \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(total) s"
    }

    static func roleLabel(_ message: SessionMessage) -> String {
        switch message.role {
        case .user: return "Utilisateur"
        case .assistant: return "Assistant"
        case .system: return "Système"
        }
    }

    // MARK: - Markdown

    static func renderMarkdown(
        session: SessionRef, messages: [SessionMessage], subagents: [String: [SessionMessage]]
    ) -> String {
        var out = "# \(session.title)\n\n"
        for (label, value) in header(session) { out += "- **\(label)** : \(value)\n" }
        if !session.prLinks.isEmpty {
            out += "- **Pull requests** : "
            out += session.prLinks.map { "[#\($0.number)](\($0.url.absoluteString))" }
                .joined(separator: ", ") + "\n"
        }
        out += "\n"

        for message in messages {
            out += markdownTurn(message, subagents: subagents, depth: 0)
        }
        return out
    }

    private static func markdownTurn(
        _ message: SessionMessage, subagents: [String: [SessionMessage]], depth: Int
    ) -> String {
        let hashes = String(repeating: "#", count: min(6, depth + 2))
        var out = "\(hashes) \(roleLabel(message)) — \(dateFormatter.string(from: message.timestamp))"
        if let model = message.model { out += " · \(model)" }
        out += "\n\n"

        if message.isCompactBoundary { out += "> Contexte compacté\n\n" }
        if message.isApiError { out += "> ⚠︎ Erreur d'API\n\n" }
        if message.isAborted { out += "> ⚠︎ Tour interrompu\n\n" }

        for block in message.blocks {
            switch block.kind {
            case .text:
                out += block.text + "\n\n"
            case .thinking:
                out += "<details><summary>Réflexion</summary>\n\n```\n\(block.text)\n```\n\n</details>\n\n"
            case .toolUse:
                out += "**Outil : \(block.toolName ?? "?")**\n\n```json\n\(block.text)\n```\n\n"
                if let agentId = block.subagentId, let transcript = subagents[agentId] {
                    out += "<details><summary>Sous-agent \(agentId)</summary>\n\n"
                    for sub in transcript { out += markdownTurn(sub, subagents: [:], depth: depth + 1) }
                    out += "</details>\n\n"
                }
            case .toolResult:
                let label = block.isError ? "Résultat (erreur)" : "Résultat"
                out += "<details><summary>\(label)</summary>\n\n```\n\(block.text)\n```\n\n</details>\n\n"
            case .image:
                out += "_[image \(block.imageMediaType ?? "")]_\n\n"
            }
        }
        if message.attachmentCount > 0 {
            out += "_\(message.attachmentCount) pièce(s) jointe(s) masquée(s)._\n\n"
        }
        return out
    }

    // MARK: - HTML

    /// Self-contained: inline stylesheet, no script, no external asset. Everything that came
    /// out of a transcript is escaped before it reaches the page.
    static func renderHTML(
        session: SessionRef, messages: [SessionMessage], subagents: [String: [SessionMessage]]
    ) -> String {
        var out = """
            <!DOCTYPE html>
            <html lang="fr"><head><meta charset="utf-8">
            <title>\(escape(session.title))</title>
            <style>
            :root { color-scheme: light dark; }
            body { font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                   margin: 0 auto; padding: 24px; max-width: 900px; }
            h1 { font-size: 22px; margin: 0 0 12px; }
            dl.meta { display: grid; grid-template-columns: max-content 1fr; gap: 2px 12px;
                      margin: 0 0 28px; font-size: 13px; }
            dt { font-weight: 600; opacity: .7; }
            dd { margin: 0; }
            section.turn { border-top: 1px solid rgba(128,128,128,.28); padding: 14px 0; }
            section.turn > h2 { font-size: 13px; margin: 0 0 8px; text-transform: uppercase;
                                letter-spacing: .04em; opacity: .65; }
            section.user > h2 { color: #2f6fb3; }
            section.assistant > h2 { color: #8a5a00; }
            p.flag { margin: 0 0 10px; padding: 6px 10px; border-radius: 6px;
                     background: rgba(200,60,60,.14); font-size: 13px; }
            p.compact { background: rgba(120,120,120,.16); }
            pre { background: rgba(128,128,128,.12); padding: 10px 12px; border-radius: 6px;
                  overflow-x: auto; font-size: 12.5px; }
            details { margin: 8px 0; }
            summary { cursor: pointer; font-size: 13px; opacity: .8; }
            details.error > summary { color: #c0392b; }
            div.text { white-space: pre-wrap; }
            div.sub { border-left: 3px solid rgba(128,128,128,.4); padding-left: 14px; margin-left: 2px; }
            </style></head><body>
            <h1>\(escape(session.title))</h1>
            <dl class="meta">
            """
        for (label, value) in header(session) {
            out += "<dt>\(escape(label))</dt><dd>\(escape(value))</dd>"
        }
        for link in session.prLinks {
            out += "<dt>PR</dt><dd><a href=\"\(escape(link.url.absoluteString))\">#\(link.number)</a></dd>"
        }
        out += "</dl>\n"

        for message in messages { out += htmlTurn(message, subagents: subagents) }
        out += "</body></html>\n"
        return out
    }

    private static func htmlTurn(
        _ message: SessionMessage, subagents: [String: [SessionMessage]]
    ) -> String {
        var out = "<section class=\"turn \(message.role.rawValue)\"><h2>\(roleLabel(message)) — "
        out += "\(escape(dateFormatter.string(from: message.timestamp)))"
        if let model = message.model { out += " · \(escape(model))" }
        out += "</h2>\n"

        if message.isCompactBoundary { out += "<p class=\"flag compact\">Contexte compacté</p>" }
        if message.isApiError { out += "<p class=\"flag\">Erreur d'API</p>" }
        if message.isAborted { out += "<p class=\"flag\">Tour interrompu</p>" }

        for block in message.blocks {
            switch block.kind {
            case .text:
                out += "<div class=\"text\">\(escape(block.text))</div>"
            case .thinking:
                out += "<details><summary>Réflexion</summary><pre>\(escape(block.text))</pre></details>"
            case .toolUse:
                let name = escape(block.toolName ?? "?")
                out += "<details><summary>Outil : \(name)</summary><pre>\(escape(block.text))</pre>"
                if let agentId = block.subagentId, let transcript = subagents[agentId] {
                    out += "<div class=\"sub\"><p><strong>Sous-agent \(escape(agentId))</strong></p>"
                    for sub in transcript { out += htmlTurn(sub, subagents: [:]) }
                    out += "</div>"
                }
                out += "</details>"
            case .toolResult:
                let label = block.isError ? "Résultat (erreur)" : "Résultat"
                out += "<details class=\"\(block.isError ? "error" : "")\">"
                out += "<summary>\(label)</summary><pre>\(escape(block.text))</pre></details>"
            case .image:
                out += "<p><em>[image \(escape(block.imageMediaType ?? ""))]</em></p>"
            }
        }
        if message.attachmentCount > 0 {
            out += "<p><em>\(message.attachmentCount) pièce(s) jointe(s) masquée(s).</em></p>"
        }
        return out + "</section>\n"
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}
