import XCTest
import CockpitShared
@testable import RTKKit

final class RTKServiceTests: XCTestCase {

    /// A `ClaudePaths` rooted in a temp home whose preferred candidate holds the fixture.
    private func makeHomeWithDatabase() throws -> ClaudePaths {
        let paths = ClaudePaths(home: makeTemporaryDirectory())
        try Fixture.makeDatabase(in: paths.rtkDatabaseCandidates[0].deletingLastPathComponent())
        return paths
    }

    func testSnapshotAssemblesEveryFigureInOnePass() throws {
        let paths = try makeHomeWithDatabase()
        let service = RTKService(paths: paths)
        let snapshot = try service.snapshot(now: Fixture.now)

        XCTAssertEqual(snapshot.today, TotalsStat(count: 4, inputTokens: 4_500, outputTokens: 2_000, savedTokens: 2_500))
        XCTAssertEqual(snapshot.allTime, TotalsStat(count: 20, inputTokens: 19_200, outputTokens: 8_350, savedTokens: 10_850))
        XCTAssertEqual(snapshot.last7Days.count, 7)
        XCTAssertEqual(snapshot.byCommand.first?.name, "rtk read")
        XCTAssertEqual(snapshot.recent.count, 20)
        XCTAssertEqual(snapshot.generatedAt, Fixture.now)
        XCTAssertEqual(snapshot.databaseURL, paths.rtkDatabaseCandidates[0])
    }

    func testSnapshotConveniencesMatchTheAllTimeTotals() throws {
        let service = RTKService(paths: try makeHomeWithDatabase())
        let snapshot = try service.snapshot(now: Fixture.now)

        XCTAssertEqual(snapshot.savedTodayTokens, 2_500)
        XCTAssertEqual(snapshot.compressionRatio, 8_350.0 / 19_200.0, accuracy: 0.0001)
        let lastActivity = try XCTUnwrap(snapshot.lastActivity)
        XCTAssertEqual(lastActivity.timeIntervalSince1970,
                       Fixture.day(0).timeIntervalSince1970 + 4 * 3_600 + 0.123,
                       accuracy: 0.001)
    }

    func testSnapshotLimitsArePassedThrough() throws {
        let service = RTKService(paths: try makeHomeWithDatabase())
        let snapshot = try service.snapshot(now: Fixture.now, days: 3, commandLimit: 2, recentLimit: 5)

        XCTAssertEqual(snapshot.last7Days.count, 3)
        XCTAssertEqual(snapshot.byCommand.count, 2)
        XCTAssertEqual(snapshot.recent.count, 5)
    }

    func testEmptySnapshotIsAllZero() {
        let url = URL(fileURLWithPath: "/tmp/history.db")
        let snapshot = RTKSnapshot.empty(databaseURL: url, generatedAt: Fixture.now)

        XCTAssertEqual(snapshot.today, .zero)
        XCTAssertEqual(snapshot.allTime, .zero)
        XCTAssertEqual(snapshot.compressionRatio, 0)
        XCTAssertNil(snapshot.lastActivity)
    }

    // MARK: - Failure modes

    func testSnapshotReportsAMissingDatabase() {
        let service = RTKService(paths: ClaudePaths(home: makeTemporaryDirectory()))
        XCTAssertNil(service.databaseURL)
        XCTAssertThrowsError(try service.snapshot(now: Fixture.now)) { error in
            XCTAssertEqual(error as? RTKError, .databaseNotFound)
        }
    }

    func testSnapshotReportsAnIncompatibleSchema() throws {
        let paths = ClaudePaths(home: makeTemporaryDirectory())
        try Fixture.makeWrongSchemaDatabase(in: paths.rtkDatabaseCandidates[0].deletingLastPathComponent())

        let service = RTKService(paths: paths)
        XCTAssertThrowsError(try service.snapshot(now: Fixture.now)) { error in
            XCTAssertEqual(error as? RTKError, .invalidSchema)
        }
    }

    func testOverridePathWins() throws {
        let paths = try makeHomeWithDatabase()
        let override = try Fixture.makeDatabase(in: makeTemporaryDirectory(), name: "custom.db")

        let service = RTKService(paths: paths, overridePath: override)
        XCTAssertEqual(service.databaseURL, override)
        XCTAssertEqual(try service.snapshot(now: Fixture.now).databaseURL, override)
    }

    func testMissingOverrideDoesNotSilentlyReadAnotherDatabase() throws {
        let paths = try makeHomeWithDatabase()
        let ghost = makeTemporaryDirectory().appendingPathComponent("nowhere.db")

        let service = RTKService(paths: paths, overridePath: ghost)
        XCTAssertNil(service.databaseURL)
        XCTAssertThrowsError(try service.snapshot(now: Fixture.now)) { error in
            XCTAssertEqual(error as? RTKError, .databaseNotFound)
        }
    }

    func testChangesFinishImmediatelyWithoutADatabase() async {
        let service = RTKService(paths: ClaudePaths(home: makeTemporaryDirectory()))
        var ticks = 0
        for await _ in service.changes { ticks += 1 }
        XCTAssertEqual(ticks, 0)
    }

    func testErrorMessagesAreLocalised() {
        XCTAssertNotNil(RTKError.databaseNotFound.errorDescription)
        XCTAssertNotNil(RTKError.invalidSchema.errorDescription)
        XCTAssertEqual(RTKError.sqlite("boom").errorDescription, "Erreur SQLite : boom")
    }
}
