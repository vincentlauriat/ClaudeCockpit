import XCTest
@testable import SessionsKit

/// The health grade is deterministic and LLM-free, so every rule is pinned to a number.
final class SessionHealthTests: XCTestCase {

    private let session = SessionRef(
        id: "s", projectDir: "p", cwd: "/tmp", title: "t",
        firstTimestamp: TestClock.start, lastTimestamp: TestClock.offset(10), toolCalls: 20)

    private func message(
        _ id: String, role: MessageRole = .assistant, blocks: [ContentBlock] = [],
        isApiError: Bool = false, isAborted: Bool = false
    ) -> SessionMessage {
        SessionMessage(
            id: id, sessionId: "s", sequence: 0, timestamp: TestClock.start, role: role,
            isApiError: isApiError, isAborted: isAborted, blocks: blocks)
    }

    private func toolUse(_ id: String, name: String, input: String) -> ContentBlock {
        ContentBlock(id: "\(id)#0", index: 0, kind: .toolUse, text: input,
                     toolName: name, toolUseId: id)
    }

    private func toolResult(_ id: String, isError: Bool) -> ContentBlock {
        ContentBlock(id: "\(id)#r", index: 0, kind: .toolResult, text: "sortie",
                     toolUseId: id, isError: isError)
    }

    private func evaluate(_ messages: [SessionMessage]) -> SessionHealth {
        SessionHealthRule.evaluate(messages: messages, session: session)
    }

    func testCleanSessionScoresAnA() {
        let health = evaluate([
            message("u", role: .user),
            message("a", blocks: [ContentBlock(id: "a#0", index: 0, kind: .text, text: "ok")]),
        ])
        XCTAssertEqual(health.score, 100)
        XCTAssertEqual(health.grade, .a)
        XCTAssertEqual(health.evidence, ["Aucune erreur détectée."])
    }

    func testApiErrorsCostFifteenEach() {
        let health = evaluate([message("a1", isApiError: true), message("a2", isApiError: true)])
        // 100 − 15 × 2 − 10 (the session ends on an error) = 60.
        XCTAssertEqual(health.score, 60)
        XCTAssertEqual(health.grade, .c)
        XCTAssertTrue(health.evidence.contains("2 erreurs d'API pendant la session."))
        XCTAssertTrue(health.evidence.contains("La session se termine sur une erreur."))
    }

    func testToolErrorsCostThreeEachAndAreCappedAtThirty() {
        let many = (0..<20).map { index in
            message("a\(index)", blocks: [
                toolUse("t\(index)", name: "Bash", input: "commande \(index)"),
                toolResult("t\(index)", isError: true),
            ])
        }
        let health = evaluate(many + [message("last", blocks: [
            ContentBlock(id: "last#0", index: 0, kind: .text, text: "fini"),
        ])])
        // 100 − 30 (capped) = 70, with no penalty for the ending since the last turn is clean.
        XCTAssertEqual(health.score, 70)
        XCTAssertEqual(health.grade, .c)
        XCTAssertTrue(health.evidence.contains("20 appels d'outil en échec sur 20."))
    }

    func testInterruptedTurnsCostTen() {
        let health = evaluate([
            message("u", role: .user),
            message("a", blocks: [
                ContentBlock(id: "a#0", index: 0, kind: .text, text: "coupé"),
            ], isAborted: true),
        ])
        XCTAssertEqual(health.score, 90)
        XCTAssertEqual(health.grade, .a)
        XCTAssertTrue(health.evidence.contains("Un tour a été interrompu."))
    }

    /// The same call failing over and over is what a stuck agent looks like.
    func testThreeIdenticalConsecutiveFailuresCostTen() {
        let repeated = (0..<3).map { index in
            message("a\(index)", blocks: [
                toolUse("t\(index)", name: "Bash", input: "swift build"),
                toolResult("t\(index)", isError: true),
            ])
        }
        let health = evaluate(repeated)
        // 100 − 9 (three tool errors) − 10 (ends on an error) − 10 (the loop) = 71.
        XCTAssertEqual(health.score, 71)
        XCTAssertTrue(health.evidence.contains("Le même appel d'outil a échoué 3 fois de suite."))
    }

    func testDifferentFailingCallsAreNotALoop() {
        let varied = (0..<3).map { index in
            message("a\(index)", blocks: [
                toolUse("t\(index)", name: "Bash", input: "commande \(index)"),
                toolResult("t\(index)", isError: true),
            ])
        }
        XCTAssertEqual(SessionHealthRule.longestFailureRun(in: varied), 1)
        XCTAssertFalse(evaluate(varied).evidence.contains { $0.contains("fois de suite") })
    }

    func testASuccessBreaksTheFailureRun() {
        let messages = [
            message("a1", blocks: [toolUse("t1", name: "Bash", input: "x"), toolResult("t1", isError: true)]),
            message("a2", blocks: [toolUse("t2", name: "Bash", input: "x"), toolResult("t2", isError: false)]),
            message("a3", blocks: [toolUse("t3", name: "Bash", input: "x"), toolResult("t3", isError: true)]),
        ]
        XCTAssertEqual(SessionHealthRule.longestFailureRun(in: messages), 1)
    }

    func testScoreIsClampedToZeroAndGradesAtEveryBoundary() {
        let disastrous = (0..<12).map { message("a\($0)", isApiError: true) }
        let health = evaluate(disastrous)
        XCTAssertEqual(health.score, 0, "le score ne descend jamais sous zéro")
        XCTAssertEqual(health.grade, .f)

        XCTAssertEqual(SessionHealthRule.grade(for: 100), .a)
        XCTAssertEqual(SessionHealthRule.grade(for: 90), .a)
        XCTAssertEqual(SessionHealthRule.grade(for: 89), .b)
        XCTAssertEqual(SessionHealthRule.grade(for: 75), .b)
        XCTAssertEqual(SessionHealthRule.grade(for: 74), .c)
        XCTAssertEqual(SessionHealthRule.grade(for: 60), .c)
        XCTAssertEqual(SessionHealthRule.grade(for: 59), .d)
        XCTAssertEqual(SessionHealthRule.grade(for: 40), .d)
        XCTAssertEqual(SessionHealthRule.grade(for: 39), .f)
        XCTAssertEqual(SessionHealthRule.grade(for: 0), .f)
    }

    /// End to end, over the demo transcript: one failing Bash call plus the API error it
    /// finishes on.
    func testGradesAnIndexedSession() async throws {
        let fixture = try TranscriptFixture()
        try fixture.writeDemoSession()
        let service = fixture.service()
        try await service.index()

        let health = try await service.health(sessionId: Line.session)
        // 100 − 15 (one API error) − 3 (one tool error) − 10 (ends on an error) = 72.
        XCTAssertEqual(health.score, 72)
        XCTAssertEqual(health.grade, .c)
        XCTAssertTrue(health.evidence.contains("Une erreur d'API pendant la session."))
        XCTAssertTrue(health.evidence.contains("1 appel d'outil en échec sur 5."))
    }

    func testHealthOfAnUnknownSessionThrows() async throws {
        let fixture = try TranscriptFixture()
        let service = fixture.service()
        try await service.index()
        do {
            _ = try await service.health(sessionId: "jamais-vue")
            XCTFail("une session inconnue doit remonter une erreur")
        } catch let error as SessionsError {
            XCTAssertEqual(error, .unknownSession("jamais-vue"))
        }
    }
}
