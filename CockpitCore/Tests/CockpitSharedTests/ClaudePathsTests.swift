import XCTest
@testable import CockpitShared

final class ClaudePathsTests: XCTestCase {
    func testDerivedPaths() {
        let home = URL(fileURLWithPath: "/tmp/home")
        let p = ClaudePaths(home: home)
        XCTAssertEqual(p.claudeDir.path, "/tmp/home/.claude")
        XCTAssertEqual(p.libraryDir.path, "/tmp/home/.claude/skillmanager/library")
        XCTAssertTrue(p.isInsideHome(URL(fileURLWithPath: "/tmp/home/.claude/skills/x")))
        XCTAssertFalse(p.isInsideHome(URL(fileURLWithPath: "/etc/passwd")))
        XCTAssertFalse(p.isInsideHome(URL(fileURLWithPath: "/tmp/home2/x")))
    }

    func testConfigDirOverride() {
        let p = ClaudePaths(home: URL(fileURLWithPath: "/tmp/home"), configDir: URL(fileURLWithPath: "/tmp/cfg"))
        XCTAssertEqual(p.claudeDir.path, "/tmp/cfg")
        XCTAssertEqual(p.skillsDir.path, "/tmp/cfg/skills")
        XCTAssertEqual(p.appSupportDir.path, "/tmp/home/Library/Application Support/ClaudeCockpit")
    }
}
