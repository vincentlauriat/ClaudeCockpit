import XCTest
import CockpitShared
@testable import SessionsKit

/// The read side: list filters, full-text search, the edits feed and the activity report.
final class SessionQueriesTests: XCTestCase {

    private var fixture: TranscriptFixture!
    private var service: SessionService!

    override func setUpWithError() throws {
        fixture = try TranscriptFixture()
        service = fixture.service()
    }

    override func tearDown() {
        service = nil
        fixture = nil
    }

    /// Three sessions in two projects, one of them a day earlier and error-free.
    private func writeCorpus() throws {
        try fixture.writeDemoSession()
        let other = "/Users/test/DevApps/Autre"
        try fixture.write([
            Line.user(uuid: "o1", text: "Autre projet, autre sujet : les licornes",
                      at: TestClock.offset(-1440), sessionId: "sess-2", cwd: other),
            Line.assistant(uuid: "o2", at: TestClock.offset(-1439),
                           blocks: [Line.text("Réponse calme et sans erreur.")],
                           messageId: "msg-o2", sessionId: "sess-2", cwd: other),
            Line.aiTitle("Session paisible", sessionId: "sess-2"),
        ], to: "-Users-test-DevApps-Autre/sess-2.jsonl")
    }

    private func indexCorpus() async throws {
        try writeCorpus()
        try await service.index()
    }

    // MARK: - Listing

    func testListsSessionsNewestFirstAndHidesSubagents() async throws {
        try await indexCorpus()
        let sessions = try await service.listSessions(SessionFilter())
        XCTAssertEqual(sessions.map(\.id), [Line.session, "sess-2"])
        XCTAssertFalse(sessions.contains { $0.isSubagent })

        var withAgents = SessionFilter()
        withAgents.includeSubagents = true
        let all = try await service.listSessions(withAgents)
        XCTAssertTrue(all.contains { $0.id == Line.agentId })
    }

    func testFiltersByProjectPeriodStarsAndErrors() async throws {
        try await indexCorpus()

        var byProject = SessionFilter()
        byProject.projectCwd = "/Users/test/DevApps/Autre"
        await XCTAssertEqualAsync(try await service.listSessions(byProject).map(\.id), ["sess-2"])

        var byPeriod = SessionFilter()
        byPeriod.since = TestClock.offset(-60)
        await XCTAssertEqualAsync(try await service.listSessions(byPeriod).map(\.id), [Line.session])

        var byErrors = SessionFilter()
        byErrors.withErrorsOnly = true
        await XCTAssertEqualAsync(try await service.listSessions(byErrors).map(\.id), [Line.session])

        var starred = SessionFilter()
        starred.starredOnly = true
        await XCTAssertEqualAsync(try await service.listSessions(starred), [])
        try await service.setStarred(true, sessionId: "sess-2")
        await XCTAssertEqualAsync(try await service.listSessions(starred).map(\.id), ["sess-2"])
    }

    func testPagesWithLimitAndOffset() async throws {
        try await indexCorpus()
        var page = SessionFilter()
        page.limit = 1
        await XCTAssertEqualAsync(try await service.listSessions(page).map(\.id), [Line.session])
        page.offset = 1
        await XCTAssertEqualAsync(try await service.listSessions(page).map(\.id), ["sess-2"])
    }

    func testStarRenameAndHide() async throws {
        try await indexCorpus()

        try await service.rename(sessionId: "sess-2", customName: "Nom choisi")
        await XCTAssertEqualAsync(try await service.session(id: "sess-2")?.title, "Nom choisi")
        // Clearing the custom name falls back to the ai-title.
        try await service.rename(sessionId: "sess-2", customName: "   ")
        await XCTAssertEqualAsync(try await service.session(id: "sess-2")?.title, "Session paisible")

        try await service.hide(sessionId: "sess-2")
        await XCTAssertEqualAsync(try await service.listSessions(SessionFilter()).map(\.id), [Line.session])
        await XCTAssertNotNilAsync(try await service.session(id: "sess-2"),
                        "masquer n'efface rien, la session reste accessible par son identifiant")
    }

    func testTitleFallsBackFromCustomNameToIdPrefix() async throws {
        // No ai-title, no slug: the first prompt becomes the title.
        try fixture.write([
            Line.user(uuid: "t1", text: "Une première demande très claire",
                      at: TestClock.offset(0), sessionId: "sess-t"),
        ], to: "\(Line.project)/sess-t.jsonl")
        try await service.index()
        // The fixture always writes a slug, which outranks the first prompt.
        await XCTAssertEqualAsync(try await service.session(id: "sess-t")?.title, "demo-slug")
    }

