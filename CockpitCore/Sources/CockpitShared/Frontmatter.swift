import Foundation

/// Minimal YAML-ish front matter parser for SKILL.md / agent / command files:
/// a leading `---` block of `key: value` lines. Values keep their raw text
/// (quotes stripped). Nested structures are not interpreted.
public struct Frontmatter: Equatable, Sendable {
    public var fields: [String: String]
    public var body: String

    public var name: String? { fields["name"] }
    public var description: String? { fields["description"] }

    public init(fields: [String: String] = [:], body: String = "") {
        self.fields = fields
        self.body = body
    }

    public static func parse(_ text: String) -> Frontmatter {
        let lines = text.components(separatedBy: .newlines)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return Frontmatter(fields: [:], body: text)
        }
        var fields: [String: String] = [:]
        var index = 1
        var currentKey: String?
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces) == "---" { index += 1; break }
            if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if value == ">" || value == "|" || value == ">-" || value == "|-" { value = "" }
                fields[key] = unquote(value)
                currentKey = key
            } else if let key = currentKey {
                // Continuation line (folded/literal block or indented text).
                let extra = line.trimmingCharacters(in: .whitespaces)
                if !extra.isEmpty {
                    let existing = fields[key] ?? ""
                    fields[key] = existing.isEmpty ? extra : existing + " " + extra
                }
            }
            index += 1
        }
        let body = lines[min(index, lines.count)...].joined(separator: "\n")
        return Frontmatter(fields: fields, body: body)
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
