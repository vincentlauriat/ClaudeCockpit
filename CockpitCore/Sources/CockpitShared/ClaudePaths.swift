import Foundation

/// Well-known locations used by every module. Paths are computed from `home`
/// so tests can point the whole app at a temporary directory.
public struct ClaudePaths: Sendable, Equatable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public static let live = ClaudePaths()

    /// `~/.claude`
    public var claudeDir: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    /// `~/.claude/projects` — Claude Code transcripts (`<encoded cwd>/<session>.jsonl`).
    public var projectsDir: URL { claudeDir.appendingPathComponent("projects", isDirectory: true) }
    /// `~/.claude/.credentials.json` — fallback for the OAuth token.
    public var credentialsFile: URL { claudeDir.appendingPathComponent(".credentials.json") }
    public var skillsDir: URL { claudeDir.appendingPathComponent("skills", isDirectory: true) }
    public var agentsDir: URL { claudeDir.appendingPathComponent("agents", isDirectory: true) }
    public var commandsDir: URL { claudeDir.appendingPathComponent("commands", isDirectory: true) }
    /// Inactive resources, shared with SkillManager: `~/.claude/skillmanager/library`.
    public var libraryDir: URL { claudeDir.appendingPathComponent("skillmanager/library", isDirectory: true) }
    /// `~/.claude/plugins/cache/<org>/<plugin>/<version>/…`
    public var pluginsCacheDir: URL { claudeDir.appendingPathComponent("plugins/cache", isDirectory: true) }
    /// Backups written before any SkillsKit mutation.
    public var backupsDir: URL { claudeDir.appendingPathComponent("backups", isDirectory: true) }
    /// `~/Library/Application Support/ClaudeCockpit`
    public var appSupportDir: URL {
        home.appendingPathComponent("Library/Application Support/ClaudeCockpit", isDirectory: true)
    }
    /// rtk history database candidates, in priority order.
    public var rtkDatabaseCandidates: [URL] {
        [
            home.appendingPathComponent("Library/Application Support/rtk/history.db"),
            home.appendingPathComponent(".local/share/rtk/history.db"),
        ]
    }
    /// Default roots scanned for projects owning a `.claude/` directory.
    public var defaultProjectRoots: [URL] {
        [
            home.appendingPathComponent("DevApps", isDirectory: true),
            home.appendingPathComponent("Documents/GitHub", isDirectory: true),
        ]
    }

    /// True when `url` is inside the user's home directory (symlinks resolved).
    public func isInsideHome(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = home.standardizedFileURL.resolvingSymlinksInPath().path
        return target == root || target.hasPrefix(root + "/")
    }
}
