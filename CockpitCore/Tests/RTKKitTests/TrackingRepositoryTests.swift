import XCTest
import CockpitShared
@testable import RTKKit

final class TrackingRepositoryTests: XCTestCase {

    private var repository: TrackingRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let url = try Fixture.makeDatabase(in: makeTemporaryDirectory())
        repository = TrackingRepository(databaseURL: url)
    }

    // MARK: - Schema

    func testValidateSchemaAcceptsRealRtkSchema() throws {
        XCTAssertTrue(try repository.validateSchema())
    }

    func testValidateSchemaRejectsDatabaseWithoutCommandsTable() throws {
        let url = try Fixture.makeWrongSchemaDatabase(in: makeTemporaryDirectory())
        XCTAssertFalse(try TrackingRepository(databaseURL: url).validateSchema())
    }

    func testReadThrowsWhenFileIsMissing() {
        let missing = makeTemporaryDirectory().appendingPathComponent("history.db")
        XCTAssertThrowsError(try TrackingRepository(databaseURL: missing).recordCount()) { error in
            XCTAssertEqual(error as? RTKError, .databaseNotFound)
        }
    }

    // MARK: - Totals

    func testRecordCountMatchesFixture() throws {
        XCTAssertEqual(try repository.recordCount(), 20)
    }

    func testTodayTotalsCoverOnlyTheCurrentUTCDay() throws {
        let today = try repository.todayTotals(now: Fixture.now)
        XCTAssertEqual(today, TotalsStat(count: 4, inputTokens: 4500, outputTokens: 2000, savedTokens: 2500))
        XCTAssertEqual(today.savingsPct, 2500.0 / 4500.0 * 100, accuracy: 0.0001)
    }

    func testTodayTotalsAreZeroOnADayWithoutActivity() throws {
        // D-1 (2026-09-20) has no rows in the fixture.
        let quiet = try repository.todayTotals(now: Fixture.day(-1).addingTimeInterval(43_200))
        XCTAssertEqual(quiet, .zero)
        XCTAssertTrue(quiet.isEmpty)
        XCTAssertEqual(quiet.savingsPct, 0)
    }

    func testAllTimeTotalsAggregateEveryRow() throws {
        let allTime = try repository.allTimeTotals()
        XCTAssertEqual(allTime, TotalsStat(count: 20, inputTokens: 19_200, outputTokens: 8_350, savedTokens: 10_850))
        XCTAssertEqual(allTime.savingsPct, 10_850.0 / 19_200.0 * 100, accuracy: 0.0001)
    }

    // MARK: - Daily series

    func testDailyTotalsReturnExactlySevenChronologicalDays() throws {
        let days = try repository.dailyTotals(days: 7, now: Fixture.now)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.map(\.date), (-6...0).map { Fixture.day($0) })
        XCTAssertEqual(days.map(\.savedTokens), [550, 0, 0, 3_300, 1_500, 0, 2_500])
        XCTAssertEqual(days.map(\.count), [2, 0, 0, 5, 3, 0, 4])
    }

    func testDailyTotalsExcludeRowsOlderThanTheWindow() throws {
        // D-10 carries 3 000 saved tokens; none of it may leak into a 7-day series.
        let days = try repository.dailyTotals(days: 7, now: Fixture.now)
        XCTAssertEqual(days.reduce(0) { $0 + $1.savedTokens }, 7_850)
    }

    func testDailyTotalsHonourALongerWindow() throws {
        let days = try repository.dailyTotals(days: 14, now: Fixture.now)
        XCTAssertEqual(days.count, 14)
        XCTAssertEqual(days.reduce(0) { $0 + $1.count }, 20)
        XCTAssertEqual(days.first?.date, Fixture.day(-13))
    }

    func testDailyTotalsReturnEmptyForANonPositiveWindow() throws {
        XCTAssertTrue(try repository.dailyTotals(days: 0, now: Fixture.now).isEmpty)
    }

    // MARK: - By command

    func testByCommandRanksFiltersByTokensSaved() throws {
        let stats = try repository.byCommand(limit: 10)
        XCTAssertEqual(stats.map(\.name), ["rtk read", "rtk git log", "rtk tsc", "rtk grep", "rtk curl"])
        XCTAssertEqual(stats.map(\.savedTokens), [5_900, 1_950, 1_500, 1_000, 500])
        XCTAssertEqual(stats.map(\.count), [9, 5, 2, 3, 1])
        XCTAssertEqual(stats[0].savingsPct, 5_900.0 / 8_700.0 * 100, accuracy: 0.0001)
    }

    func testByCommandHonoursItsLimit() throws {
        let top2 = try repository.byCommand(limit: 2)
        XCTAssertEqual(top2.map(\.name), ["rtk read", "rtk git log"])
        XCTAssertTrue(try repository.byCommand(limit: 0).isEmpty)
    }

    // MARK: - Recent records

    func testRecentRecordsAreNewestFirstAndFullyMapped() throws {
        let recent = try repository.recentRecords(limit: 3)
        XCTAssertEqual(recent.map(\.rtkCommand), ["rtk grep", "rtk git log", "rtk read"])

        let newest = recent[0]
        XCTAssertEqual(newest.originalCommand, "grep x")
        XCTAssertEqual(newest.inputTokens, 1_000)
        XCTAssertEqual(newest.outputTokens, 1_000)
        XCTAssertEqual(newest.savedTokens, 0)
        XCTAssertEqual(newest.savingsPct, 0, accuracy: 0.0001)
        // 2026-09-21T04:00:00.123456+00:00 — microseconds must survive parsing.
        XCTAssertEqual(newest.timestamp.timeIntervalSince1970,
                       Fixture.day(0).timeIntervalSince1970 + 4 * 3_600 + 0.123,
                       accuracy: 0.001)
    }

    func testRecentRecordsHonourTheirLimit() throws {
        XCTAssertEqual(try repository.recentRecords(limit: 50).count, 20)
        XCTAssertTrue(try repository.recentRecords(limit: 0).isEmpty)
    }

    func testRecentRecordsAreEmptyOnAnEmptyTable() throws {
        let url = try Fixture.makeEmptyDatabase(in: makeTemporaryDirectory())
        let empty = TrackingRepository(databaseURL: url)
        XCTAssertTrue(try empty.recentRecords(limit: 5).isEmpty)
        XCTAssertEqual(try empty.recordCount(), 0)
        XCTAssertEqual(try empty.allTimeTotals(), .zero)
    }

    // MARK: - Database resolution

    func testResolveDatabaseFallsThroughToTheSecondCandidate() throws {
        let home = makeTemporaryDirectory()
        let paths = ClaudePaths(home: home)
        XCTAssertNil(TrackingRepository.resolveDatabase(paths: paths))

        let second = paths.rtkDatabaseCandidates[1]
        try Fixture.makeDatabase(in: second.deletingLastPathComponent())
        XCTAssertEqual(TrackingRepository.resolveDatabase(paths: paths), second)

        // Once the preferred location exists it wins.
        let first = paths.rtkDatabaseCandidates[0]
        try Fixture.makeDatabase(in: first.deletingLastPathComponent())
        XCTAssertEqual(TrackingRepository.resolveDatabase(paths: paths), first)
    }

    func testOverrideTakesPrecedenceOverEveryCandidate() throws {
        let home = makeTemporaryDirectory()
        let paths = ClaudePaths(home: home)
        try Fixture.makeDatabase(in: paths.rtkDatabaseCandidates[0].deletingLastPathComponent())

        let override = try Fixture.makeDatabase(in: makeTemporaryDirectory(), name: "custom.db")
        XCTAssertEqual(TrackingRepository.resolveDatabase(paths: paths, override: override), override)
    }

    func testMissingOverrideFailsRatherThanFallingBack() throws {
        let home = makeTemporaryDirectory()
        let paths = ClaudePaths(home: home)
        try Fixture.makeDatabase(in: paths.rtkDatabaseCandidates[0].deletingLastPathComponent())

        let ghost = makeTemporaryDirectory().appendingPathComponent("nowhere.db")
        XCTAssertNil(TrackingRepository.resolveDatabase(paths: paths, override: ghost))
    }
}