    // MARK: - Search

    func testSearchReturnsSnippetsAroundTheMatch() async throws {
        try await indexCorpus()
        let hits = try await service.search("licornes", filter: SessionFilter())
        XCTAssertEqual(hits.count, 1)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.sessionId, "sess-2")
        XCTAssertEqual(hit.messageId, "o1")
        XCTAssertTrue(hit.snippet.contains("«"), hit.snippet)
        XCTAssertTrue(hit.snippet.lowercased().contains("licornes"), hit.snippet)
        XCTAssertEqual(hit.id, hit.messageId)
    }

    func testSearchReachesInsideToolOutput() async throws {
        try await indexCorpus()
        let hits = try await service.search("drwxr", filter: SessionFilter())
        XCTAssertEqual(hits.map(\.sessionId), [Line.session])
    }

    /// The corpus is French, so a search typed without accents has to find the accented text.
    func testSearchIgnoresDiacritics() async throws {
        try await indexCorpus()
        await XCTAssertEqualAsync(try await service.search("echoue", filter: SessionFilter()).count, 1)
        await XCTAssertEqualAsync(try await service.search("échoué", filter: SessionFilter()).count, 1)
    }

    /// FTS5 treats quotes, `AND` and `*` as syntax; typed into the search field they are text.
    func testSearchSurvivesOperatorsAndQuotesInTheQuery() async throws {
        try await indexCorpus()
        // A throw here fails the test: these are exactly the inputs that break a raw MATCH.
        _ = try await service.search("\"unbalanced", filter: SessionFilter())
        _ = try await service.search("AND OR NEAR", filter: SessionFilter())
        _ = try await service.search("a: b- c*d (e)", filter: SessionFilter())
        await XCTAssertEqualAsync(try await service.search("   ", filter: SessionFilter()), [])
        // A trailing star stays a prefix search, the one operator worth exposing.
        await XCTAssertEqualAsync(try await service.search("licorn*", filter: SessionFilter()).count, 1)
    }

    func testSearchHonoursTheListFilters() async throws {
        try await indexCorpus()
        var filter = SessionFilter()
        filter.projectCwd = "/Users/test/DevApps/Demo"
        await XCTAssertEqualAsync(try await service.search("licornes", filter: filter), [])
    }

    func testListSessionsNarrowsToFullTextMatches() async throws {
        try await indexCorpus()
        var filter = SessionFilter()
        filter.query = "licornes"
        await XCTAssertEqualAsync(try await service.listSessions(filter).map(\.id), ["sess-2"])
    }

    // MARK: - Projects and edits

    func testProjectsAreGroupedByWorkingDirectory() async throws {
        try await indexCorpus()
        let projects = try await service.projects()
        XCTAssertEqual(projects.map(\.cwd), ["/Users/test/DevApps/Demo", "/Users/test/DevApps/Autre"])
        XCTAssertEqual(projects.first?.sessions, 1)
    }

    func testRecentEditsAreNewestFirstAndScopedToAProject() async throws {
        try await indexCorpus()
        let edits = try await service.recentEdits()
        XCTAssertEqual(edits.map(\.tool), ["Write", "Edit"])
        XCTAssertEqual(edits.first?.path, "/Users/test/DevApps/Demo/Notes.md")
        XCTAssertEqual(edits.first?.linesAdded, 3)
        XCTAssertEqual(edits.last?.linesRemoved, 2)
        XCTAssertTrue(edits.first!.timestamp > edits.last!.timestamp)

        await XCTAssertEqualAsync(
            try await service.recentEdits(projectCwd: "/Users/test/DevApps/Autre"), [])
        await XCTAssertEqualAsync(try await service.recentEdits(limit: 1).count, 1)
    }

    // MARK: - Activity

    func testActivityBucketsTurnsByWeekdayAndHour() async throws {
        try await indexCorpus()
        let report = try await service.activity(
            since: TestClock.offset(-2880), until: TestClock.offset(2880),
            calendar: TestClock.calendar)

        // 2026-09-23 is a Wednesday: weekday 4 with a Sunday-first calendar.
        // Seven assistant turns that day: the six of the demo session plus the one its
        // sub-agent ran. Sub-agent turns are real work, so activity counts them; `sessions`
        // counts only the transcripts Vincent actually started.
        let wednesday = report.buckets.first { $0.weekday == 4 && $0.hour == 10 }
        XCTAssertEqual(wednesday?.assistantTurns, 7)
        XCTAssertEqual(report.turns, 8, "sept tours le mercredi, un la veille")
        XCTAssertEqual(report.sessions, 2, "les sous-agents ne comptent pas comme des sessions")
        XCTAssertEqual(report.costUSD, 1.2345, accuracy: 0.0001)

        let mix = try XCTUnwrap(report.tools.first { $0.id == "Bash" })
        XCTAssertEqual(mix.calls, 2)
        XCTAssertEqual(mix.errors, 1)
        XCTAssertEqual(mix.errorRate, 0.5, accuracy: 0.001)
        XCTAssertEqual(report.toolCalls, 5)
        XCTAssertEqual(report.models.first?.model, "claude-opus-5")

        // Every day of the range is present, including the empty ones.
        XCTAssertTrue(report.days.contains { $0.id == "2026-09-23" && $0.turns == 7 })
        XCTAssertTrue(report.days.contains { $0.turns == 0 })
        XCTAssertEqual(report.days.first { $0.id == "2026-09-23" }?.costUSD ?? 0, 1.2345, accuracy: 0.0001)
    }

    func testActivityCanBeScopedToOneProject() async throws {
        try await indexCorpus()
        let report = try await service.activity(
            since: TestClock.offset(-2880), until: TestClock.offset(2880),
            projectCwd: "/Users/test/DevApps/Autre", calendar: TestClock.calendar)
        XCTAssertEqual(report.turns, 1)
        XCTAssertEqual(report.sessions, 1)
        XCTAssertEqual(report.tools, [])
    }

    // MARK: - Paging messages

    func testMessagesPageAndCanIncludeSystemLines() async throws {
        try await indexCorpus()
        let total = try await service.messageCount(sessionId: Line.session)
        XCTAssertGreaterThan(total, 10)

        // System bookkeeping is out by default; the compaction marker stays, and everything
        // comes back with the toggle on.
        let readable = try await service.messages(sessionId: Line.session, limit: 500)
        XCTAssertFalse(readable.contains { $0.role == .system && !$0.isCompactBoundary })
        XCTAssertTrue(readable.contains { $0.isCompactBoundary })

        let firstPage = try await service.messages(sessionId: Line.session, offset: 0, limit: 3)
        XCTAssertEqual(firstPage.map(\.id), ["u1", "a1", "u2"])
        XCTAssertEqual(firstPage.map(\.sequence), [0, 1, 2])

        let secondPage = try await service.messages(sessionId: Line.session, offset: 3, limit: 3)
        XCTAssertEqual(secondPage.first?.id, "a2")

        try fixture.write([
            Line.user(uuid: "m1", text: "visible", at: TestClock.offset(0), sessionId: "sess-m"),
            Line.user(uuid: "m2", text: "caché", at: TestClock.offset(1), sessionId: "sess-m", isMeta: true),
        ], to: "\(Line.project)/sess-m.jsonl")
        try await service.index()
        await XCTAssertEqualAsync(try await service.messages(sessionId: "sess-m").map(\.id), ["m1"])
        await XCTAssertEqualAsync(
            try await service.messages(sessionId: "sess-m", includeMeta: true).map(\.id), ["m1", "m2"])
    }
}

