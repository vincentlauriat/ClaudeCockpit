import XCTest
@testable import RTKKit

final class DBWatcherTests: XCTestCase {

    func testWatcherEmitsWhenTheDatabaseIsWritten() async throws {
        let directory = makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("history.db")

        let watcher = DBWatcher(databaseURL: database, debounce: 0.1, pollingInterval: nil)
        watcher.start()
        defer { watcher.stop() }

        let received = expectation(description: "change tick")
        let consumer = Task {
            for await _ in watcher.changes {
                received.fulfill()
                return
            }
        }
        defer { consumer.cancel() }

        // FSEvents needs the stream to be live before the write lands.
        try await Task.sleep(nanoseconds: 300_000_000)
        try Data("x".utf8).write(to: database)

        await fulfillment(of: [received], timeout: 5)
    }

    func testPollingFallbackEmitsWithoutAnyFileActivity() async throws {
        let directory = makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let watcher = DBWatcher(
            databaseURL: directory.appendingPathComponent("history.db"),
            debounce: 0.1,
            pollingInterval: 0.2)
        watcher.start()
        defer { watcher.stop() }

        let received = expectation(description: "poll tick")
        let consumer = Task {
            for await _ in watcher.changes {
                received.fulfill()
                return
            }
        }
        defer { consumer.cancel() }

        await fulfillment(of: [received], timeout: 5)
    }

    func testStopFinishesTheStreamAndIsIdempotent() async throws {
        let directory = makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let watcher = DBWatcher(
            databaseURL: directory.appendingPathComponent("history.db"),
            debounce: 0.1,
            pollingInterval: nil)
        watcher.start()

        let finished = expectation(description: "stream finished")
        Task {
            for await _ in watcher.changes {}
            finished.fulfill()
        }

        watcher.stop()
        watcher.stop()  // must not crash: the retained self-pointer is released once.

        await fulfillment(of: [finished], timeout: 5)
    }

    func testStopWithoutStartIsSafe() {
        let watcher = DBWatcher(databaseURL: URL(fileURLWithPath: "/tmp/history.db"))
        watcher.stop()
    }
}

final class RTKTimestampTests: XCTestCase {

    func testParsesRtkMicrosecondTimestamps() throws {
        let date = try XCTUnwrap(RTKTimestamp.parse("2026-09-21T21:11:11.312260+00:00"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_790_025_071.312, accuracy: 0.001)
    }

    func testParsesTimestampsWithoutAFractionalPart() throws {
        let date = try XCTUnwrap(RTKTimestamp.parse("2026-09-21T21:11:11Z"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_790_025_071, accuracy: 0.001)
    }

    func testParsesTimestampsWithMillisecondPrecision() throws {
        let date = try XCTUnwrap(RTKTimestamp.parse("2026-09-21T21:11:11.312Z"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_790_025_071.312, accuracy: 0.001)
    }

    func testRejectsGarbage() {
        XCTAssertNil(RTKTimestamp.parse("not a date"))
        XCTAssertNil(RTKTimestamp.parse(""))
    }
}

final class UTCDayTests: XCTestCase {

    func testLowerBoundSortsBeforeEveryRowOfItsDay() {
        let bound = UTCDay.lowerBound(Fixture.day(0))
        XCTAssertEqual(bound, "2026-09-21T00:00:00")
        XCTAssertLessThan(bound, "2026-09-21T00:00:00.000000+00:00")
        XCTAssertLessThan("2026-09-21T23:59:59.999999+00:00", UTCDay.lowerBound(Fixture.day(1)))
    }

    func testLabelIsTheUTCCalendarDay() {
        XCTAssertEqual(UTCDay.label(Fixture.now), "2026-09-21")
        XCTAssertEqual(UTCDay.label(Fixture.day(-6)), "2026-09-15")
    }

    func testStartOfDayIsMidnightUTC() {
        XCTAssertEqual(UTCDay.start(of: Fixture.now), Fixture.day(0))
        XCTAssertEqual(Fixture.now.timeIntervalSince(UTCDay.start(of: Fixture.now)), 43_200)
    }
}
