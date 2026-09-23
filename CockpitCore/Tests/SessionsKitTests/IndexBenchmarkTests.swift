import XCTest
import CockpitShared
@testable import SessionsKit

/// Measures a full index of the real corpus under `~/.claude/projects`.
///
/// Off by default — it reads close to a gigabyte and takes minutes, which has no place in a
/// routine `swift test`. Run it deliberately:
///
/// ```
/// SESSIONSKIT_BENCH=1 swift test --filter IndexBenchmarkTests
/// ```
///
/// The transcripts are only ever read; the index is written to a throwaway directory, never
/// to the app's real `sessions.db`.
final class IndexBenchmarkTests: XCTestCase {

    func testFullIndexOfTheRealCorpus() async throws {
        guard ProcessInfo.processInfo.environment["SESSIONSKIT_BENCH"] == "1" else {
            throw XCTSkip("SESSIONSKIT_BENCH=1 pour mesurer l'indexation du corpus réel")
        }

        let paths = ClaudePaths.live
        guard FileManager.default.fileExists(atPath: paths.projectsDir.path) else {
            throw XCTSkip("aucun transcript sous \(paths.projectsDir.path)")
        }

        // `SESSIONSKIT_BENCH_KEEP=<dir>` leaves the index behind so its page usage can be
        // inspected with `sqlite3` afterwards; otherwise it goes to a throwaway directory.
        let keep = ProcessInfo.processInfo.environment["SESSIONSKIT_BENCH_KEEP"]
        let scratch = keep.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("sessionskit-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { if keep == nil { try? FileManager.default.removeItem(at: scratch) } }

        let service = SessionService(
            paths: paths, databaseURL: scratch.appendingPathComponent("sessions.db"))

        let started = Date()
        let progress = try await service.index(full: true)
        let elapsed = Date().timeIntervalSince(started)

        let megabytes = Double(progress.bytesRead) / 1_048_576
        let databaseMB = Double(progress.dbSizeBytes) / 1_048_576
        print("""

            ── Indexation complète du corpus réel ──────────────────────────
            fichiers      : \(progress.filesDone) / \(progress.filesTotal)
            lu            : \(String(format: "%.0f", megabytes)) Mo
            durée         : \(String(format: "%.1f", elapsed)) s
            débit         : \(String(format: "%.1f", megabytes / max(elapsed, 0.001))) Mo/s
            base          : \(String(format: "%.0f", databaseMB)) Mo
            ───────────────────────────────────────────────────────────────

            """)

        // A second pass reads only what Claude Code appended in between. On an idle machine
        // that is zero; on a live one it is the few kilobytes of the sessions still running,
        // so the bar is "a rounding error next to the corpus" rather than "nothing at all".
        // The exact-zero case is covered on fixtures by `testSecondPassReadsNothing`.
        let incrementalStart = Date()
        let second = try await service.index()
        let incremental = Date().timeIntervalSince(incrementalStart)
        print("passe incrémentale : \(String(format: "%.2f", incremental)) s, "
              + "\(second.bytesRead) octets relus")

        try await measureTargetedPass(on: service)
        try await report(on: service)

        XCTAssertGreaterThan(progress.filesDone, 0)
        XCTAssertLessThan(Double(second.bytesRead), Double(progress.bytesRead) / 100,
                          "une passe incrémentale ne doit relire que ce qui a été ajouté")
        XCTAssertLessThan(incremental, 5, "la passe incrémentale doit rester imperceptible")
        XCTAssertLessThan(elapsed, 180, "objectif : moins de 3 minutes sur le corpus complet")
    }

    /// What the watcher's path list buys: a pass that touches one file against one that
    /// re-walks the archive. This is the difference between the two during an active session,
    /// where an event arrives roughly every second.
    private func measureTargetedPass(on service: SessionService) async throws {
        guard let heaviest = try await service.heaviestTranscript(),
              let path = try await service.transcriptURL(sessionId: heaviest.sessionId)?.path
        else { return }

        let targetedStart = Date()
        let targeted = try await service.index(changedPaths: [path])
        let targetedTime = Date().timeIntervalSince(targetedStart)

        let fullStart = Date()
        let full = try await service.index()
        let fullTime = Date().timeIntervalSince(fullStart)

        print("""

            ── Passe ciblée contre passe complète ──────────────────────────
            ciblée   : \(targeted.filesTotal) fichier, \
            \(String(format: "%.0f", targetedTime * 1000)) ms
            complète : \(full.filesTotal) fichiers, \
            \(String(format: "%.0f", fullTime * 1000)) ms
            ───────────────────────────────────────────────────────────────

            """)

        XCTAssertEqual(targeted.filesTotal, 1)
        XCTAssertLessThan(targetedTime, fullTime,
                          "la passe ciblée doit coûter moins qu'un parcours complet")
    }

    /// What the index actually made of the real corpus — the numbers that tell whether the
    /// heuristics (sub-agent linking, titles, tool naming) held up outside the fixtures.
    private func report(on service: SessionService) async throws {
        var everything = SessionFilter()
        everything.limit = 5000
        everything.includeSubagents = true
        let all = try await service.listSessions(everything)
        let subagents = all.filter(\.isSubagent)
        let linked = try await service.linkedSubagentCount()
        let projects = try await service.projects()

        let untitled = all.filter { $0.title.count <= 8 && $0.title.allSatisfy(\.isHexDigit) }
        var recent = SessionFilter()
        recent.limit = 20
        let hits = try await service.search("erreur", filter: recent)

        var grades: [HealthGrade: Int] = [:]
        var longest: (SessionRef, Int)?
        for session in all where !session.isSubagent {
            grades[session.healthGrade, default: 0] += 1
            if session.assistantTurns > (longest?.1 ?? 0) { longest = (session, session.assistantTurns) }
        }
        let distribution = HealthGrade.allCases
            .map { "\($0.rawValue) \(grades[$0] ?? 0)" }.joined(separator: " · ")
        let heaviestTurns = longest.map {
            "\($0.0.assistantTurns) tours → \($0.0.healthGrade.rawValue)"
        } ?? "—"

        let attachments = try await service.attachmentStats()
        let priced = all.filter { !$0.tokensByModel.isEmpty }.count
        let withCost = all.filter { $0.costStateUSD != nil }.count

        let month = try await service.activity(
            since: Date().addingTimeInterval(-30 * 86_400), until: Date())

        print("""

            ── Ce que l'index a compris du corpus ──────────────────────────
            sessions        : \(all.count - subagents.count)
            sous-agents     : \(subagents.count), dont \(linked) reliés à leur appel Agent
            projets         : \(projects.count)
            sans titre      : \(untitled.count) (repli sur le préfixe d'identifiant)
            « erreur »      : \(hits.count) résultats
            30 derniers j.  : \(month.sessions) sessions, \(month.turns) tours, \
            \(month.toolCalls) appels d'outil, \(String(format: "%.2f", month.costUSD)) $
            top outils      : \(month.tools.prefix(5).map { "\($0.id)×\($0.calls)" }.joined(separator: " "))
            notes de santé  : \(distribution)
            la plus longue  : \(heaviestTurns)
            coût connu      : \(withCost) sessions · jetons par modèle : \(priced)
            pièces jointes  : \(attachments.files) fichiers sur \
            \(attachments.withAttachment) tours « Vous » (sur \(attachments.userTurnsWithText) avec du texte)
            bulles vides    : \(attachments.bareBubbles) (une pièce jointe et rien d'autre)
            ───────────────────────────────────────────────────────────────

            """)

        try await measurePaging(on: service)

        XCTAssertGreaterThan(all.count, 0)
        XCTAssertGreaterThan(projects.count, 0)
        XCTAssertFalse(month.tools.isEmpty, "le nom d'outil doit remonter sur du vrai corpus")
        XCTAssertLessThan(attachments.withAttachment, attachments.userTurnsWithText / 4,
                          "une pièce jointe doit rester l'exception, pas la règle")
        XCTAssertEqual(attachments.bareBubbles, 0,
                       "aucune bulle « Vous » ne doit se réduire à une pièce jointe")
        XCTAssertGreaterThan(priced, withCost * 2,
                             "les jetons par modèle doivent couvrir bien plus que cost-state")
        if let longest {
            XCTAssertNotEqual(longest.0.healthGrade, .f,
                              "la plus longue session ne doit pas être notée F pour sa longueur")
        }
    }

    /// Reading a page of the heaviest session there is. This is the number that decides how
    /// short the view has to paginate.
    private func measurePaging(on service: SessionService) async throws {
        // The biggest transcript on disk, not the one with the most messages: the lazy
        // re-read of capped bodies is what this measures, and that is bounded by bytes.
        guard let heaviest = try await service.heaviestTranscript() else { return }
        let session = heaviest.sessionId
        let total = try await service.messageCount(sessionId: session)
        let started = Date()
        let page = try await service.messages(sessionId: session, offset: 0, limit: 400)
        let firstPage = Date().timeIntervalSince(started)

        let middle = Date()
        _ = try await service.messages(
            sessionId: session, offset: max(0, total / 2), limit: 400)
        let midPage = Date().timeIntervalSince(middle)

        let graded = Date()
        _ = try await service.health(sessionId: session)
        let health = Date().timeIntervalSince(graded)

        print("""

            ── Pagination sur la session la plus lourde ────────────────────
            session       : \(session)
            transcript    : \(heaviest.bytes / 1_048_576) Mo, \(total) messages visibles
            page 1 (400)  : \(String(format: "%.0f", firstPage * 1000)) ms \
            (\(page.flatMap(\.blocks).filter(\.isTruncated).count) blocs relus)
            page milieu   : \(String(format: "%.0f", midPage * 1000)) ms
            note de santé : \(String(format: "%.1f", health * 1000)) ms
            ───────────────────────────────────────────────────────────────

            """)

        // The worst case for the lazy re-read: the session with the most capped blocks.
        var relecture = "aucun bloc tronqué dans le corpus"
        if let worst = try await service.mostTruncatedSession() {
            let started = Date()
            let page = try await service.messages(
                sessionId: worst.sessionId, offset: 0, limit: 400)
            let elapsed = Date().timeIntervalSince(started)
            let restored = page.flatMap(\.blocks).filter { $0.text.utf8.count > ContentBlock.storedBodyCap }
            relecture = "\(worst.blocks) blocs tronqués, page en "
                + "\(String(format: "%.0f", elapsed * 1000)) ms, \(restored.count) relus"
            XCTAssertLessThan(elapsed, 1.0, "même avec relecture, une page reste sous la seconde")
        }
        print("relecture paresseuse : \(relecture)\n")

        XCTAssertLessThan(firstPage, 1.0, "une page de 400 messages doit rester sous la seconde")
        XCTAssertLessThan(health, 0.05, "la note de santé ne doit lire aucun transcript")
    }
}


