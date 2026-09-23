import XCTest
@testable import SessionsKit

/// Grades taken from sessions that actually exist in the author's archive, so the rule is
/// pinned against real shapes rather than invented ones.
///
/// The bug these guard against: the first rule penalised the raw error *count*, so it graded
/// session length. A 1 281-turn session that shipped two releases came out F while an 8-turn
/// session came out A, and the badge taught the reader nothing.
final class HealthRegressionTests: XCTestCase {

    private func grade(_ counters: SessionHealthCounters) -> (HealthGrade, Int) {
        let health = SessionHealthRule.evaluate(counters)
        return (health.grade, health.score)
    }

    /// The session that produced Claude Cockpit 1.0.0 and 1.0.1.
    func testLongProductiveSessionIsNotFailed() {
        let (grade, score) = grade(SessionHealthCounters(
            toolCalls: 342, toolErrors: 14, apiErrors: 4, assistantTurns: 891,
            abortedTurns: 0, repeatedFailures: 1, endedOnError: false))
        XCTAssertGreaterThanOrEqual(score, 75, "4,1 % d'erreurs d'outil ne vaut pas un échec")
        XCTAssertEqual(grade, .b)
    }

    /// Same error rate, a quarter of the size: the grade must not move. This is the invariant
    /// the count-based rule broke.
    ///
    /// Both samples are large enough for a 5 % rate to mean something. The original short
    /// case, 20 calls with 1 failure, sits below that: there the per-failure ceiling governs
    /// instead, which is the point of `testATinySampleIsNotGradedOnItsRate`.
    func testSameRateAtDifferentSizesGradesTheSame() {
        let long = grade(SessionHealthCounters(
            toolCalls: 400, toolErrors: 20, apiErrors: 0, assistantTurns: 1000,
            abortedTurns: 0, repeatedFailures: 0, endedOnError: false))
        let short = grade(SessionHealthCounters(
            toolCalls: 100, toolErrors: 5, apiErrors: 0, assistantTurns: 250,
            abortedTurns: 0, repeatedFailures: 0, endedOnError: false))
        XCTAssertEqual(long.0, short.0)
        XCTAssertEqual(long.1, short.1)
        XCTAssertEqual(long.0, .b)
    }

    /// A session that called no tool has no rate to speak of and must not be penalised on a
    /// division by a floor of one. 24 such sessions exist in the real archive.
    func testSessionWithoutAnyToolCallIsClean() {
        let (grade, score) = grade(SessionHealthCounters(
            toolCalls: 0, toolErrors: 0, apiErrors: 0, assistantTurns: 12,
            abortedTurns: 0, repeatedFailures: 0, endedOnError: false))
        XCTAssertEqual(grade, .a)
        XCTAssertEqual(score, 100)
    }

    /// A genuinely bad session must still be able to fail, or the grade says nothing either.
    func testAGenuinelyBadSessionStillFails() {
        let (grade, _) = grade(SessionHealthCounters(
            toolCalls: 40, toolErrors: 18, apiErrors: 9, assistantTurns: 60,
            abortedTurns: 6, repeatedFailures: 5, endedOnError: true))
        XCTAssertEqual(grade, .f)
    }
}
