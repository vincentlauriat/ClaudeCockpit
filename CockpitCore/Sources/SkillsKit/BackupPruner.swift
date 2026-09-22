import Foundation
import CockpitShared

/// Removes old backup roots created by `ResourceStore` under `paths.backupsDir`.
/// Roots are named `yyyyMMdd-HHmmss`; anything older than `maxAge` (default 30
/// days) is deleted. Unknown entries are left alone.
public enum BackupPruner {
    public static let defaultMaxAge: TimeInterval = 30 * 86_400

    /// Returns the URLs that were removed.
    @discardableResult
    public static func prune(paths: ClaudePaths, maxAge: TimeInterval = defaultMaxAge, now: Date = Date(),
                             fileManager: FileManager = .default) -> [URL] {
        let root = paths.backupsDir
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles]) else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var removed: [URL] = []
        for entry in entries {
            // Roots are `yyyyMMdd-HHmmss`, optionally suffixed `-2`, `-3`… within the same second.
            let name = entry.lastPathComponent
            guard name.count >= 15, name.count == 15 || name.dropFirst(15).hasPrefix("-"),
                  let stamp = formatter.date(from: String(name.prefix(15))) else { continue }
            guard now.timeIntervalSince(stamp) > maxAge else { continue }
            if (try? fileManager.removeItem(at: entry)) != nil { removed.append(entry) }
        }
        return removed
    }
}
