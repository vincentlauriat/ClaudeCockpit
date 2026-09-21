import XCTest
@testable import RTKKit

final class RTKKitSmokeTests: XCTestCase {
    func testModuleName() { XCTAssertEqual(RTKKitModule.name, "RTKKit") }
}
