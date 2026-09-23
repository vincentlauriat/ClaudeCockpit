import XCTest
import CockpitShared
@testable import SessionsKit

/// The health grade is deterministic and LLM-free, so every rule is pinned to a number.
///
/// The scale weighs **rates**, not counts. On the real corpus the error rate barely moves
/// with session length while the count grows with it, so scoring counts graded duration.
final class SessionHealthTests: XCTestCase {

    private func evaluate(
        toolCalls: Int = 100, toolErrors: Int = 0, apiErrors: Int = 0,
        assistantTurns: Int = 100, abortedTurns: Int = 0, repeatedFailures: Int = 0,
        endedOnError: Bool = false
    ) -> SessionHealth {
        SessionHealthRule.evaluate(SessionHealthCounters(
            toolCalls: toolCalls, toolErrors: toolErrors, apiErrors: apiErrors,
            assistantTurns: assistantTurns, abortedTurns: abortedTurns,
            repeatedFailures: repeatedFailures, endedOnError: endedOnError))
    }

    func testCleanSessionScoresAnA() {
        let health = evaluate()
        XCTAssertEqual(health.score, 100)
        XCTAssertEqual(health.grade, .a)
        XCTAssertEqual(health.evidence, ["Aucune erreur détectée."])
        XCTAssertEqual(SessionHealthRule.evaluate(.clean).grade, .a)
    }

    /// The invariant the old scale broke: two sessions with the same error rate deserve the
    /// same grade whether they ran 20 tool calls or 200.
    func testSameErrorRateScoresTheSameWhateverTheSize() {
        let small = evaluate(toolCalls: 20, toolErrors: 1, assistantTurns: 8)
        let large = evaluate(toolCalls: 200, toolErrors: 10, assistantTurns: 800)
        XCTAssertEqual(small.score, large.score)
        XCTAssertEqual(small.grade, large.grade)
        XCTAssertEqual(small.score, 88)  // 100 − (5 % − 2 %) × 400
    }

    /// The case that motivated the change: a long session that shipped a release, scored F by
    /// the old count-based scale, is an A once its 4,3 % error rate is what counts.
    func testALongProductiveSessionIsNotPunishedForItsLength() {
        let health = evaluate(toolCalls: 325, toolErrors: 14, assistantTurns: 1_281)
        XCTAssertEqual(health.score, 91)
        XCTAssertEqual(health.grade, .a)
        XCTAssertEqual(evaluate(toolCalls: 325, toolErrors: 17, assistantTurns: 1_281).grade, .b)
    }

    func testToolErrorsAreFreeBelowTwoPercentAndCappedAtThirty() {
        XCTAssertEqual(evaluate(toolCalls: 100, toolErrors: 2).score, 100, "2 % est le plancher")
        XCTAssertEqual(evaluate(toolCalls: 100, toolErrors: 1).score, 100)
        XCTAssertEqual(evaluate(toolCalls: 100, toolErrors: 5).score, 88)
        XCTAssertEqual(evaluate(toolCalls: 100, toolErrors: 10).score, 70, "10 % atteint le plafond")
        XCTAssertEqual(evaluate(toolCalls: 100, toolErrors: 100).score, 70, "et n'en bouge plus")
    }

    /// A session that called no tool has no tool error rate; it must not be graded on one.
    func testASessionWithoutToolCallsIsNotPenalised() {
        let health = evaluate(toolCalls: 0, toolErrors: 0, assistantTurns: 12)
        XCTAssertEqual(health.score, 100)
        XCTAssertEqual(health.grade, .a)
        XCTAssertEqual(health.evidence, ["Aucune erreur détectée."])
    }

    func testApiErrorsAreWeighedAgainstTheTurnsTheyInterrupted() {
        XCTAssertEqual(evaluate(apiErrors: 1, assistantTurns: 200).score, 95)   // 0,5 %
        XCTAssertEqual(evaluate(apiErrors: 5, assistantTurns: 200).score, 75)   // 2,5 %, plafond
        XCTAssertEqual(evaluate(apiErrors: 50, assistantTurns: 200).score, 75)
    }

