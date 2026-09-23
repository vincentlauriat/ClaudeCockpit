import XCTest
import CockpitShared
@testable import SessionsKit

/// The indexing pass: what it stores, what it refuses to read twice, and how it recovers.
final class SessionIndexerTests: XCTestCase {

    private var fixture: TranscriptFixture!

    override func setUpWithError() throws {
        fixture = try TranscriptFixture()
    }

    override func tearDown() {
        fixture = nil
    }

    func testIndexesEveryLineKindOfTheDemoSession() async throws {
        try fixture.writeDemoSession()
        let service = fixture.service()
        let progress = try await service.index()

        XCTAssertFalse(progress.isRunning)
        XCTAssertEqual(progress.filesTotal, 2)  // the session and its sub-agent
        XCTAssertEqual(progress.filesDone, 2)
        XCTAssertGreaterThan(progress.bytesRead, 0)
        XCTAssertNotNil(progress.lastRun)

        let session = try XCTUnwrapAsync(try await service.session(id: Line.session))
        XCTAssertEqual(session.title, "Correction du parseur")  // the ai-title line
        XCTAssertEqual(session.cwd, Line.cwd)
        XCTAssertEqual(session.gitBranch, "feat/sessions-viewer")
        XCTAssertEqual(session.claudeVersion, "2.1.278")
        XCTAssertEqual(session.assistantTurns, 6)
        XCTAssertEqual(session.toolCalls, 5)
        XCTAssertEqual(session.toolErrors, 1)
        XCTAssertEqual(session.costStateUSD ?? 0, 1.2345, accuracy: 0.0001)
        XCTAssertEqual(session.prLinks.map(\.number), [42])
        XCTAssertNil(session.parentSessionId)
        XCTAssertFalse(session.isSubagent)
        // Edit (+3/−2) and Write (+3/−0).
        XCTAssertEqual(session.linesAdded, 6)
        XCTAssertEqual(session.linesRemoved, 2)
        // Six assistant turns at 10 in / 20 out / 5 cache-read / 2 cache-create.
        XCTAssertEqual(session.inputTokens, 60)
        XCTAssertEqual(session.outputTokens, 120)
        XCTAssertEqual(session.cacheReadTokens, 30)
        XCTAssertEqual(session.cacheCreationTokens, 12)
        XCTAssertEqual(session.totalTokens, 222)
        XCTAssertEqual(session.duration, 13 * 60, accuracy: 0.5)
    }

