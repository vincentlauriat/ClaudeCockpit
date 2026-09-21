import XCTest
@testable import CockpitShared

final class CockpitSharedSmokeTests: XCTestCase {
    func testModuleName() { XCTAssertEqual(CockpitSharedModule.name, "CockpitShared") }
}
