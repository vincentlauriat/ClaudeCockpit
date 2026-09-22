import Foundation
import CockpitShared

/// Finds projects owning a `.claude/` directory under a set of roots.
///
/// Designed to be cheap on large, cloud-synced trees: it walks with POSIX
/// `readdir`/`lstat` (no Foundation resource fetches, symlinks never followed),
/// stops at `maxDepth` levels below each root, never descends into a directory
/// already recognised as a project, hidden directories, or the usual build
/// caches, and gives up politely when the `deadline` passes, returning what it
/// found so far.
public struct ProjectScanner: Sendable {
    public static let ignoredDirectoryNames: Set<String> = [
        "node_modules", ".build", "DerivedData", "Pods", ".git", "vendor",
        "build", "dist", "target", "Library", "Applications",
    ]

    public init() {}

    public static func scan(roots: [URL], maxDepth: Int = 2, timeBudget: TimeInterval = 4) -> [ProjectRef] {
        ProjectScanner().scan(roots: roots, maxDepth: maxDepth, timeBudget: timeBudget)
    }

    public func scan(roots: [URL], maxDepth: Int = 2, timeBudget: TimeInterval = 4) -> [ProjectRef] {
        var found: [String: ProjectRef] = [:]
        let deadline = Date().addingTimeInterval(timeBudget)
        for root in roots {
            visit(root.standardizedFileURL.path, depth: 0, maxDepth: maxDepth, deadline: deadline, into: &found)
        }
        return found.values.sorted { left, right in
            let order = left.name.localizedStandardCompare(right.name)
            if order != .orderedSame { return order == .orderedAscending }
            return left.id < right.id
        }
    }

    // MARK: - POSIX walk

    private func isDirectory(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    private func visit(_ path: String, depth: Int, maxDepth: Int, deadline: Date, into found: inout [String: ProjectRef]) {
        guard depth <= maxDepth, Date() < deadline, isDirectory(path) else { return }

        // A project is a directory holding `.claude/`. Do not descend into it.
        if depth > 0, isDirectory(path + "/.claude") {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let project = ProjectRef(name: url.lastPathComponent, url: url)
            found[project.id] = project
            return
        }

        guard depth < maxDepth, let dir = opendir(path) else { return }
        defer { closedir(dir) }
        while let entry = readdir(dir) {
            if Date() >= deadline { return }
            let name = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name == "." || name == ".." || name.hasPrefix(".") || Self.ignoredDirectoryNames.contains(name) { continue }
            // DT_DIR avoids a stat per entry; DT_UNKNOWN (some filesystems) falls back to lstat.
            let type = Int32(entry.pointee.d_type)
            if type == DT_LNK { continue }
            let child = path + "/" + name
            if type == DT_DIR || (type == DT_UNKNOWN && isDirectory(child)) {
                visit(child, depth: depth + 1, maxDepth: maxDepth, deadline: deadline, into: &found)
            }
        }
    }
}
