import XCTest
import CockpitShared
@testable import SessionsKit

/// Guarantees the interface relies on and cannot check for itself: the order rows come back
/// in, when `lastRun` is allowed to move, and how a search hit is turned into a page.
final class ContractTests: XCTestCase {

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

    /// Three sessions an hour apart, plus one edit and one searchable word each.
    private func writeThreeSessions() throws {
        for (index, minutes) in [0, 60, 120].enumerated() {
            let id = "sess-\(index)"
            try fixture.write([
                Line.user(uuid: "\(id)-u", text: "licorne numéro \(index)",
                          at: TestClock.offset(minutes), sessionId: id),
                Line.assistant(uuid: "\(id)-a", at: TestClock.offset(minutes + 1), blocks: [
                    Line.toolUse(id: "\(id)-t", name: "Write", input: [
                        "file_path": "/Users/test/DevApps/Demo/f\(index).md",
                        "content": "ligne",
                    ]),
                ], messageId: "msg-\(id)", sessionId: id),
            ], to: "\(Line.project)/\(id).jsonl")
        }
    }

    // MARK: - Ordering

    /// The day-grouped list and the "Sessions aujourd'hui" card both read the first page, so
    /// an ascending or arbitrary order would silently drop today's sessions off it.
    func testListSessionsIsNewestFirstAndPagesThatOrder() async throws {
        try writeThreeSessions()
        try await service.index()

        var filter = SessionFilter()
        let all = try await service.listSessions(filter)
        XCTAssertEqual(all.map(\.id), ["sess-2", "sess-1", "sess-0"])
        XCTAssertEqual(all.map(\.lastTimestamp), all.map(\.lastTimestamp).sorted(by: >))

        filter.offset = 1
        await XCTAssertEqualAsync(try await service.listSessions(filter).map(\.id),
                                  ["sess-1", "sess-0"],
                                  "offset: 1 doit sauter la plus récente")
        filter.offset = 0
        filter.limit = 2
        await XCTAssertEqualAsync(try await service.listSessions(filter).map(\.id),
                                  ["sess-2", "sess-1"])
    }

    func testRecentEditsAreNewestFirst() async throws {
        try writeThreeSessions()
        try await service.index()
        let edits = try await service.recentEdits()
        XCTAssertEqual(edits.map(\.sessionId), ["sess-2", "sess-1", "sess-0"])
        XCTAssertEqual(edits.map(\.timestamp), edits.map(\.timestamp).sorted(by: >))
    }

    func testSearchHitsAreNewestFirst() async throws {
        try writeThreeSessions()
        try await service.index()
        let hits = try await service.search("licorne", filter: SessionFilter())
        XCTAssertEqual(hits.map(\.sessionId), ["sess-2", "sess-1", "sess-0"])
        XCTAssertEqual(hits.map(\.timestamp), hits.map(\.timestamp).sorted(by: >))
    }

    // MARK: - Progress

    /// Three views key their reload on `lastRun`. Publishing it mid-pass would make all of
    /// them re-query once per indexed file, exactly while the machine is busiest.
    func testLastRunOnlyMovesWhenAPassCompletes() async throws {
        try writeThreeSessions()
        let collected = ProgressLog()

        let first = try await service.index { collected.append($0) }
        let during = collected.steps.filter(\.isRunning)
        XCTAssertGreaterThanOrEqual(during.count, 3, "une étape par fichier au moins")
        XCTAssertTrue(during.allSatisfy { $0.lastRun == nil },
                      "lastRun doit rester à sa valeur d'avant la passe pendant la passe")
        XCTAssertEqual(during.map(\.filesDone), during.map(\.filesDone).sorted())
        XCTAssertNotNil(first.lastRun)
        XCTAssertFalse(first.isRunning)

        // On the pass after, the intermediate steps carry the *previous* run's date, unchanged.
        try fixture.write([
            Line.user(uuid: "later-u", text: "encore", at: TestClock.offset(300),
                      sessionId: "sess-later"),
        ], to: "\(Line.project)/sess-later.jsonl")

        let second = ProgressLog()
        let final = try await service.index { second.append($0) }
        let running = second.steps.filter(\.isRunning)
        XCTAssertFalse(running.isEmpty)
        XCTAssertTrue(running.allSatisfy { $0.lastRun == first.lastRun })
        XCTAssertNotNil(final.lastRun)
        XCTAssertGreaterThan(final.lastRun!, first.lastRun!)
    }

    // MARK: - Reaching a message

    func testMessageIndexLocatesASearchHitInItsPage() async throws {
        try fixture.writeDemoSession()
        try await service.index()

        let messages = try await service.messages(sessionId: Line.session, limit: 500)
        for (rank, message) in messages.enumerated() {
            let found = try await service.messageIndex(
                sessionId: Line.session, messageId: message.id)
            XCTAssertEqual(found, rank, message.id)
        }

        // A hit found by search can be paged to directly.
        let hits = try await service.search("drwxr", filter: SessionFilter())
        let hit = try XCTUnwrap(hits.first)
        let located = try await service.messageIndex(
            sessionId: hit.sessionId, messageId: hit.messageId)
        let rank = try XCTUnwrap(located)
        let page = try await service.messages(
            sessionId: hit.sessionId, offset: rank, limit: 1)
        XCTAssertEqual(page.first?.id, hit.messageId)
    }

    func testMessageIndexRespectsVisibility() async throws {
        try fixture.writeDemoSession()
        try await service.index()

        // A system line is out of the readable transcript, and in with the toggle on.
        await XCTAssertNilAsync(
            try await service.messageIndex(sessionId: Line.session, messageId: "s0"))
        await XCTAssertNotNilAsync(try await service.messageIndex(
            sessionId: Line.session, messageId: "s0", includeMeta: true))
        await XCTAssertNilAsync(try await service.messageIndex(
            sessionId: Line.session, messageId: "jamais-vu"))
    }

    /// The total and the pages have to speak of the same set, or the view cannot say
    /// "message 12 sur 40" without lying.
    func testMessageCountMatchesWhatPagingReturns() async throws {
        try fixture.writeDemoSession()
        try await service.index()

        let visible = try await service.messageCount(sessionId: Line.session)
        await XCTAssertEqualAsync(
            try await service.messages(sessionId: Line.session, limit: 5000).count, visible)

        let everything = try await service.messageCount(
            sessionId: Line.session, includeMeta: true)
        await XCTAssertEqualAsync(try await service.messages(
            sessionId: Line.session, includeMeta: true, limit: 5000).count, everything)
        XCTAssertGreaterThan(everything, visible, "des lignes système existent bien")
    }
}

/// Collects what the indexing callback publishes, from whatever executor it runs on.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [IndexProgress] = []

    var steps: [IndexProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ progress: IndexProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }
}
