import XCTest
@testable import CockpitShared

final class FRFormatTests: XCTestCase {
    func testTokens() {
        XCTAssertEqual(FRFormat.tokens(999), "999")
        XCTAssertEqual(FRFormat.tokens(12_345), "12,3 k")
        XCTAssertEqual(FRFormat.tokens(250_000), "250 k")
        XCTAssertEqual(FRFormat.tokens(1_260_000), "1,3 M")
        XCTAssertEqual(FRFormat.tokens(2_500_000_000), "2,5 G")
    }

    func testDuration() {
        XCTAssertEqual(FRFormat.duration(30), "30 s")
        XCTAssertEqual(FRFormat.duration(125), "2 min")
        XCTAssertEqual(FRFormat.duration(7_500), "2 h 05")
        XCTAssertEqual(FRFormat.duration(3 * 86_400 + 3_600), "3 j 1 h")
    }

    func testPercent() {
        XCTAssertEqual(FRFormat.percent(0.42), "42 %")
        XCTAssertEqual(FRFormat.percent(42.5, fraction: false, digits: 1), "42,5 %")
    }
}