    func testStoresBlocksAttachmentsAndCompactionFlags() async throws {
        try fixture.writeDemoSession()
        let service = fixture.service()
        try await service.index()

        let messages = try await service.messages(sessionId: Line.session, limit: 500)
        let byId = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })

        let first = try XCTUnwrap(byId["a1"])
        XCTAssertEqual(first.blocks.map(\.kind), [.thinking, .text, .toolUse])
        XCTAssertEqual(first.blocks[2].toolName, "Bash")
        XCTAssertEqual(first.blocks[0].id, "a1#0")

        // Hook output rides on the same line type as a real attachment and must not show up.
        XCTAssertEqual(try XCTUnwrap(byId["u2"]).attachments, [])
        // Real files do, named, on the turn they were attached to.
        XCTAssertEqual(try XCTUnwrap(byId["u1"]).attachments, ["internal/api.go", "TODO.md"])
        XCTAssertEqual(try XCTUnwrap(byId["u1"]).attachmentCount, 2)

        XCTAssertTrue(try XCTUnwrap(byId["s1"]).isCompactBoundary)
        XCTAssertEqual(try XCTUnwrap(byId["s1"]).systemSubtype, "compact_boundary")
        XCTAssertTrue(try XCTUnwrap(byId["u7"]).isCompactBoundary)
        XCTAssertTrue(try XCTUnwrap(byId["a6"]).isApiError)
        XCTAssertEqual(try XCTUnwrap(byId["a6"]).blocks.last?.imageMediaType, "image/png")

        // The tool result carries the name of the call it answers, which is what makes the
        // tool mix and the error rate plain group-by queries.
        let failing = try XCTUnwrap(byId["u6"]).blocks.first
        XCTAssertEqual(failing?.toolName, "Bash")
        XCTAssertTrue(failing?.isError ?? false)
    }

    /// An attachment's `parentUuid` points at the *previous attachment*, not at the message:
    /// Claude Code chains them up to nine deep. Following the chain and taking the last
    /// message written before it agree on all 273 file attachments of the real archive, so
    /// the indexer takes the second route — and this pins it against a chain three deep.
    func testAnAttachmentBehindAChainOfPlumbingStillFindsItsTurn() async throws {
        try fixture.write([
            Line.user(uuid: "c-u1", text: "voici le fichier", at: TestClock.offset(0),
                      sessionId: "sess-chain"),
            Line.attachment(parentUuid: "c-u1", kind: "hook_success", sessionId: "sess-chain"),
            Line.attachment(parentUuid: "ignoré", kind: "environment", sessionId: "sess-chain"),
            Line.attachment(parentUuid: "ignoré", kind: "date", sessionId: "sess-chain"),
            Line.fileAttachment(parentUuid: "ignoré", filename: "/x/y/api.go",
                                displayPath: "y/api.go", sessionId: "sess-chain"),
            Line.assistant(uuid: "c-a1", at: TestClock.offset(1),
                           blocks: [Line.text("bien reçu")],
                           messageId: "msg-c1", sessionId: "sess-chain"),
        ], to: "\(Line.project)/sess-chain.jsonl")

        let service = fixture.service()
        try await service.index()
        let messages = try await service.messages(sessionId: "sess-chain")
        let byId = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })

        XCTAssertEqual(try XCTUnwrap(byId["c-u1"]).attachments, ["y/api.go"])
        XCTAssertEqual(try XCTUnwrap(byId["c-a1"]).attachments, [],
                       "le tour suivant ne doit rien récupérer")
    }

    /// A `user` line carrying only a `tool_result` is written by Claude Code to bring an
    /// answer back, never by someone attaching a file — and the `edited_text_file` that
    /// follows one records what the *agent* just edited. Hanging it there produced a bubble
    /// saying nothing but "1 pièce jointe": 107 of the archive's 273 file attachments.
    func testAFileRecordedAfterAToolResultIsNotTheUsersAttachment() async throws {
        try fixture.write([
            Line.user(uuid: "t-u1", text: "modifie le fichier", at: TestClock.offset(0),
                      sessionId: "sess-tool"),
            Line.assistant(uuid: "t-a1", at: TestClock.offset(1), blocks: [
                Line.toolUse(id: "t-t1", name: "Edit", input: [
                    "file_path": "/x/store.py", "old_string": "a", "new_string": "b",
                ]),
            ], messageId: "msg-t1", sessionId: "sess-tool"),
            Line.toolResult(uuid: "t-u2", at: TestClock.offset(2), toolUseId: "t-t1",
                            text: "Edit applied", sessionId: "sess-tool"),
            // Claude Code notes what it just edited, right after the tool's answer.
            Line.fileAttachment(parentUuid: "t-u2", kind: "edited_text_file",
                                filename: "/x/store.py", sessionId: "sess-tool"),
        ], to: "\(Line.project)/sess-tool.jsonl")

        let service = fixture.service()
        try await service.index()
        let messages = try await service.messages(sessionId: "sess-tool")
        XCTAssertTrue(messages.allSatisfy(\.attachments.isEmpty),
                      "aucun tour ne doit afficher une pièce jointe que Vincent n'a pas jointe")

        // And no bubble is left carrying an attachment and nothing else.
        let bare = messages.filter {
            !$0.attachments.isEmpty && !$0.blocks.contains { $0.kind != .toolResult }
        }
        XCTAssertEqual(bare, [], "aucune bulle « Vous » réduite à une pièce jointe")
    }

    /// The chain can also straddle two indexing passes, the message having been stored before
    /// the attachment was appended.
    func testAnAttachmentAppendedLaterStillFindsItsTurn() async throws {
        let path = "\(Line.project)/sess-late.jsonl"
        try fixture.write([
            Line.user(uuid: "l-u1", text: "le fichier arrive", at: TestClock.offset(0),
                      sessionId: "sess-late"),
        ], to: path)
        let service = fixture.service()
        try await service.index()

        try fixture.append(Line.fileAttachment(
            parentUuid: "l-u1", filename: "/x/y/tard.go", displayPath: "y/tard.go",
            sessionId: "sess-late"), to: path)
        try await service.index()

        let messages = try await service.messages(sessionId: "sess-late")
        XCTAssertEqual(messages.first?.attachments, ["y/tard.go"])
    }

    func testRebuildsFileEditsWithTheirStrings() async throws {
        try fixture.writeDemoSession()
        let service = fixture.service()
        try await service.index()

        let messages = try await service.messages(sessionId: Line.session, limit: 500)
        let editBlock = try XCTUnwrap(messages
            .flatMap(\.blocks).first { $0.fileEdit?.tool == "Edit" })
        let edit = try XCTUnwrap(editBlock.fileEdit)
        XCTAssertEqual(edit.path, "/Users/test/DevApps/Demo/Parser.swift")
        XCTAssertEqual(edit.oldString, "let a = 1\nlet b = 2")
        XCTAssertEqual(edit.newString, "let a = 1\nlet b = 3\nlet c = 4")
        XCTAssertEqual(edit.linesAdded, 3)
        XCTAssertEqual(edit.linesRemoved, 2)

        let writeBlock = try XCTUnwrap(messages
            .flatMap(\.blocks).first { $0.fileEdit?.tool == "Write" })
        XCTAssertEqual(writeBlock.fileEdit?.content, "# Notes\nune ligne\nune autre")
    }

    // MARK: - Sub-agents

    func testLinksSubagentTranscriptToTheCallThatSpawnedIt() async throws {
        try fixture.writeDemoSession()
        let service = fixture.service()
        try await service.index()

        // The sub-agent is its own session, keyed by agentId, pointing back at its parent.
        let agent = try XCTUnwrapAsync(try await service.session(id: Line.agentId))
        XCTAssertEqual(agent.parentSessionId, Line.session)
        XCTAssertTrue(agent.isSubagent)

        await XCTAssertEqualAsync(try await service.subagentIds(ofSession: Line.session), [Line.agentId])

        let messages = try await service.messages(sessionId: Line.session, limit: 500)
        let agentCall = try XCTUnwrap(messages.flatMap(\.blocks).first { $0.toolName == "Agent" })
        XCTAssertEqual(agentCall.subagentId, Line.agentId)

        let transcript = try await service.subagentMessages(agentId: Line.agentId)
        XCTAssertEqual(transcript.count, 2)
        XCTAssertTrue(transcript.allSatisfy(\.isSidechain))
        XCTAssertTrue(transcript.last?.blocks.first?.text.contains("tout est vert") ?? false)
    }

    /// Sub-agent lines carry the *parent* session id, so indexing them under the id they
    /// claim would merge them into their parent and inflate every counter.
    func testSubagentTurnsAreNotCountedOnTheParent() async throws {
        try fixture.writeDemoSession()
        let service = fixture.service()
        try await service.index()

        let parent = try XCTUnwrapAsync(try await service.session(id: Line.session))
        let agent = try XCTUnwrapAsync(try await service.session(id: Line.agentId))
        XCTAssertEqual(parent.assistantTurns, 6)
        XCTAssertEqual(agent.assistantTurns, 1)
        XCTAssertEqual(agent.userTurns, 1)
    }

    // MARK: - Incremental

    func testSecondPassReadsNothing() async throws {
        try fixture.writeDemoSession()
        let service = fixture.service()
        let first = try await service.index()
        XCTAssertGreaterThan(first.bytesRead, 0)

        let second = try await service.index()
        XCTAssertEqual(second.bytesRead, 0, "un transcript inchangé ne doit pas être relu")
        XCTAssertEqual(second.filesTotal, 2)
    }

    func testAppendedLinesAreIndexedWithoutRereadingTheFile() async throws {
        let path = try fixture.writeDemoSession()
        let service = fixture.service()
        try await service.index()
        let before = try await service.messageCount(sessionId: Line.session)

        let appended = Line.assistant(
            uuid: "a7", at: TestClock.offset(20),
            blocks: [Line.text("Ajout après coup")], messageId: "msg-a7")
        try fixture.append(appended, to: path)

        let outcome = try await service.index()
        XCTAssertEqual(Int(outcome.bytesRead), appended.utf8.count + 1)
        await XCTAssertEqualAsync(try await service.messageCount(sessionId: Line.session), before + 1)

        let session = try XCTUnwrapAsync(try await service.session(id: Line.session))
        XCTAssertEqual(session.assistantTurns, 7)
        XCTAssertEqual(session.lastTimestamp, TestClock.offset(20))
    }

    /// A transcript caught mid-write ends on half a line. It must be left alone until the
    /// writer finishes it, and never counted as read.
    func testPartialTrailingLineIsLeftForTheNextPass() async throws {
        let path = try fixture.writeDemoSession()
        let service = fixture.service()
        try await service.index()
        let before = try await service.messageCount(sessionId: Line.session)

        let line = Line.assistant(
            uuid: "a8", at: TestClock.offset(21), blocks: [Line.text("moitié")], messageId: "msg-a8")
        let cut = String(line.prefix(line.count / 2))
        try fixture.appendPartial(cut, to: path)

        try await service.index()
        await XCTAssertEqualAsync(try await service.messageCount(sessionId: Line.session), before,
                       "une ligne incomplète ne doit pas être indexée")

        // The writer finishes the line; it is picked up on the very next pass.
        try fixture.appendPartial(String(line.dropFirst(cut.count)) + "\n", to: path)
        try await service.index()
        await XCTAssertEqualAsync(try await service.messageCount(sessionId: Line.session), before + 1)
    }

    /// Two transcripts can carry the same API response. Its tokens must be counted once.
    func testDedupesAssistantMessagesByApiMessageId() async throws {
        let shared = Line.assistant(
            uuid: "dup-a", at: TestClock.offset(0), blocks: [Line.text("réponse partagée")],
            messageId: "msg-shared", sessionId: "sess-a", inputTokens: 100, outputTokens: 200)
        try fixture.write([
            Line.user(uuid: "dup-u", text: "question", at: TestClock.offset(0), sessionId: "sess-a"),
            shared,
        ], to: "\(Line.project)/sess-a.jsonl")
        try fixture.write([
            Line.user(uuid: "dup-u2", text: "question", at: TestClock.offset(0), sessionId: "sess-b"),
            shared.replacingOccurrences(of: "\"sess-a\"", with: "\"sess-b\"")
                .replacingOccurrences(of: "\"dup-a\"", with: "\"dup-b\""),
        ], to: "\(Line.project)/sess-b.jsonl")

        let service = fixture.service()
        try await service.index()

        let first = try XCTUnwrapAsync(try await service.session(id: "sess-a"))
        let second = try XCTUnwrapAsync(try await service.session(id: "sess-b"))
        XCTAssertEqual(first.inputTokens + second.inputTokens, 100,
                       "la même réponse d'API ne doit être comptée qu'une fois")
        XCTAssertEqual(first.outputTokens + second.outputTokens, 200)
        // Both transcripts still read in full: only the token accounting is deduped.
        await XCTAssertEqualAsync(try await service.messageCount(sessionId: "sess-a"), 2)
        await XCTAssertEqualAsync(try await service.messageCount(sessionId: "sess-b"), 2)
    }

    // MARK: - Rebuild

    func testFullRebuildKeepsStarsAndCustomNames() async throws {
        try fixture.writeDemoSession()
        let service = fixture.service()
        try await service.index()
        try await service.setStarred(true, sessionId: Line.session)
        try await service.rename(sessionId: Line.session, customName: "Ma session")

        let rebuilt = try await service.index(full: true)
        XCTAssertGreaterThan(rebuilt.bytesRead, 0, "une reconstruction relit tout")

        let session = try XCTUnwrapAsync(try await service.session(id: Line.session))
        XCTAssertTrue(session.isStarred)
        XCTAssertEqual(session.customName, "Ma session")
        XCTAssertEqual(session.title, "Ma session", "le nom choisi prime sur l'ai-title")
        XCTAssertEqual(session.assistantTurns, 6, "les agrégats sont recalculés, pas doublés")
    }

    /// A transcript that was replaced rather than appended to is re-read from byte zero, and
    /// its old rows — including the FTS entries, which external-content tables do not clean
    /// up on their own — have to go with it.
    func testRewrittenTranscriptIsReindexedWithoutPhantomSearchHits() async throws {
        let path = "\(Line.project)/sess-r.jsonl"
        try fixture.write([
            Line.user(uuid: "r1", text: "licorne originale", at: TestClock.offset(0), sessionId: "sess-r"),
        ], to: path)
        let service = fixture.service()
        try await service.index()
        await XCTAssertEqualAsync(try await service.search("licorne", filter: SessionFilter()).count, 1)

        try fixture.write([
            Line.user(uuid: "r2", text: "hippogriffe de remplacement",
                      at: TestClock.offset(1), sessionId: "sess-r"),
        ], to: path)
        try await service.index()

        await XCTAssertEqualAsync(try await service.search("licorne", filter: SessionFilter()), [],
                       "l'index plein texte doit oublier le contenu supprimé")
        await XCTAssertEqualAsync(try await service.search("hippogriffe", filter: SessionFilter()).count, 1)
        await XCTAssertEqualAsync(try await service.messageCount(sessionId: "sess-r"), 1)
    }

    /// Re-reading a transcript from byte zero drops its blocks, and with them the
    /// `subagent_id` that made the `Agent` card openable. The link has to be rebuilt in the
    /// same pass, or the card goes dead with nothing reporting it.
    func testRereadingATranscriptRebuildsItsSubagentLinks() async throws {
        try fixture.writeDemoSession()
        let service = fixture.service()
        try await service.index()

        func agentBlock() async throws -> ContentBlock {
            let messages = try await service.messages(sessionId: Line.session, limit: 500)
            return try XCTUnwrap(messages.flatMap(\.blocks).first { $0.toolName == "Agent" })
        }
        let before = try await agentBlock()
        XCTAssertEqual(before.subagentId, Line.agentId)

        // An atomic rewrite: same content, new inode, so the whole session is read again.
        try fixture.writeDemoSession()
        try await service.index()

        let after = try await agentBlock()
        XCTAssertEqual(after.subagentId, Line.agentId,
                       "le lien vers le sous-agent doit être refait après une relecture")
        await XCTAssertEqualAsync(
            try await service.subagentMessages(agentId: Line.agentId).count, 2)
    }

    func testForgetsSessionsWhoseTranscriptIsGone() async throws {
        let path = try fixture.writeDemoSession()
        let service = fixture.service()
        try await service.index()
        await XCTAssertNotNilAsync(try await service.session(id: Line.session))

        try FileManager.default.removeItem(at: fixture.url(path))
        try await service.index()
        await XCTAssertNilAsync(try await service.session(id: Line.session))
    }

    func testTranscriptURLPointsAtTheIndexedFile() async throws {
        let path = try fixture.writeDemoSession()
        let service = fixture.service()
        try await service.index()
        let found = try await service.transcriptURL(sessionId: Line.session)
        XCTAssertEqual(found?.resolvingSymlinksInPath(),
                       fixture.url(path).resolvingSymlinksInPath())
        await XCTAssertNilAsync(try await service.transcriptURL(sessionId: "inconnue"))
    }
}

