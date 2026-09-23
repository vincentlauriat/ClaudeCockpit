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

        try await report(on: service)

        XCTAssertGreaterThan(progress.filesDone, 0)
        XCTAssertLessThan(Double(second.bytesRead), Double(progress.bytesRead) / 100,
                          "une passe incrémentale ne doit relire que ce qui a été ajouté")
        XCTAssertLessThan(incremental, 5, "la passe incrémentale doit rester imperceptible")
        XCTAssertLessThan(elapsed, 180, "objectif : moins de 3 minutes sur le corpus complet")
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
            ───────────────────────────────────────────────────────────────

            """)

        XCTAssertGreaterThan(all.count, 0)
        XCTAssertGreaterThan(projects.count, 0)
        XCTAssertFalse(month.tools.isEmpty, "le nom d'outil doit remonter sur du vrai corpus")
    }
}

