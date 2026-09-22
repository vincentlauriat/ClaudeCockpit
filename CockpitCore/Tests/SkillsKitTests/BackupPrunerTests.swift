import XCTest
import CockpitShared
@testable import SkillsKit

final class BackupPrunerTests: XCTestCase {
    func testPrunesOnlyOldTimestampedRoots() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = ClaudePaths(home: home)
        let fm = FileManager.default
        let old = paths.backupsDir.appendingPathComponent("20260101-120000")
        let recent = paths.backupsDir.appendingPathComponent("20260921-120000")
        let foreign = paths.backupsDir.appendingPathComponent("notes")
        let oldSuffixed = paths.backupsDir.appendingPathComponent("20260101-120000-2")
        for dir in [old, recent, foreign, oldSuffixed] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("f.txt"))
        }
        let now = DateFormatter.cockpitStamp.date(from: "20260922-090000")!
        let removed = BackupPruner.prune(paths: paths, maxAge: 30 * 86_400, now: now)
        XCTAssertEqual(Set(removed.map(\.lastPathComponent)), ["20260101-120000", "20260101-120000-2"])
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: recent.path))
        XCTAssertTrue(fm.fileExists(atPath: foreign.path))
        try? fm.removeItem(at: home)
    }
}

private extension DateFormatter {
    static let cockpitStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