// MARK: - Helpers

/// `XCTUnwrap` on a value that had to be awaited out of an actor.
func XCTUnwrapAsync<T>(
    _ value: T?, _ message: String = "valeur nulle", file: StaticString = #filePath, line: UInt = #line
) throws -> T {
    try XCTUnwrap(value, message, file: file, line: line)
}

// MARK: - Async assertions

// XCTest's assertions take non-async autoclosures, so an `await` cannot appear inside one.
// These thin wrappers evaluate the expression first and then assert on the result.

func XCTAssertEqualAsync<T: Equatable>(
    _ expression: @autoclosure () async throws -> T,
    _ expected: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        let actual = try await expression()
        XCTAssertEqual(actual, try expected(), message(), file: file, line: line)
    } catch {
        XCTFail("\(error)", file: file, line: line)
    }
}

func XCTAssertNotNilAsync<T>(
    _ expression: @autoclosure () async throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        let value = try await expression()
        XCTAssertNotNil(value, message(), file: file, line: line)
    } catch {
        XCTFail("\(error)", file: file, line: line)
    }
}

func XCTAssertNilAsync<T>(
    _ expression: @autoclosure () async throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        let value = try await expression()
        XCTAssertNil(value, message(), file: file, line: line)
    } catch {
        XCTFail("\(error)", file: file, line: line)
    }
}