/// A session spanning several `IN (…)` batches. What this pins down is the stitching: every
/// message must find its blocks again once the fetch is split across statements.
final class LargeSessionTests: XCTestCase {

    func testLoadsASessionLargerThanOneBoundParameterBatch() async throws {
        let fixture = try TranscriptFixture()
        let count = 1_500
        var lines: [String] = []
        for index in 0..<count {
            lines.append(Line.assistant(
                uuid: "big-\(index)", at: TestClock.offset(index),
                blocks: [Line.text("tour numéro \(index)")],
                messageId: "msg-big-\(index)", sessionId: "sess-big"))
        }
        try fixture.write(lines, to: "\(Line.project)/sess-big.jsonl")

        let service = fixture.service()
        try await service.index()
        await XCTAssertEqualAsync(try await service.messageCount(sessionId: "sess-big"), count)

        let messages = try await service.messages(sessionId: "sess-big", limit: count + 10)
        XCTAssertEqual(messages.count, count)
        XCTAssertGreaterThan(count, SessionStore.inClauseChunk * 3,
                             "le corpus de test doit couvrir plusieurs lots")
        XCTAssertTrue(messages.allSatisfy { $0.blocks.count == 1 },
                      "chaque message doit retrouver son bloc, quel que soit le découpage")
        XCTAssertEqual(messages.first?.blocks.first?.text, "tour numéro 0")
        XCTAssertEqual(messages.last?.blocks.first?.text, "tour numéro \(count - 1)")

        // Health reads the whole session in one go; this is where the limit bites.
        let health = try await service.health(sessionId: "sess-big")
        XCTAssertEqual(health.grade, .a)
    }
}
