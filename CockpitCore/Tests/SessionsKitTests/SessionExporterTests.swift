import XCTest
@testable import SessionsKit

final class SessionExporterTests: XCTestCase {

    private var fixture: TranscriptFixture!
    private var session: SessionRef!
    private var messages: [SessionMessage]!
    private var subagents: [String: [SessionMessage]]!

    override func setUp() async throws {
        fixture = try TranscriptFixture()
        try fixture.writeDemoSession()
        let service = fixture.service()
        try await service.index()
        let found = try await service.session(id: Line.session)
        session = try XCTUnwrap(found)
        messages = try await service.messages(sessionId: Line.session, limit: 500)
        let transcript = try await service.subagentMessages(agentId: Line.agentId)
        subagents = [Line.agentId: transcript]
    }

    override func tearDown() {
        fixture = nil
    }

    func testMarkdownCarriesTheHeaderTurnsAndToolCalls() {
        let markdown = SessionExporter.markdown(
            session: session, messages: messages, subagents: subagents)

        XCTAssertTrue(markdown.hasPrefix("# Correction du parseur"))
        XCTAssertTrue(markdown.contains("**Projet** : /Users/test/DevApps/Demo"))
        XCTAssertTrue(markdown.contains("**Branche** : feat/sessions-viewer"))
        XCTAssertTrue(markdown.contains("[#42](https://github.com/test/demo/pull/42)"))
        XCTAssertTrue(markdown.contains("## Utilisateur"))
        XCTAssertTrue(markdown.contains("## Assistant"))
        XCTAssertTrue(markdown.contains("**Outil : Bash**"))
        XCTAssertTrue(markdown.contains("<summary>Réflexion</summary>"))
        XCTAssertTrue(markdown.contains("<summary>Résultat (erreur)</summary>"))
        XCTAssertTrue(markdown.contains("> Contexte compacté"))
        XCTAssertTrue(markdown.contains("> ⚠︎ Erreur d'API"))
        // The sub-agent transcript is inlined under the call that spawned it.
        XCTAssertTrue(markdown.contains("Sous-agent \(Line.agentId)"))
        XCTAssertTrue(markdown.contains("tout est vert"))
    }

    func testHTMLIsSelfContainedAndEscaped() {
        let html = SessionExporter.html(session: session, messages: messages, subagents: subagents)

        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("<style>"), "la feuille de style doit être inline")
        XCTAssertFalse(html.contains("<script"), "aucun script dans un export autonome")
        XCTAssertFalse(html.contains("src=\"http"), "aucune ressource externe")
        XCTAssertTrue(html.contains("Correction du parseur"))
        XCTAssertTrue(html.contains("<summary>Outil : Bash</summary>"))
        XCTAssertTrue(html.contains("Contexte compacté"))
        XCTAssertTrue(html.hasSuffix("</body></html>\n"))
    }

    /// Transcripts are full of angle brackets and quotes; none of them may become markup.
    func testHTMLEscapesTranscriptContent() {
        let hostile = SessionMessage(
            id: "x", sessionId: "s", sequence: 0, timestamp: TestClock.start, role: .user,
            blocks: [ContentBlock(
                id: "x#0", index: 0, kind: .text,
                text: "<script>alert(\"xss\")</script> & 'quote'")])
        let html = SessionExporter.html(session: session, messages: [hostile])

        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("&amp;"))
        XCTAssertTrue(html.contains("&#39;quote&#39;"))
    }

    func testDurationReadsInFrench() {
        XCTAssertEqual(SessionExporter.duration(45), "45 s")
        XCTAssertEqual(SessionExporter.duration(600), "10 min")
        XCTAssertEqual(SessionExporter.duration(7_800), "2 h 10 min")
        XCTAssertEqual(SessionExporter.duration(-5), "0 s")
    }

    func testExportsAnEmptySessionWithoutCrashing() {
        XCTAssertFalse(SessionExporter.markdown(session: session, messages: []).isEmpty)
        XCTAssertFalse(SessionExporter.html(session: session, messages: []).isEmpty)
    }
}
