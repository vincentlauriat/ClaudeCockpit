import XCTest
@testable import QuotaKit

final class QuotaAPIParsingGuardTests: XCTestCase {
    func testAbsurdUtilizationIsIgnored() throws {
        let json = """
        {"five_hour": {"utilization": 1e300, "resets_at": "2026-09-22T10:00:00Z"},
         "seven_day": {"utilization": 34.5, "resets_at": "2026-09-25T18:00:00Z"}}
        """
        let snapshot = try QuotaAPI.parse(Data(json.utf8), fetchedAt: Date())
        XCTAssertNil(snapshot.session, "an out-of-range meter must be dropped, not crash the menu bar label")
        XCTAssertEqual(snapshot.week?.utilization, 34.5)
    }

    func testNegativeUtilizationClampsToZero() throws {
        let json = """
        {"seven_day": {"utilization": -0.5, "resets_at": "2026-09-25T18:00:00Z"}}
        """
        let snapshot = try QuotaAPI.parse(Data(json.utf8), fetchedAt: Date())
        XCTAssertEqual(snapshot.week?.utilization, 0)
    }
}
