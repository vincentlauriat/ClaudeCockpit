import XCTest
@testable import SkillsKit

final class SkillsKitSmokeTests: XCTestCase {
    func testModuleName() { XCTAssertEqual(SkillsKitModule.name, "SkillsKit") }
}
