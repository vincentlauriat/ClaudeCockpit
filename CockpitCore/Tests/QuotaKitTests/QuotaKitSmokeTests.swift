import XCTest
@testable import QuotaKit

final class QuotaKitSmokeTests: XCTestCase {
    func testModuleName() { XCTAssertEqual(QuotaKitModule.name, "QuotaKit") }
}
