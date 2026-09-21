import XCTest
@testable import QuotaKit

final class PaceMathTests: XCTestCase {
    /// Fixed instant: 2026-09-21 12:00:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_789_128_000)

    private func weekMeter(utilization: Double, hoursUntilReset: Double) -> Meter {
        Meter(key: "seven_day", name: "all", utilization: utilization,
              resetsAt: now.addingTimeInterval(hoursUntilReset * 3600), windowHours: 168)
    }

    func testProjectionSplitsTheWindowAtNow() throws {
        // 84 h left in a 168 h window → 84 h elapsed.
        let projection = try XCTUnwrap(
            UsageMath.projection(for: weekMeter(utilization: 50, hoursUntilReset: 84), now: now))
        XCTAssertEqual(projection.hoursElapsed, 84, accuracy: 0.0001)
        XCTAssertEqual(projection.hoursLeft, 84, accuracy: 0.0001)
        XCTAssertEqual(projection.used, 50)
    }

    func testLandingSustainableRateAndDailyBudget() throws {
        let projection = try XCTUnwrap(
            UsageMath.projection(for: weekMeter(utilization: 50, hoursUntilReset: 84), now: now))
        // Half the window burned in half the window → lands exactly on 100.
        XCTAssertEqual(projection.landing, 100, accuracy: 0.0001)
        XCTAssertFalse(projection.isOver)
        XCTAssertEqual(projection.runningPerHour, 50 / 84, accuracy: 0.0001)
        XCTAssertEqual(projection.neededPerHour, 50 / 84, accuracy: 0.0001)
        XCTAssertEqual(projection.remaining, 50, accuracy: 0.0001)
        XCTAssertEqual(projection.daysLeft, 3.5, accuracy: 0.0001)
        // 50 % spread over 3,5 days.
        XCTAssertEqual(projection.evenSharePerDay, 50 / 3.5, accuracy: 0.0001)
    }

    func testOverspendingIsFlagged() throws {
        // 90 % burned with two thirds of the window gone → lands at 135 %.
        let projection = try XCTUnwrap(
            UsageMath.projection(for: weekMeter(utilization: 90, hoursUntilReset: 56), now: now))
        XCTAssertEqual(projection.landing, 135, accuracy: 0.0001)
        XCTAssertTrue(projection.isOver)
        XCTAssertEqual(projection.neededPerHour, 10 / 56, accuracy: 0.0001)
    }

    func testZeroRemainingDaysFallsBackToTheRemainingQuota() throws {
        let projection = try XCTUnwrap(
            UsageMath.projection(for: weekMeter(utilization: 70, hoursUntilReset: 0), now: now))
        XCTAssertEqual(projection.hoursLeft, 0)
        XCTAssertEqual(projection.daysLeft, 0)
        XCTAssertEqual(projection.neededPerHour, 0, "no time left means no sustainable rate")
        XCTAssertEqual(projection.evenSharePerDay, 30, accuracy: 0.0001)
        XCTAssertEqual(projection.landing, 70, accuracy: 0.0001)
    }

    func testFullyUsedWindowHasNothingLeftToSpend() throws {
        let projection = try XCTUnwrap(
            UsageMath.projection(for: weekMeter(utilization: 100, hoursUntilReset: 24), now: now))
        XCTAssertEqual(projection.remaining, 0)
        XCTAssertEqual(projection.neededPerHour, 0)
        XCTAssertEqual(projection.evenSharePerDay, 0)
        XCTAssertTrue(projection.isOver)
        XCTAssertEqual(PaceSentence.pace(projection),
                       "Quota épuisé. Il se recharge à la réinitialisation.")
    }

    func testOverageAboveOneHundredKeepsRemainingAtZero() throws {
        let projection = try XCTUnwrap(
            UsageMath.projection(for: weekMeter(utilization: 112, hoursUntilReset: 24), now: now))
        XCTAssertEqual(projection.remaining, 0)
        XCTAssertEqual(projection.evenSharePerDay, 0)
    }

    func testElapsedTimeIsClampedToTheWindow() throws {
        // Reset already in the past: elapsed caps at the window, nothing goes negative.
        let meter = Meter(key: "seven_day", name: "all", utilization: 40,
                          resetsAt: now.addingTimeInterval(-3600), windowHours: 168)
        let projection = try XCTUnwrap(UsageMath.projection(for: meter, now: now))
        XCTAssertEqual(projection.hoursElapsed, 168, accuracy: 0.0001)
        XCTAssertEqual(projection.hoursLeft, 0)
    }

    func testFreshWindowProjectionIsNotMeaningful() throws {
        // 12 % three minutes into a 5-hour window reads as 254 %/h — the guard rejects it.
        let session = Meter(key: "five_hour", name: "session", utilization: 12,
                            resetsAt: now.addingTimeInterval(4.95 * 3600), windowHours: 5)
        let projection = try XCTUnwrap(UsageMath.projection(for: session, now: now))
        XCTAssertGreaterThan(projection.landing, 1000)
        XCTAssertFalse(projection.isMeaningful)
    }

    func testEstablishedWindowProjectionIsMeaningful() throws {
        let session = Meter(key: "five_hour", name: "session", utilization: 40,
                            resetsAt: now.addingTimeInterval(2 * 3600), windowHours: 5)
        let projection = try XCTUnwrap(UsageMath.projection(for: session, now: now))
        XCTAssertTrue(projection.isMeaningful)
    }

    func testProjectionIsNilWithoutResetDate() {
        let meter = Meter(key: "seven_day_nimbus_quill", name: "nimbus_quill",
                          utilization: 3.5, resetsAt: nil, windowHours: 168)
        XCTAssertNil(UsageMath.projection(for: meter, now: now))
    }

    func testWeekStartUsesTheWeeklyResetWhenAvailable() {
        let snapshot = GaugeSnapshot(fetchedAt: now, session: nil,
                                     week: weekMeter(utilization: 50, hoursUntilReset: 84),
                                     models: [])
        let expected = now.addingTimeInterval(84 * 3600 - 7 * 86_400)
        XCTAssertEqual(UsageMath.weekStart(gauge: snapshot, now: now).timeIntervalSince1970,
                       expected.timeIntervalSince1970, accuracy: 0.0001)
    }

    func testWeekStartFallsBackToSevenDaysAgo() {
        XCTAssertEqual(UsageMath.weekStart(gauge: nil, now: now).timeIntervalSince1970,
                       now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970, accuracy: 0.0001)
    }

    func testPaceSentences() throws {
        let comfortable = try XCTUnwrap(
            UsageMath.projection(for: weekMeter(utilization: 40, hoursUntilReset: 84), now: now))
        XCTAssertEqual(PaceSentence.pace(comfortable),
                       "À ce rythme, le quota finira la semaine à 80 % : la marge est suffisante.")

        let over = try XCTUnwrap(
            UsageMath.projection(for: weekMeter(utilization: 90, hoursUntilReset: 56), now: now))
        XCTAssertEqual(PaceSentence.pace(over),
                       "À ce rythme, le quota atteint 135 % : il sera épuisé avant la réinitialisation.")
        XCTAssertTrue(PaceSentence.rates(over).hasPrefix("Rythme actuel 0,80 %/h"))
    }
}
