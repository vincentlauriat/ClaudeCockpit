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

    /// `attachment` is mostly Claude Code's own plumbing: hook output, token reminders, the
    /// date, the skill listing. 112 015 such lines in the real archive against 273 real files.
    /// Treating them all as attachments put a phantom "1 pièce jointe" on nearly every turn.
    func testClaudeCodePlumbingIsNotAnAttachment() {
        for kind in ["hook_success", "total_tokens_reminder", "hook_additional_context",
                     "environment", "skill_listing", "date", "model", "prompt_snapshot"] {
            guard case .ignored = parse(Line.attachment(parentUuid: "u2", kind: kind))
            else { return XCTFail("\(kind) ne doit pas compter comme pièce jointe") }
        }
    }

    /// An allow-list, not a deny-list: a kind Claude Code invents tomorrow stays out until
    /// someone decides it is a file.
    func testAnUnknownAttachmentKindIsIgnoredRatherThanCounted() {
        guard case .ignored = parse(Line.attachment(parentUuid: "u2", kind: "quantum_reminder"))
        else { return XCTFail("un type inconnu doit rester hors du compte") }
    }

    func testARealFileAttachmentIsNamedFromItsDisplayPath() {
        guard case .attachment(let name) = parse(Line.fileAttachment(
            parentUuid: "u2", filename: "/Users/test/DevApps/Demo/internal/api.go",
            displayPath: "internal/api.go"))
        else { return XCTFail("attendu une pièce jointe") }
        XCTAssertEqual(name, "internal/api.go")
    }

    /// `edited_text_file` carries no `displayPath`, so the name comes from the file itself
    /// rather than from an absolute path too long to show in a turn header.
    func testAnEditedTextFileFallsBackToItsFileName() {
        guard case .attachment(let name) = parse(Line.fileAttachment(
            parentUuid: "u2", kind: "edited_text_file",
            filename: "/Users/test/DevApps/Demo/notes/TODO.md"))
        else { return XCTFail("attendu une pièce jointe") }
        XCTAssertEqual(name, "TODO.md")
    }

    func testACompactFileReferenceIsAnAttachment() {
        guard case .attachment(let name) = parse(Line.fileAttachment(
            parentUuid: "u2", kind: "compact_file_reference",
            filename: "/Users/test/DevApps/Demo/store/azure.go",
            displayPath: "store/azure.go"))
        else { return XCTFail("attendu une pièce jointe") }
        XCTAssertEqual(name, "store/azure.go")
    }

    /// The byte scan is only a filter; the nested `type` decides. A hook whose output happens
    /// to quote `"type":"file"` must not become an attachment.
    func testAHookQuotingAFileTypeIsStillIgnored() {
        let line = Line.encode([
            "type": "attachment", "uuid": "x", "parentUuid": "u2", "sessionId": Line.session,
            "attachment": ["type": "hook_success", "stdout": #"{"type":"file","filename":"/tmp/a"}"#],
        ])
        guard case .ignored = parse(line)
        else { return XCTFail("le type imbriqué fait foi, pas les octets") }
    }

    func testAFileAttachmentWithoutAnyNameIsIgnored() {
        let line = Line.encode([
            "type": "attachment", "uuid": "x", "parentUuid": "u2", "sessionId": Line.session,
            "attachment": ["type": "file", "content": "…"],
        ])
        guard case .ignored = parse(line) else { return XCTFail("sans nom, rien à afficher") }
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
        let huge = String(repeating: "a", count: ContentBlock.storedBodyCap + 500)
        let capped = parser.capped(huge)
        XCTAssertTrue(capped.hasSuffix(ContentBlock.truncationMarker))
        XCTAssertEqual(capped.utf8.count,
                       ContentBlock.storedBodyCap + ContentBlock.truncationMarker.utf8.count)
        XCTAssertEqual(parser.capped("court"), "court")

        // The display path re-parses the same line with a far larger cap.
        let display = TranscriptParser(bodyCap: ContentBlock.bodyCap)
        XCTAssertEqual(display.capped(huge), huge)
    }

    /// A cut that lands inside an accented character must back up, not leave a broken glyph.
    func testCapNeverCutsACharacterInHalf() {
        let accented = String(repeating: "é", count: 200)   // two bytes per character
        for cap in [7, 8, 9, 10] {
            let capped = TranscriptParser.capped(accented, cap: cap)
            let body = String(capped.dropLast(ContentBlock.truncationMarker.count))
            XCTAssertFalse(body.unicodeScalars.contains("\u{FFFD}"), "cap \(cap)")
            XCTAssertTrue(accented.hasPrefix(body), "cap \(cap)")
            XCTAssertLessThanOrEqual(body.utf8.count, cap, "cap \(cap)")
        }
    }
}
