// SessionsKit — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import Foundation
import CockpitShared

extension SessionHealthRule {

    /// What each kind of trouble costs, out of a starting score of 100.
    ///
    /// Errors are weighed as **rates**, not counts. Measured on the real corpus, the error
    /// rate barely moves with session length — 3,9 % on short sessions, 2,9 % on long ones —
    /// while the raw count grows with it. Scoring the count therefore graded duration rather
    /// than health: a 1 281-turn session that shipped a release came out F while an 8-turn
    /// session came out A.
    enum Penalty {
        /// Tool errors below this rate cost nothing: a few failures are how a tool gets used.
        static let toolErrorFloor = 0.02
        /// Slope past the floor — 5 % costs about 12 points, 10 % costs the cap.
        static let toolErrorSlope = 400.0
        static let toolErrorCap = 30.0
        /// A second ceiling, in points per failure, so a rate measured on a handful of calls
        /// cannot dominate the grade: one failure out of three is not a 33 % error rate, it is
        /// a sample too small for a rate to exist.
        ///
        /// This is deliberately in tension with "same rate, same grade". That invariant was a
        /// means to "the grade reflects health, not length", and it only holds where a rate is
        /// measurable — past roughly eighty calls at 5 %, where the slope takes over from this
        /// ceiling. Below that the ceiling governs, on purpose. Do not remove it thinking it
        /// an oversight.
        static let pointsPerToolError = 3.0

        /// API errors are rarer and worse, so the slope is steep: 0,5 % costs 5, 2,5 % caps.
        static let apiErrorSlope = 1000.0
        static let apiErrorCap = 25.0

        static let endedOnError = 15
        /// One interrupted turn is ordinary; a habit of interrupting is not.
        static let aborted = 5
        static let abortedShare = 0.02
        static let abortedExtra = 5

        static let repeatedFailure = 10
        /// A call has to fail this many times in a row before it counts as a loop.
        static let repeatThreshold = 3
    }

    /// Grades one session from counters the indexer already holds — no model, no network, no
    /// transcript read, and the same answer every time.
    ///
    /// Taking counters rather than messages is what lets the list show a badge per row: a
    /// grade computed from the transcript would mean materialising every session on screen,
    /// which is exactly the greedy read the spec rules out.
    ///
    /// Evidence is written in French and cites the rate next to the count, so the sentence
    /// explains the grade instead of seeming to contradict it.
    static func evaluateCounters(_ counters: SessionHealthCounters) -> SessionHealth {
        var score = 100.0
        var evidence: [String] = []

        // A session that called no tool has no tool error rate to speak of; dividing by a
        // floor of 1 would invent one out of nothing.
        if counters.toolCalls > 0, counters.toolErrors > 0 {
            let rate = Double(counters.toolErrors) / Double(counters.toolCalls)
            let byRate = min(Penalty.toolErrorCap,
                             max(0, (rate - Penalty.toolErrorFloor) * Penalty.toolErrorSlope))
            let byCount = Penalty.pointsPerToolError * Double(counters.toolErrors)
            score -= min(byRate, byCount)
            evidence.append("""
                \(FRFormat.plural(counters.toolErrors, "erreur")) d'outil sur \
                \(FRFormat.plural(counters.toolCalls, "appel")), soit \
                \(FRFormat.percent(rate, digits: 1)).
                """)
        }

        if counters.apiErrors > 0 {
            let turns = max(counters.assistantTurns, counters.apiErrors)
            let rate = Double(counters.apiErrors) / Double(turns)
            score -= min(Penalty.apiErrorCap, rate * Penalty.apiErrorSlope)
            evidence.append("""
                \(FRFormat.plural(counters.apiErrors, "erreur")) d'API sur \
                \(FRFormat.plural(turns, "tour")) assistant, soit \
                \(FRFormat.percent(rate, digits: 1)).
                """)
        }

        if counters.endedOnError {
            score -= Double(Penalty.endedOnError)
            evidence.append("La session se termine sur une erreur.")
        }

        if counters.abortedTurns > 0 {
            let turns = max(counters.assistantTurns, counters.abortedTurns)
            let share = Double(counters.abortedTurns) / Double(turns)
            score -= Double(Penalty.aborted)
            if share > Penalty.abortedShare { score -= Double(Penalty.abortedExtra) }
            let word = counters.abortedTurns > 1 ? "interrompus" : "interrompu"
            evidence.append("""
                \(FRFormat.plural(counters.abortedTurns, "tour")) \(word) sur \
                \(FRFormat.plural(turns, "tour")) assistant.
                """)
        }

        if counters.repeatedFailures >= Penalty.repeatThreshold {
            score -= Double(Penalty.repeatedFailure)
            evidence.append(
                "Le même appel d'outil a échoué \(counters.repeatedFailures) fois de suite.")
        }

        if evidence.isEmpty { evidence.append("Aucune erreur détectée.") }
        let clamped = min(100, max(0, Int(score.rounded())))
        return SessionHealth(grade: grade(for: clamped), score: clamped, evidence: evidence)
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

    // MARK: - Counting, for the indexer

    /// The identity of a tool call: its name and its input. Two failures count as a repeat
    /// only when both match, so `Bash` failing on two different commands is not a loop while
    /// the same command failing four times is.
    ///
    /// Hashed with FNV-1a rather than `Hasher`, whose seed changes between processes: this
    /// value is written to the database and compared against what a later run computes.
    static func identityHash(toolName: String?, input: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ bytes: some Sequence<UInt8>) {
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        mix((toolName ?? "?").utf8)
        mix(CollectionOfOne(UInt8(0)))
        // A prefix is enough to tell two calls apart and keeps the cost off the hot path.
        mix(input.utf8.prefix(identityPrefix))
        return Int64(bitPattern: hash)
    }

    static let identityPrefix = 4096

    /// Tracks the current run of identical consecutive failures while a transcript is read.
    ///
    /// A transcript arrives in chunks, possibly across launches of the app, so the run in
    /// progress is stored next to the longest one seen and resumed on the following pass.
    struct FailureRun: Equatable {
        var longest = 0
        var current = 0
        var key: Int64?

        /// - Parameters:
        ///   - failed: whether this tool result is an error.
        ///   - identity: the identity of the call it answers, `nil` when it cannot be paired.
        mutating func record(failed: Bool, identity: Int64?) {
            guard failed, let identity else {
                current = 0
                key = nil
                return
            }
            current = (identity == key) ? current + 1 : 1
            key = identity
            longest = max(longest, current)
        }
    }
}
