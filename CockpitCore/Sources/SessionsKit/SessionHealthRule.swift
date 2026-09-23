// SessionsKit — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import Foundation

extension SessionHealthRule {

    /// How much each kind of trouble costs, out of a starting score of 100.
    enum Penalty {
        static let apiError = 15
        static let endedOnError = 10
        static let toolError = 3
        static let toolErrorCap = 30
        static let aborted = 10
        static let repeatedFailure = 10
        /// A call has to fail this many times in a row before it counts as a loop.
        static let repeatThreshold = 3
    }

    /// Grades one session from its messages alone — no model, no network, same answer every time.
    ///
    /// Evidence is written in French, in the order the rules fire, so the popover reads as a
    /// short explanation rather than a list of counters.
    static func evaluateRules(messages: [SessionMessage], session: SessionRef) -> SessionHealth {
        var score = 100
        var evidence: [String] = []

        let apiErrors = messages.filter(\.isApiError).count
        if apiErrors > 0 {
            score -= Penalty.apiError * apiErrors
            evidence.append(apiErrors == 1
                ? "Une erreur d'API pendant la session."
                : "\(apiErrors) erreurs d'API pendant la session.")
        }

        let toolErrors = messages.reduce(0) { total, message in
            total + message.blocks.filter { $0.kind == .toolResult && $0.isError }.count
        }
        if toolErrors > 0 {
            score -= min(Penalty.toolErrorCap, Penalty.toolError * toolErrors)
            let calls = session.toolCalls > 0 ? session.toolCalls : toolErrors
            evidence.append("\(toolErrors) appel\(toolErrors > 1 ? "s" : "") d'outil en échec sur \(calls).")
        }

        if let last = messages.last(where: { $0.role == .assistant }), endsBadly(last) {
            score -= Penalty.endedOnError
            evidence.append("La session se termine sur une erreur.")
        }

        let aborted = messages.filter(\.isAborted).count
        if aborted > 0 {
            score -= Penalty.aborted
            evidence.append(aborted == 1
                ? "Un tour a été interrompu."
                : "\(aborted) tours ont été interrompus.")
        }

        let repeats = longestFailureRun(in: messages)
        if repeats >= Penalty.repeatThreshold {
            score -= Penalty.repeatedFailure
            evidence.append("Le même appel d'outil a échoué \(repeats) fois de suite.")
        }

        if evidence.isEmpty { evidence.append("Aucune erreur détectée.") }
        let clamped = min(100, max(0, score))
        return SessionHealth(grade: grade(for: clamped), score: clamped, evidence: evidence)
    }

    /// The closing assistant turn failed: the API itself errored, or its last tool call did.
    private static func endsBadly(_ message: SessionMessage) -> Bool {
        message.isApiError || message.blocks.contains { $0.isError }
    }

    /// The longest run of consecutive tool results that both failed and answered the same
    /// call — the signature of an agent retrying something that cannot work.
    ///
    /// Identity is the tool's name plus its input, so `Bash` failing on two different commands
    /// is not a loop while the same command failing four times is.
    static func longestFailureRun(in messages: [SessionMessage]) -> Int {
        var inputs: [String: String] = [:]  // toolUseId → tool name + input
        for message in messages {
            for block in message.blocks where block.kind == .toolUse {
                guard let toolUseId = block.toolUseId else { continue }
                inputs[toolUseId] = "\(block.toolName ?? "?")\u{1}\(block.text)"
            }
        }

        var longest = 0
        var current = 0
        var previous: String?
        for message in messages {
            for block in message.blocks where block.kind == .toolResult {
                guard block.isError, let toolUseId = block.toolUseId,
                      let identity = inputs[toolUseId]
                else {
                    current = 0
                    previous = nil
                    continue
                }
                current = identity == previous ? current + 1 : 1
                previous = identity
                longest = max(longest, current)
            }
        }
        return longest
    }

    static func grade(for score: Int) -> HealthGrade {
        switch score {
        case 90...: return .a
        case 75..<90: return .b
        case 60..<75: return .c
        case 40..<60: return .d
        default: return .f
        }
    }
}
