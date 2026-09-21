import XCTest
@testable import UsageKit

final class UsageKitSmokeTests: XCTestCase {
    func testModuleName() { XCTAssertEqual(UsageKitModule.name, "UsageKit") }
}