    func testEndingOnAnErrorCostsFifteen() {
        XCTAssertEqual(evaluate(endedOnError: true).score, 85)
        XCTAssertTrue(evaluate(endedOnError: true).evidence
            .contains("La session se termine sur une erreur."))
    }

    func testInterruptionsCostMoreWhenTheyAreAHabit() {
        XCTAssertEqual(evaluate(assistantTurns: 200, abortedTurns: 1).score, 95, "0,5 % : un accident")
        XCTAssertEqual(evaluate(assistantTurns: 20, abortedTurns: 4).score, 90, "20 % : une habitude")
    }

    func testRepeatedFailuresCostTenOnceThereAreThree() {
        XCTAssertEqual(evaluate(repeatedFailures: 2).score, 100, "deux fois n'est pas une boucle")
        let loop = evaluate(repeatedFailures: 3)
        XCTAssertEqual(loop.score, 90)
        XCTAssertTrue(loop.evidence.contains("Le même appel d'outil a échoué 3 fois de suite."))
    }

    /// Evidence has to carry the rate, or the sentence looks like it contradicts the grade.
    func testEvidenceCitesRatesAndAgreesInFrench() {
        let many = evaluate(toolCalls: 325, toolErrors: 14, assistantTurns: 1_281)
        XCTAssertEqual(many.evidence.first, "14 erreurs d'outil sur 325 appels, soit 4,3 %.")

        let one = evaluate(toolCalls: 32, toolErrors: 1, assistantTurns: 10)
        XCTAssertEqual(one.evidence.first, "1 erreur d'outil sur 32 appels, soit 3,1 %.")

        XCTAssertEqual(evaluate(apiErrors: 1, assistantTurns: 200).evidence.first,
                       "1 erreur d'API sur 200 tours assistant, soit 0,5 %.")
        XCTAssertEqual(evaluate(assistantTurns: 20, abortedTurns: 4).evidence.first,
                       "4 tours interrompus sur 20 tours assistant.")
        XCTAssertEqual(evaluate(assistantTurns: 20, abortedTurns: 1).evidence.first,
                       "1 tour interrompu sur 20 tours assistant.")
    }

