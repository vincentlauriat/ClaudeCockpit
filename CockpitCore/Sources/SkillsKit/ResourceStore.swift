import Foundation
import CockpitShared

/// Reads and mutates the skills / agents / commands tree.
///
/// Every mutation is validated against `ClaudePaths.isInsideHome` and copies
/// the affected files into `backupsDir/<yyyyMMdd-HHmmss>/<level>/<kind>/…`
/// before touching them.
public actor ResourceStore {
    private let paths: ClaudePaths
    private let fileManager: FileManager

    public init(paths: ClaudePaths = .live, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    // MARK: - Inventory

    /// Scans the library, the global directory and every given project, plus
    /// the plugin cache. Missing directories are simply empty.
    public func inventory(projects: [ProjectRef] = []) throws -> SkillsInventory {
        var resources: [ClaudeResource] = []
        let levels: [ResourceLevel] = [.library, .global] + projects.map { ResourceLevel.project($0) }
        for level in levels {
            for kind in ResourceKind.allCases {
                resources.append(contentsOf: scan(kind: kind, level: level))
            }
        }
        resources.sort { left, right in
            let order = left.name.localizedStandardCompare(right.name)
            if order != .orderedSame { return order == .orderedAscending }
            return left.id < right.id
        }
        return SkillsInventory(
            resources: resources,
            plugins: scanPlugins(),
            projects: projects,
            generatedAt: Date()
        )
    }

    /// Markdown content of a resource — `SKILL.md` for a skill.
    public func read(_ resource: ClaudeResource) throws -> String {
        let url = resource.contentURL
        guard paths.isInsideHome(url) else { throw SkillsError.outsideHome }
        guard fileManager.fileExists(atPath: url.path) else { throw SkillsError.notFound }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw SkillsError.io("Lecture impossible : \(error.localizedDescription)")
        }
    }

    /// Markdown content of a plugin skill.
    public func read(_ plugin: PluginResource) throws -> String {
        let url = plugin.contentURL
        guard paths.isInsideHome(plugin.url), paths.isInsideHome(url) else { throw SkillsError.outsideHome }
        guard fileManager.fileExists(atPath: url.path) else { throw SkillsError.notFound }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw SkillsError.io("Lecture impossible : \(error.localizedDescription)")
        }
    }

    /// The item to select in the Finder.
    public nonisolated func revealURL(for resource: ClaudeResource) -> URL { resource.url }

    public nonisolated func revealURL(for plugin: PluginResource) -> URL { plugin.url }

    // MARK: - Mutations

    /// Copies or moves a resource to another level.
    ///
    /// - Refuses an existing destination unless `overwrite` is true; the
    ///   destination is then backed up before being replaced.
    /// - In `.move` mode the source is backed up before being removed.
    @discardableResult
    public func transfer(
        _ resource: ClaudeResource,
        to level: ResourceLevel,
        mode: TransferMode,
        overwrite: Bool = false
    ) throws -> ClaudeResource {
        guard level != resource.level else {
            throw SkillsError.io("La source et la destination sont identiques.")
        }
        let name = try sanitizedName(resource.name)
        let source = resource.url
        guard paths.isInsideHome(source) else { throw SkillsError.outsideHome }
        guard fileManager.fileExists(atPath: source.path) else { throw SkillsError.notFound }

        let destinationDirectory = level.directory(for: resource.kind, paths: paths)
        guard paths.isInsideHome(destinationDirectory) else { throw SkillsError.outsideHome }
        let destination = itemURL(kind: resource.kind, name: name, in: destinationDirectory)

        var backupRoot: URL?
        if fileManager.fileExists(atPath: destination.path) {
            guard overwrite else { throw SkillsError.alreadyExists(destination) }
            let root = try makeBackupRoot()
            backupRoot = root
            try backup(destination, kind: resource.kind, level: level, into: root)
            try remove(destination)
        }

        try createDirectory(destinationDirectory)
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw SkillsError.io("Copie impossible : \(error.localizedDescription)")
        }

        if mode == .move {
            let root = try backupRoot ?? makeBackupRoot()
            try backup(source, kind: resource.kind, level: resource.level, into: root)
            try remove(source)
        }

        guard let created = load(kind: resource.kind, level: level, itemURL: destination) else {
            throw SkillsError.io("La ressource transférée est illisible.")
        }
        return created
    }

    /// Copies a plugin skill directory to the library, the global level or a project.
    @discardableResult
    public func importPlugin(
        _ plugin: PluginResource,
        to level: ResourceLevel,
        overwrite: Bool = false
    ) throws -> ClaudeResource {
        let name = try sanitizedName(plugin.name)
        guard paths.isInsideHome(plugin.url), paths.isInsideHome(plugin.contentURL) else {
            throw SkillsError.outsideHome
        }
        guard fileManager.fileExists(atPath: plugin.contentURL.path) else { throw SkillsError.notFound }

        let destinationDirectory = level.directory(for: .skill, paths: paths)
        guard paths.isInsideHome(destinationDirectory) else { throw SkillsError.outsideHome }
        let destination = itemURL(kind: .skill, name: name, in: destinationDirectory)

        if fileManager.fileExists(atPath: destination.path) {
            guard overwrite else { throw SkillsError.alreadyExists(destination) }
            let root = try makeBackupRoot()
            try backup(destination, kind: .skill, level: level, into: root)
            try remove(destination)
        }

        try createDirectory(destinationDirectory)
        do {
            try fileManager.copyItem(at: plugin.url, to: destination)
        } catch {
            throw SkillsError.io("Import impossible : \(error.localizedDescription)")
        }

        guard let created = load(kind: .skill, level: level, itemURL: destination) else {
            throw SkillsError.io("Le skill importé est illisible.")
        }
        return created
    }

    /// Backs the resource up, then removes it. Returns the backup location.
    @discardableResult
    public func delete(_ resource: ClaudeResource) throws -> URL {
        let url = resource.url
        guard paths.isInsideHome(url) else { throw SkillsError.outsideHome }
        guard fileManager.fileExists(atPath: url.path) else { throw SkillsError.notFound }
        let root = try makeBackupRoot()
        let backupURL = try backup(url, kind: resource.kind, level: resource.level, into: root)
        try remove(url)
        return backupURL
    }

    // MARK: - Scanning

    private func scan(kind: ResourceKind, level: ResourceLevel) -> [ClaudeResource] {
        let directory = level.directory(for: kind, paths: paths)
        guard paths.isInsideHome(directory) else { return [] }
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var result: [ClaudeResource] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if kind.isDirectoryBased {
                guard isDirectory else { continue }
            } else {
                guard !isDirectory, entry.pathExtension.lowercased() == "md" else { continue }
            }
            if let resource = load(kind: kind, level: level, itemURL: entry) {
                result.append(resource)
            }
        }
        return result
    }

    private func scanPlugins() -> [PluginResource] {
        let cache = paths.pluginsCacheDir
        var result: [PluginResource] = []
        for org in subdirectories(of: cache) {
            for plugin in subdirectories(of: org) {
                for version in subdirectories(of: plugin) {
                    let orphaned = version.appendingPathComponent(".orphaned_at")
                    if fileManager.fileExists(atPath: orphaned.path) { continue }
                    let skillsDirectory = version.appendingPathComponent("skills", isDirectory: true)
                    let fallback = pluginDescription(versionDirectory: version)
                    for skill in subdirectories(of: skillsDirectory) {
                        let content = skill.appendingPathComponent("SKILL.md")
                        guard fileManager.fileExists(atPath: content.path) else { continue }
                        let text = (try? String(contentsOf: content, encoding: .utf8)) ?? ""
                        let front = Frontmatter.parse(text)
                        result.append(PluginResource(
                            org: org.lastPathComponent,
                            plugin: plugin.lastPathComponent,
                            version: version.lastPathComponent,
                            name: skill.lastPathComponent,
                            url: skill,
                            description: nonEmpty(front.description) ?? fallback
                        ))
                    }
                }
            }
        }
        return result.sorted { left, right in
            let order = left.name.localizedStandardCompare(right.name)
            if order != .orderedSame { return order == .orderedAscending }
            return left.id < right.id
        }
    }

    private func pluginDescription(versionDirectory: URL) -> String? {
        let manifest = versionDirectory
            .appendingPathComponent(".claude-plugin", isDirectory: true)
            .appendingPathComponent("plugin.json")
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return nonEmpty(object["description"] as? String)
    }

    private func subdirectories(of directory: URL) -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false }
    }

    private func load(kind: ResourceKind, level: ResourceLevel, itemURL: URL) -> ClaudeResource? {
        let content = kind.isDirectoryBased ? itemURL.appendingPathComponent("SKILL.md") : itemURL
        guard fileManager.fileExists(atPath: content.path) else { return nil }
        let text = (try? String(contentsOf: content, encoding: .utf8)) ?? ""
        let front = Frontmatter.parse(text)
        let values = try? content.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let name = kind.isDirectoryBased
            ? itemURL.lastPathComponent
            : itemURL.deletingPathExtension().lastPathComponent
        return ClaudeResource(
            kind: kind,
            name: name,
            level: level,
            url: itemURL,
            description: nonEmpty(front.description),
            frontmatter: front,
            modifiedAt: values?.contentModificationDate ?? .distantPast,
            sizeBytes: Int64(values?.fileSize ?? 0)
        )
    }

    // MARK: - Filesystem helpers

    private func itemURL(kind: ResourceKind, name: String, in directory: URL) -> URL {
        kind.isDirectoryBased
            ? directory.appendingPathComponent(name, isDirectory: true)
            : directory.appendingPathComponent("\(name).md")
    }

    private func sanitizedName(_ raw: String) throws -> String {
        let name = NameSanitizer.sanitize(raw)
        guard !name.isEmpty, name != ".", name != ".." else {
            throw SkillsError.io("Nom de ressource invalide.")
        }
        return name
    }

    /// A fresh `backupsDir/<yyyyMMdd-HHmmss>` folder, suffixed if that second
    /// already produced one.
    private func makeBackupRoot() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var candidate = paths.backupsDir.appendingPathComponent(stamp, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = paths.backupsDir.appendingPathComponent("\(stamp)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try createDirectory(candidate)
        return candidate
    }

    @discardableResult
    private func backup(_ url: URL, kind: ResourceKind, level: ResourceLevel, into root: URL) throws -> URL {
        let directory = root
            .appendingPathComponent(level.backupComponent, isDirectory: true)
            .appendingPathComponent(kind.directoryName, isDirectory: true)
        try createDirectory(directory)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) { try remove(destination) }
        do {
            try fileManager.copyItem(at: url, to: destination)
        } catch {
            throw SkillsError.io("Sauvegarde impossible : \(error.localizedDescription)")
        }
        return destination
    }

    private func createDirectory(_ url: URL) throws {
        guard paths.isInsideHome(url) else { throw SkillsError.outsideHome }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw SkillsError.io("Création du dossier impossible : \(error.localizedDescription)")
        }
    }

    private func remove(_ url: URL) throws {
        guard paths.isInsideHome(url) else { throw SkillsError.outsideHome }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw SkillsError.io("Suppression impossible : \(error.localizedDescription)")
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
