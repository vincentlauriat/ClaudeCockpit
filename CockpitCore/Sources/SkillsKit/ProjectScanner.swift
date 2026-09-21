import Foundation
import CockpitShared

/// Finds projects owning a `.claude/` directory under a set of roots.
///
/// Scanning stops at `maxDepth` levels below each root and never descends into
/// a directory already recognised as a project, hidden directories, or the
/// usual build caches.
public struct ProjectScanner: Sendable {
    public static let ignoredDirectoryNames: Set<String> = [
        "node_modules", ".build", "DerivedData", "Pods", ".git", "vendor",
    ]

    public init() {}

    public static func scan(roots: [URL], maxDepth: Int = 3) -> [ProjectRef] {
        ProjectScanner().scan(roots: roots, maxDepth: maxDepth)
    }

    public func scan(roots: [URL], maxDepth: Int = 3) -> [ProjectRef] {
        var found: [String: ProjectRef] = [:]
        for root in roots {
            visit(root, depth: 0, maxDepth: maxDepth, into: &found)
        }
        return found.values.sorted { left, right in
            let order = left.name.localizedStandardCompare(right.name)
            if order != .orderedSame { return order == .orderedAscending }
            return left.id < right.id
        }
    }

    private func visit(_ directory: URL, depth: Int, maxDepth: Int, into found: inout [String: ProjectRef]) {
        guard depth <= maxDepth else { return }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }

        // A project is a directory holding `.claude/`. Do not descend into it.
        if depth > 0 {
            let dotClaude = directory.appendingPathComponent(".claude", isDirectory: true)
            var dotClaudeIsDirectory: ObjCBool = false
            if fm.fileExists(atPath: dotClaude.path, isDirectory: &dotClaudeIsDirectory), dotClaudeIsDirectory.boolValue {
                let project = ProjectRef(name: directory.lastPathComponent, url: directory.standardizedFileURL)
                found[project.id] = project
                return
            }
        }

        guard depth < maxDepth else { return }
        let entries = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") || Self.ignoredDirectoryNames.contains(name) { continue }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            visit(entry, depth: depth + 1, maxDepth: maxDepth, into: &found)
        }
    }
}