    /// Every rule at once. Because each is capped, the worst reachable score is 10 rather
    /// than 0 — the floor is a property of the scale, not a clamp that can fire.
    func testWorstCaseAndGradesAtEveryBoundary() {
        let disastrous = evaluate(
            toolCalls: 10, toolErrors: 10, apiErrors: 10, assistantTurns: 10,
            abortedTurns: 10, repeatedFailures: 9, endedOnError: true)
        XCTAssertEqual(disastrous.score, 10)  // 100 − 30 − 25 − 15 − (5 + 5) − 10
        XCTAssertEqual(disastrous.grade, .f)
        XCTAssertEqual(disastrous.evidence.count, 5, "chaque règle doit s'expliquer")

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

    // MARK: - The run counter the indexer keeps

    func testFailureRunCountsOnlyIdenticalConsecutiveFailures() {
        let bash = SessionHealthRule.identityHash(toolName: "Bash", input: "swift build")
        var run = SessionHealthRule.FailureRun()
        for _ in 0..<4 { run.record(failed: true, identity: bash) }
        XCTAssertEqual(run.longest, 4)
    }

    func testDifferentCallsAreNotARun() {
        var run = SessionHealthRule.FailureRun()
        for index in 0..<5 {
            run.record(failed: true, identity: SessionHealthRule.identityHash(
                toolName: "Bash", input: "commande \(index)"))
        }
        XCTAssertEqual(run.longest, 1)
    }

    func testASuccessBreaksTheRun() {
        let bash = SessionHealthRule.identityHash(toolName: "Bash", input: "swift build")
        var run = SessionHealthRule.FailureRun()
        run.record(failed: true, identity: bash)
        run.record(failed: true, identity: bash)
        run.record(failed: false, identity: bash)
        run.record(failed: true, identity: bash)
        XCTAssertEqual(run.longest, 2)
        XCTAssertEqual(run.current, 1)
    }

    func testAnUnpairedResultBreaksTheRun() {
        let bash = SessionHealthRule.identityHash(toolName: "Bash", input: "x")
        var run = SessionHealthRule.FailureRun()
        run.record(failed: true, identity: bash)
        run.record(failed: true, identity: nil)
        run.record(failed: true, identity: bash)
        XCTAssertEqual(run.longest, 1)
    }

    /// The key is written to the database and compared against what a later process computes,
    /// so it must not depend on a per-process hash seed.
    func testIdentityHashIsStableAndDiscriminating() {
        XCTAssertEqual(
            SessionHealthRule.identityHash(toolName: "Bash", input: "ls"),
            SessionHealthRule.identityHash(toolName: "Bash", input: "ls"))
        XCTAssertNotEqual(
            SessionHealthRule.identityHash(toolName: "Bash", input: "ls"),
            SessionHealthRule.identityHash(toolName: "Bash", input: "pwd"))
        XCTAssertNotEqual(
            SessionHealthRule.identityHash(toolName: "Bash", input: "ls"),
            SessionHealthRule.identityHash(toolName: "Read", input: "ls"))
    }

    // MARK: - End to end

    func testGradesAnIndexedSessionFromStoredCounters() async throws {
        let fixture = try TranscriptFixture()
        try fixture.writeDemoSession()
        let service = fixture.service()
        try await service.index()

        let health = try await service.health(sessionId: Line.session)
        // Five tool calls with one failure is a 20 % rate, and one API error out of six turns
        // is 17 %: both cap out. 100 − 30 − 25 − 15 (ends on an error) = 30.
        XCTAssertEqual(health.score, 30)
        XCTAssertEqual(health.grade, .f)
        XCTAssertTrue(health.evidence.contains("1 erreur d'outil sur 5 appels, soit 20,0 %."),
                      "\(health.evidence)")
        XCTAssertTrue(health.evidence.contains("1 erreur d'API sur 6 tours assistant, soit 16,7 %."),
                      "\(health.evidence)")
    }

    /// The badge in the list and the verdict in the detail must never diverge — they are the
    /// same function over the same stored row.
    func testListBadgeMatchesTheDetailVerdict() async throws {
        let fixture = try TranscriptFixture()
        try fixture.writeDemoSession()
        try fixture.writeStuckSession()
        let service = fixture.service()
        try await service.index()

        var filter = SessionFilter()
        filter.includeSubagents = true
        let sessions = try await service.listSessions(filter)
        XCTAssertGreaterThan(sessions.count, 1)
        for session in sessions {
            let detail = try await service.health(sessionId: session.id)
            XCTAssertEqual(session.healthGrade, detail.grade, session.id)
        }
        XCTAssertTrue(sessions.contains { $0.healthGrade != .a }, "au moins une session notée")
    }

    /// Three identical failing calls in a row, counted while the transcript is indexed.
    func testDetectsARepeatedFailureLoopWhileIndexing() async throws {
        let fixture = try TranscriptFixture()
        try fixture.writeStuckSession()
        let service = fixture.service()
        try await service.index()

        let health = try await service.health(sessionId: Line.stuckSession)
        XCTAssertTrue(health.evidence.contains("Le même appel d'outil a échoué 3 fois de suite."),
                      "\(health.evidence)")
        // Three calls, three failures: the rate caps the tool penalty. 100 − 30 − 10 = 60.
        XCTAssertEqual(health.score, 60)
        XCTAssertEqual(health.grade, .c)
    }

    /// The run in progress has to survive the chunk boundary: the same three failures spread
    /// over two indexing passes must still count as a loop.
    func testARepeatedFailureLoopSurvivesAnIncrementalPass() async throws {
        let fixture = try TranscriptFixture()
        let path = try fixture.writeStuckSession(failures: 2)
        let service = fixture.service()
        try await service.index()
        var health = try await service.health(sessionId: Line.stuckSession)
        XCTAssertFalse(health.evidence.contains { $0.contains("fois de suite") })

        for line in Line.stuckFailure(index: 2) { try fixture.append(line, to: path) }
        try await service.index()

        health = try await service.health(sessionId: Line.stuckSession)
        XCTAssertTrue(health.evidence.contains("Le même appel d'outil a échoué 3 fois de suite."),
                      "\(health.evidence)")
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
