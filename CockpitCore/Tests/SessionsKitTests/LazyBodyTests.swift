import XCTest
import CockpitShared
@testable import SessionsKit

/// The 8 KB storage cap is what keeps the index from growing with the size of tool outputs.
/// What it must not cost is fidelity: a block cut in the database has to come back whole
/// when it is displayed, read again from the transcript it came from.
final class LazyBodyTests: XCTestCase {

    private var fixture: TranscriptFixture!
    private var service: SessionService!
    /// Comfortably over the cap, and recognisable at both ends.
    private let huge = "DÉBUT\n" + String(repeating: "sortie très longue\n", count: 3_000) + "FIN"

    override func setUpWithError() throws {
        fixture = try TranscriptFixture()
        service = fixture.service()
    }

    override func tearDown() {
        service = nil
        fixture = nil
    }

    private func writeSessionWithHugeOutput() throws {
        try fixture.write([
            Line.user(uuid: "big-u", text: "lance le build", at: TestClock.offset(0),
                      sessionId: "sess-huge"),
            Line.assistant(uuid: "big-a", at: TestClock.offset(1), blocks: [
                Line.toolUse(id: "big-t", name: "Bash", input: ["command": "swift build"]),
            ], messageId: "msg-big", sessionId: "sess-huge"),
            Line.toolResult(uuid: "big-r", at: TestClock.offset(2), toolUseId: "big-t",
                            text: huge, sessionId: "sess-huge"),
        ], to: "\(Line.project)/sess-huge.jsonl")
    }

    private func storedBody(toolUseId: String) throws -> String {
        let store = try SessionStore(databaseURL: fixture.databaseURL)
        return try store.scalar("""
            SELECT body FROM blocks WHERE tool_use_id = ? AND kind = 'toolResult' LIMIT 1
            """, [toolUseId]) as? String ?? ""
    }

    func testOversizedOutputIsCappedInTheIndexButServedWhole() async throws {
        try writeSessionWithHugeOutput()
        try await service.index()

        let stored = try storedBody(toolUseId: "big-t")
        XCTAssertLessThanOrEqual(
            stored.utf8.count,
            ContentBlock.storedBodyCap + ContentBlock.truncationMarker.utf8.count,
            "la base ne doit garder que le début de la sortie")
        XCTAssertTrue(stored.hasSuffix(ContentBlock.truncationMarker))

        let messages = try await service.messages(sessionId: "sess-huge")
        let result = try XCTUnwrap(messages.flatMap(\.blocks).first { $0.kind == .toolResult })
        XCTAssertEqual(result.text, huge, "le texte complet doit être relu depuis le transcript")
        XCTAssertFalse(result.isTruncated)
    }

    /// A `Write` big enough to be cut still has to yield its full content, or the diff view
    /// shows a truncated file.
    func testATruncatedFileEditRecoversItsStrings() async throws {
        let content = String(repeating: "une ligne de fichier\n", count: 2_000)
        try fixture.write([
            Line.assistant(uuid: "w-a", at: TestClock.offset(0), blocks: [
                Line.toolUse(id: "w-t", name: "Write", input: [
                    "file_path": "/Users/test/DevApps/Demo/gros.txt", "content": content,
                ]),
            ], messageId: "msg-w", sessionId: "sess-write"),
        ], to: "\(Line.project)/sess-write.jsonl")
        try await service.index()

        let messages = try await service.messages(sessionId: "sess-write")
        let block = try XCTUnwrap(messages.flatMap(\.blocks).first { $0.toolName == "Write" })
        XCTAssertEqual(block.fileEdit?.content, content)
        XCTAssertEqual(block.fileEdit?.path, "/Users/test/DevApps/Demo/gros.txt")
        XCTAssertEqual(block.fileEdit?.linesAdded, 2_000)
    }

    /// The transcript is the source of the full text, so its loss must degrade the page, not
    /// fail it: the reader keeps the beginning of the output and its truncation marker.
    func testADeletedTranscriptLeavesTheCappedTextInPlace() async throws {
        try writeSessionWithHugeOutput()
        try await service.index()
        try FileManager.default.removeItem(at: fixture.url("\(Line.project)/sess-huge.jsonl"))

        let messages = try await service.messages(sessionId: "sess-huge")
        let result = try XCTUnwrap(messages.flatMap(\.blocks).first { $0.kind == .toolResult })
        XCTAssertTrue(result.isTruncated)
        XCTAssertTrue(result.text.hasPrefix("DÉBUT"))
    }

    /// A page whose blocks all fit under the cap must not open the transcript at all. Proven
    /// by moving the file out of the way: the text still comes back in full.
    func testAnOrdinaryPageNeverTouchesTheTranscript() async throws {
        try fixture.writeDemoSession()
        try await service.index()
        let path = fixture.url("\(Line.project)/\(Line.session).jsonl")
        let parked = path.appendingPathExtension("parked")
        try FileManager.default.moveItem(at: path, to: parked)
        defer { try? FileManager.default.moveItem(at: parked, to: path) }

        let messages = try await service.messages(sessionId: Line.session, limit: 500)
        XCTAssertFalse(messages.isEmpty)
        XCTAssertFalse(messages.flatMap(\.blocks).contains(where: \.isTruncated))
        XCTAssertTrue(messages.flatMap(\.blocks)
            .contains { $0.text.contains("Corrige le parseur") })
    }

    /// An offset is only as good as the append-only assumption behind it. If one ever points
    /// at the wrong line, the block must stay truncated rather than quietly show another
    /// message's text — a visible gap beats an invisible corruption.
    func testAStaleOffsetIsRefusedRatherThanSplicedIn() async throws {
        try writeSessionWithHugeOutput()
        try await service.index()

        // Point the tool-result message at the *first* line of the transcript instead.
        let store = try SessionStore(databaseURL: fixture.databaseURL)
        let head = try store.rows("""
            SELECT line_offset, line_len FROM messages WHERE uuid = 'big-u'
            """).first
        try store.run("""
            UPDATE messages SET line_offset = ?, line_len = ? WHERE uuid = 'big-r'
            """, [head?[0], head?[1]])

        let messages = try await service.messages(sessionId: "sess-huge")
        let result = try XCTUnwrap(messages.flatMap(\.blocks).first { $0.kind == .toolResult })
        XCTAssertTrue(result.isTruncated, "un offset périmé ne doit pas être suivi")
        XCTAssertTrue(result.text.hasPrefix("DÉBUT"), "le texte stocké reste en place")
        XCTAssertFalse(result.text.contains("lance le build"),
                       "le texte d'un autre message ne doit jamais être recollé ici")
    }

    /// Search only covers what is indexed, and what is indexed stops at the cap. Better said
    /// once here than discovered by a user hunting for a line that is in the transcript.
    func testSearchOnlyReachesTheIndexedPrefixOfALongOutput() async throws {
        try writeSessionWithHugeOutput()
        try await service.index()
        await XCTAssertEqualAsync(try await service.search("DÉBUT", filter: SessionFilter()).count, 1)
        await XCTAssertEqualAsync(try await service.search("FIN", filter: SessionFilter()), [],
                       "au-delà du plafond, le texte n'est pas indexé")
    }
}
