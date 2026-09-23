import XCTest
@testable import SessionsKit

/// One test per line kind the spec lists, plus the shapes that vary between releases.
final class TranscriptParserTests: XCTestCase {

    private let parser = TranscriptParser()

    private func parse(_ line: String) -> ParsedLine {
        parser.parse(Data(line.utf8))
    }

    func testParsesUserTextLine() throws {
        guard case .message(let message) = parse(
            Line.user(uuid: "u1", text: "bonjour", at: TestClock.start))
        else { return XCTFail("attendu une ligne user") }

        XCTAssertEqual(message.uuid, "u1")
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.sessionId, Line.session)
        XCTAssertEqual(message.timestamp, TestClock.start)
        XCTAssertEqual(message.cwd, Line.cwd)
        XCTAssertEqual(message.gitBranch, "feat/sessions-viewer")
        XCTAssertEqual(message.version, "2.1.278")
        XCTAssertEqual(message.blocks.count, 1)
        XCTAssertEqual(message.blocks.first?.kind, .text)
        XCTAssertEqual(message.blocks.first?.body, "bonjour")
    }

    func testParsesAssistantBlocksAndUsage() throws {
        guard case .message(let message) = parse(Line.assistant(
            uuid: "a1", at: TestClock.start,
            blocks: [Line.thinking("hmm"), Line.text("voilà"),
                     Line.toolUse(id: "t1", name: "Bash", input: ["command": "ls"])],
            messageId: "msg-1", inputTokens: 11, outputTokens: 22,
            cacheReadTokens: 33, cacheCreationTokens: 44))
        else { return XCTFail("attendu une ligne assistant") }

        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(message.apiMessageId, "msg-1")
        XCTAssertEqual(message.model, "claude-opus-5")
        XCTAssertEqual(message.inputTokens, 11)
        XCTAssertEqual(message.outputTokens, 22)
        XCTAssertEqual(message.cacheReadTokens, 33)
        XCTAssertEqual(message.cacheCreationTokens, 44)
        XCTAssertEqual(message.blocks.map(\.kind), [.thinking, .text, .toolUse])
        XCTAssertEqual(message.blocks[2].toolName, "Bash")
        XCTAssertEqual(message.blocks[2].toolUseId, "t1")
        XCTAssertTrue(message.blocks[2].body.contains("\"command\""), message.blocks[2].body)
    }

    func testParsesToolResultAndItsError() throws {
        guard case .message(let message) = parse(Line.toolResult(
            uuid: "u2", at: TestClock.start, toolUseId: "t1",
            text: "command not found", isError: true))
        else { return XCTFail("attendu une ligne user portant un tool_result") }

        let block = try XCTUnwrap(message.blocks.first)
        XCTAssertEqual(block.kind, .toolResult)
        XCTAssertEqual(block.toolUseId, "t1")
        XCTAssertTrue(block.isError)
        XCTAssertEqual(block.body, "command not found")
    }

    /// `tool_result.content` is a bare string for some tools and an array of blocks for others.
    func testFlattensBothToolResultContentShapes() {
        XCTAssertEqual(TranscriptParser.flatten("texte brut"), "texte brut")
        XCTAssertEqual(
            TranscriptParser.flatten([["type": "text", "text": "une"], ["type": "text", "text": "deux"]]),
            "une\ndeux")
    }

    func testDetectsBothCompactionMechanisms() {
        guard case .compactBoundary(let fromSystem) = parse(
            Line.compactBoundary(uuid: "s1", at: TestClock.start))
        else { return XCTFail("attendu une frontière de compaction système") }
        XCTAssertEqual(fromSystem.role, .system)
        XCTAssertEqual(fromSystem.systemSubtype, "compact_boundary")
        XCTAssertTrue(fromSystem.isCompactBoundary)

        guard case .compactBoundary(let fromUser) = parse(
            Line.compactSummary(uuid: "u7", at: TestClock.start))
        else { return XCTFail("attendu une frontière de compaction utilisateur") }
        XCTAssertEqual(fromUser.role, .user)
        XCTAssertTrue(fromUser.isCompactBoundary)
    }

    func testDetectsApiErrorAndAbortedTurns() {
        guard case .message(let failed) = parse(Line.assistant(
            uuid: "a1", at: TestClock.start, blocks: [Line.text("échec")], isApiError: true))
        else { return XCTFail("attendu une ligne assistant") }
        XCTAssertTrue(failed.isApiError)

        guard case .message(let aborted) = parse(Line.assistant(
            uuid: "a2", at: TestClock.start, blocks: [Line.text("…")], isAborted: true))
        else { return XCTFail("attendu une ligne assistant") }
        XCTAssertTrue(aborted.isAborted)
    }

    func testParsesAiTitlePrLinkAndCostState() throws {
        guard case .aiTitle(let sessionId, let title) = parse(Line.aiTitle("Mon titre"))
        else { return XCTFail("attendu une ligne ai-title") }
        XCTAssertEqual(sessionId, Line.session)
        XCTAssertEqual(title, "Mon titre")

        guard case .prLink(_, let link) = parse(Line.prLink(number: 7, at: TestClock.start))
        else { return XCTFail("attendu une ligne pr-link") }
        XCTAssertEqual(link.number, 7)
        XCTAssertEqual(link.repository, "test/demo")
        XCTAssertEqual(link.url.absoluteString, "https://github.com/test/demo/pull/7")

        guard case .costState(_, let cost, let added, let removed) = parse(Line.costState(0.5))
        else { return XCTFail("attendu une ligne cost-state") }
        XCTAssertEqual(cost, 0.5, accuracy: 0.0001)
        XCTAssertEqual(added, 12)
        XCTAssertEqual(removed, 3)
    }

    /// Attachments are recognised on the raw bytes, so their payload never reaches the JSON
    /// decoder — only the uuid of the message they hang off is read out.
    func testAttachmentsAreCountedNotStored() {
        guard case .attachment(let parentUuid) = parse(Line.attachment(parentUuid: "u2"))
        else { return XCTFail("attendu une ligne attachment") }
        XCTAssertEqual(parentUuid, "u2")
    }

    func testIgnoresNoiseAndUnknownLineKinds() {
        if case .ignored = parse(Line.noise()) {} else { XCTFail("le bruit doit être ignoré") }
        if case .ignored = parse(#"{"type":"atis-latch","sessionId":"x"}"#) {}
        else { XCTFail("atis-latch doit être ignoré") }
        if case .ignored = parse("pas du json") {} else { XCTFail("une ligne illisible est ignorée") }
    }

    // MARK: - File edits

    func testCountsLinesForEachFileTool() throws {
        let edit = try XCTUnwrap(TranscriptParser.fileEdit(tool: "Edit", input: [
            "file_path": "/tmp/a.swift",
            "old_string": "un\ndeux",
            "new_string": "un\ndeux\ntrois",
        ]))
        XCTAssertEqual(edit.path, "/tmp/a.swift")
        XCTAssertEqual(edit.linesRemoved, 2)
        XCTAssertEqual(edit.linesAdded, 3)

        let write = try XCTUnwrap(TranscriptParser.fileEdit(tool: "Write", input: [
            "file_path": "/tmp/b.md", "content": "a\nb\nc\n",
        ]))
        XCTAssertEqual(write.linesAdded, 3)
        XCTAssertEqual(write.linesRemoved, 0)
        XCTAssertEqual(write.content, "a\nb\nc\n")

        let multi = try XCTUnwrap(TranscriptParser.fileEdit(tool: "MultiEdit", input: [
            "file_path": "/tmp/c.swift",
            "edits": [
                ["old_string": "x", "new_string": "x\ny"],
                ["old_string": "z\nw", "new_string": "z"],
            ],
        ]))
        XCTAssertEqual(multi.linesAdded, 3)
        XCTAssertEqual(multi.linesRemoved, 3)

        XCTAssertNil(TranscriptParser.fileEdit(tool: "Bash", input: ["command": "ls"]))
    }

    // MARK: - Agent linking

    func testReadsBothAgentReferenceForms() {
        XCTAssertEqual(
            TranscriptParser.agentReference(in: "Spawned.\nagentId: a1e17712abe09e8df (internal)"),
            "a1e17712abe09e8df")
        XCTAssertEqual(
            TranscriptParser.agentReference(in: "agent_id: dev-1-4@session-3818b05e\n"),
            "dev-1-4@session-3818b05e")
        XCTAssertNil(TranscriptParser.agentReference(in: "rien à voir ici"))
    }

    func testDerivesAgentNameFromAgentId() {
        XCTAssertEqual(TranscriptWalker.agentName(fromAgentId: "aimpl-t1-2-01b9429ddddff833"), "impl-t1-2")
        XCTAssertEqual(TranscriptWalker.agentName(fromAgentId: "asessionskit-64025234235c2371"), "sessionskit")
        XCTAssertNil(TranscriptWalker.agentName(fromAgentId: "sans-suffixe-hex"))
    }

    // MARK: - Timestamps

    /// The hand-rolled reader has to agree with `ISO8601DateFormatter` on every shape the
    /// transcripts use, or every timestamp in the index is quietly wrong.
    func testFastTimestampParserMatchesFoundation() {
        for value in [
            "2026-09-23T10:00:00.000Z", "2026-09-22T08:19:19.200Z",
            "2026-01-01T00:00:00.000Z", "2024-02-29T23:59:59.999Z",
            "2026-12-31T12:34:56Z",
        ] {
            let fast = TranscriptParser.fastDate(from: value)
            let reference = TranscriptParser.isoWithFraction.date(from: value)
                ?? TranscriptParser.iso.date(from: value)
            XCTAssertNotNil(fast, value)
            XCTAssertEqual(fast?.timeIntervalSince1970 ?? -1,
                           reference?.timeIntervalSince1970 ?? -2, accuracy: 0.0005, value)
        }
        // An offset other than Z is left to Foundation rather than mis-read.
        XCTAssertNil(TranscriptParser.fastDate(from: "2026-09-23T10:00:00+02:00"))
        XCTAssertNotNil(TranscriptParser.date(from: "2026-09-23T10:00:00+02:00"))
    }

    // MARK: - Caps

    func testCapsAVeryLargeBlockAndMarksIt() {
        let huge = String(repeating: "a", count: ContentBlock.bodyCap + 500)
        let capped = TranscriptParser.capped(huge)
        XCTAssertTrue(capped.hasSuffix(ContentBlock.truncationMarker))
        XCTAssertEqual(capped.utf8.count,
                       ContentBlock.bodyCap + ContentBlock.truncationMarker.utf8.count)
        XCTAssertEqual(TranscriptParser.capped("court"), "court")
    }
}
