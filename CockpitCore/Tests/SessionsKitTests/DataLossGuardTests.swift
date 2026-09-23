import XCTest
import CockpitShared
@testable import SessionsKit

/// Stars, custom names and hidden flags are the only things in this database the user made,
/// and no re-index can bring them back. These tests pin the cases where a pass could take
/// them away.
final class DataLossGuardTests: XCTestCase {

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

    /// Two sessions, one starred and one renamed.
    private func writeAndMark() async throws {
        try fixture.writeDemoSession()
        try fixture.write([
            Line.user(uuid: "k-u", text: "deuxième projet", at: TestClock.offset(30),
                      sessionId: "sess-keep"),
        ], to: "\(Line.project)/sess-keep.jsonl")
        try await service.index()
        try await service.setStarred(true, sessionId: Line.session)
        try await service.rename(sessionId: "sess-keep", customName: "Nom que j'ai tapé")
    }

    /// `TranscriptWalker` returns an empty list both when the archive is genuinely empty and
    /// when the enumerator failed — a missing directory, an unmounted volume, a permission
    /// not granted yet. Reading the second as the first once cost every session row.
    func testAnEmptyWalkNeverDeletesAnything() async throws {
        try await writeAndMark()

        // Make the walk come back empty the way a real failure would: the projects directory
        // is simply not there any more.
        let projects = fixture.paths.projectsDir
        let moved = projects.deletingLastPathComponent().appendingPathComponent("projects-absent")
        try FileManager.default.moveItem(at: projects, to: moved)
        defer { try? FileManager.default.moveItem(at: moved, to: projects) }

        let progress = try await service.index()
        XCTAssertEqual(progress.filesTotal, 0, "le parcours doit bien être vide")

        let starred = try XCTUnwrapAsync(try await service.session(id: Line.session))
        XCTAssertTrue(starred.isStarred, "l'étoile doit survivre à un parcours vide")
        let renamed = try XCTUnwrapAsync(try await service.session(id: "sess-keep"))
        XCTAssertEqual(renamed.customName, "Nom que j'ai tapé")

        var filter = SessionFilter()
        filter.includeSubagents = true
        await XCTAssertEqualAsync(try await service.listSessions(filter).count, 3,
                                  "aucune session ne doit disparaître")
    }

    /// A hidden session is a decision the user made too, and it lives nowhere else.
    func testAnEmptyWalkKeepsHiddenSessionsHidden() async throws {
        try await writeAndMark()
        try await service.hide(sessionId: "sess-keep")

        let projects = fixture.paths.projectsDir
        let moved = projects.deletingLastPathComponent().appendingPathComponent("projects-absent")
        try FileManager.default.moveItem(at: projects, to: moved)
        defer { try? FileManager.default.moveItem(at: moved, to: projects) }
        try await service.index()

        await XCTAssertNotNilAsync(try await service.session(id: "sess-keep"))
        let listed = try await service.listSessions(SessionFilter())
        XCTAssertFalse(listed.contains { $0.id == "sess-keep" },
                       "la session masquée doit le rester")
    }

    /// Deleting a whole project removes several transcripts at once, a parent and its
    /// sub-agents among them. The cleanup has to survive that, not only a single file.
    func testAWholeProjectCanDisappearAtOnce() async throws {
        try await writeAndMark()
        try fixture.write([
            Line.user(uuid: "other-u", text: "projet gardé", at: TestClock.offset(40),
                      sessionId: "sess-other", cwd: "/Users/test/DevApps/Autre"),
        ], to: "-Users-test-DevApps-Autre/sess-other.jsonl")
        try await service.index()

        // Everything under the demo project goes: the two sessions and the sub-agent.
        try FileManager.default.removeItem(at: fixture.url(Line.project))
        let progress = try await service.index()
        XCTAssertGreaterThan(progress.filesTotal, 0, "le parcours n'est pas vide")

        var filter = SessionFilter()
        filter.includeSubagents = true
        await XCTAssertEqualAsync(try await service.listSessions(filter).map(\.id), ["sess-other"])
        await XCTAssertNilAsync(try await service.session(id: Line.session))
        await XCTAssertNilAsync(try await service.session(id: Line.agentId))
        // The index has to stay usable, not merely non-empty.
        await XCTAssertEqualAsync(try await service.search("licorne", filter: SessionFilter()), [])
        await XCTAssertEqualAsync(try await service.search("gardé", filter: SessionFilter()).count, 1)
    }

    /// The guard must not switch off the ordinary cleanup: a transcript really deleted, while
    /// the others are still there, still has to leave the index.
    func testADeletedTranscriptStillDisappearsWhenOthersRemain() async throws {
        try await writeAndMark()
        try FileManager.default.removeItem(at: fixture.url("\(Line.project)/sess-keep.jsonl"))

        let progress = try await service.index()
        XCTAssertGreaterThan(progress.filesTotal, 0, "le parcours n'est pas vide")

        await XCTAssertNilAsync(try await service.session(id: "sess-keep"))
        let survivor = try XCTUnwrapAsync(try await service.session(id: Line.session))
        XCTAssertTrue(survivor.isStarred, "les autres sessions ne sont pas touchées")
    }
}
