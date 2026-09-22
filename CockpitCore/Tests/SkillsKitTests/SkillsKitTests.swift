import XCTest
import CockpitShared
@testable import SkillsKit

/// Builds a throwaway `$HOME` populated with a realistic `.claude` tree.
/// The real `~/.claude` is never touched.
private struct Fixture {
    let home: URL
    let paths: ClaudePaths
    let project: ProjectRef

    static func make() throws -> Fixture {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SkillsKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolve /var → /private/var so `isInsideHome` compares like with like.
        let home = base.resolvingSymlinksInPath()
        let paths = ClaudePaths(home: home)

        try writeSkill(in: paths.skillsDir, name: "alpha-skill", description: "Premier skill global")
        try writeSkill(in: paths.skillsDir, name: "beta-skill", description: "Second skill global")
        try writeFlat(
            in: paths.libraryDir.appendingPathComponent("agents", isDirectory: true),
            name: "lib-agent",
            description: "Agent rangé en bibliothèque"
        )

        let projectURL = home.appendingPathComponent("DevApps/demo-project", isDirectory: true)
        try writeFlat(
            in: projectURL.appendingPathComponent(".claude/commands", isDirectory: true),
            name: "deploy",
            description: "Commande projet"
        )

        // Must be skipped by the scanner.
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("DevApps/node_modules/ghost-project/.claude", isDirectory: true),
            withIntermediateDirectories: true
        )

        let pluginVersion = paths.pluginsCacheDir
            .appendingPathComponent("acme/toolkit/1.0.0", isDirectory: true)
        try writeSkill(
            in: pluginVersion.appendingPathComponent("skills", isDirectory: true),
            name: "plugin-skill",
            description: "Skill fourni par un plugin"
        )

        return Fixture(
            home: home,
            paths: paths,
            project: ProjectRef(name: "demo-project", url: projectURL)
        )
    }

    static func writeSkill(in directory: URL, name: String, description: String) throws {
        let skillDir = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let body = "---\nname: \(name)\ndescription: \(description)\n---\n\n# \(name)\n"
        try body.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    static func writeFlat(in directory: URL, name: String, description: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let body = "---\nname: \(name)\ndescription: \(description)\n---\n\nCorps de \(name).\n"
        try body.write(to: directory.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: home)
    }

    /// Every file stored under `~/.claude/backups`, relative to it.
    func backupEntries() -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: paths.backupsDir.path) else { return [] }
        return enumerator.compactMap { $0 as? String }.sorted()
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

final class SkillsKitTests: XCTestCase {
    private var fixture: Fixture!
    private var store: ResourceStore!

    override func setUpWithError() throws {
        fixture = try Fixture.make()
        store = ResourceStore(paths: fixture.paths)
    }

    override func tearDownWithError() throws {
        fixture.cleanUp()
        fixture = nil
        store = nil
    }

    // MARK: - Inventory

    func testInventoryCountsEveryLevel() async throws {
        let inventory = try await store.inventory(projects: [fixture.project])

        XCTAssertEqual(inventory.count(kind: .skill, level: .global), 2)
        XCTAssertEqual(inventory.count(kind: .agent, level: .library), 1)
        XCTAssertEqual(inventory.count(kind: .command, level: .project(fixture.project)), 1)
        XCTAssertEqual(inventory.resources.count, 4)
        XCTAssertEqual(inventory.plugins.count, 1)
        XCTAssertFalse(inventory.isEmpty)
    }

    func testInventoryReadsDescriptionsFromFrontMatter() async throws {
        let inventory = try await store.inventory(projects: [fixture.project])

        let alpha = try XCTUnwrap(inventory.resources.first { $0.name == "alpha-skill" })
        XCTAssertEqual(alpha.description, "Premier skill global")
        XCTAssertEqual(alpha.frontmatter.name, "alpha-skill")
        XCTAssertGreaterThan(alpha.sizeBytes, 0)
        XCTAssertEqual(alpha.contentURL.lastPathComponent, "SKILL.md")

        let agent = try XCTUnwrap(inventory.resources.first { $0.kind == .agent })
        XCTAssertEqual(agent.description, "Agent rangé en bibliothèque")
        XCTAssertEqual(agent.level, .library)

        let command = try XCTUnwrap(inventory.resources.first { $0.kind == .command })
        XCTAssertEqual(command.name, "deploy")
        XCTAssertEqual(command.level, .project(fixture.project))

        let plugin = try XCTUnwrap(inventory.plugins.first)
        XCTAssertEqual(plugin.qualifiedName, "toolkit:plugin-skill")
        XCTAssertEqual(plugin.org, "acme")
        XCTAssertEqual(plugin.version, "1.0.0")
        XCTAssertEqual(plugin.description, "Skill fourni par un plugin")
    }

    func testInventoryIsSortedByName() async throws {
        let inventory = try await store.inventory(projects: [fixture.project])
        let names = inventory.resources.map(\.name)
        XCTAssertEqual(names, names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    func testResourceIdsAreUniqueAcrossSameNamedProjects() async throws {
        let twin = ProjectRef(
            name: "demo-project",
            url: fixture.home.appendingPathComponent("Documents/GitHub/demo-project", isDirectory: true)
        )
        try Fixture.writeFlat(
            in: twin.claudeDir.appendingPathComponent("commands", isDirectory: true),
            name: "deploy",
            description: "Homonyme"
        )

        let inventory = try await store.inventory(projects: [fixture.project, twin])
        let ids = inventory.resources(kind: .command).map(\.id)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 2)
    }

    func testReadReturnsSkillMarkdown() async throws {
        let inventory = try await store.inventory()
        let alpha = try XCTUnwrap(inventory.resources.first { $0.name == "alpha-skill" })
        let content = try await store.read(alpha)
        XCTAssertTrue(content.contains("# alpha-skill"))
    }

    // MARK: - Project scanner

    func testProjectScannerFindsProjectsAndSkipsNodeModules() throws {
        let projects = ProjectScanner.scan(roots: fixture.paths.defaultProjectRoots)

        XCTAssertEqual(projects.map(\.name), ["demo-project"])
        XCTAssertEqual(projects.first?.url.path, fixture.project.url.path)
        XCTAssertFalse(projects.contains { $0.name == "ghost-project" })
    }

    func testProjectScannerSortsByName() throws {
        let extra = fixture.home.appendingPathComponent("DevApps/aaa-project/.claude", isDirectory: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)

        let projects = ProjectScanner.scan(roots: fixture.paths.defaultProjectRoots)
        XCTAssertEqual(projects.map(\.name), ["aaa-project", "demo-project"])
    }

    // MARK: - Transfer

    func testCopySkillFromGlobalToProject() async throws {
        let inventory = try await store.inventory(projects: [fixture.project])
        let alpha = try XCTUnwrap(inventory.resources.first { $0.name == "alpha-skill" })

        let copied = try await store.transfer(alpha, to: .project(fixture.project), mode: .copy)

        XCTAssertEqual(copied.level, .project(fixture.project))
        XCTAssertEqual(copied.name, "alpha-skill")
        XCTAssertEqual(copied.description, "Premier skill global")
        XCTAssertTrue(fixture.exists(copied.contentURL))
        XCTAssertTrue(fixture.exists(alpha.contentURL), "la source doit rester en place après une copie")
        XCTAssertTrue(fixture.backupEntries().isEmpty, "une copie sans écrasement ne sauvegarde rien")
    }

    func testMoveAgentFromLibraryToGlobalBacksUpTheSource() async throws {
        let inventory = try await store.inventory()
        let agent = try XCTUnwrap(inventory.resources.first { $0.kind == .agent })

        let moved = try await store.transfer(agent, to: .global, mode: .move)

        XCTAssertEqual(moved.level, .global)
        XCTAssertTrue(fixture.exists(moved.url))
        XCTAssertFalse(fixture.exists(agent.url), "la source doit disparaître après un déplacement")
        XCTAssertTrue(
            fixture.backupEntries().contains { $0.hasSuffix("library/agents/lib-agent.md") },
            "sauvegardes trouvées : \(fixture.backupEntries())"
        )
    }

    func testTransferToSameLevelIsRejected() async throws {
        let inventory = try await store.inventory()
        let alpha = try XCTUnwrap(inventory.resources.first { $0.name == "alpha-skill" })

        await XCTAssertThrowsErrorAsync(try await store.transfer(alpha, to: .global, mode: .copy)) { error in
            guard case .io = error as? SkillsError else {
                return XCTFail("attendu .io, reçu \(error)")
            }
        }
    }

    func testOverwriteIsRefusedThenAllowedWithBackup() async throws {
        let inventory = try await store.inventory()
        let alpha = try XCTUnwrap(inventory.resources.first { $0.name == "alpha-skill" })

        let first = try await store.transfer(alpha, to: .library, mode: .copy)
        XCTAssertTrue(fixture.exists(first.contentURL))

        await XCTAssertThrowsErrorAsync(try await store.transfer(alpha, to: .library, mode: .copy)) { error in
            guard case .alreadyExists(let url) = error as? SkillsError else {
                return XCTFail("attendu .alreadyExists, reçu \(error)")
            }
            XCTAssertEqual(url.lastPathComponent, "alpha-skill")
        }

        let second = try await store.transfer(alpha, to: .library, mode: .copy, overwrite: true)
        XCTAssertTrue(fixture.exists(second.contentURL))
        XCTAssertTrue(
            fixture.backupEntries().contains { $0.hasSuffix("library/skills/alpha-skill/SKILL.md") },
            "sauvegardes trouvées : \(fixture.backupEntries())"
        )
    }

    /// Two mutations inside the same second must not collide on the backup path.
    func testConsecutiveBackupsInTheSameSecondDoNotCollide() async throws {
        let inventory = try await store.inventory()
        let alpha = try XCTUnwrap(inventory.resources.first { $0.name == "alpha-skill" })

        _ = try await store.transfer(alpha, to: .library, mode: .copy)
        let overwritten = try await store.transfer(alpha, to: .library, mode: .copy, overwrite: true)
        let backupURL = try await store.delete(overwritten)

        XCTAssertTrue(fixture.exists(backupURL))
        XCTAssertFalse(fixture.exists(overwritten.url))
        let roots = try FileManager.default.contentsOfDirectory(atPath: fixture.paths.backupsDir.path)
        XCTAssertEqual(roots.count, 2, "deux opérations doivent produire deux dossiers : \(roots)")
    }

    /// `replaceItemAt` behaves differently on a file and on a directory; skills are
    /// directories, agents and commands are flat `.md` files. Both must overwrite cleanly.
    func testOverwritingAFlatResourceReplacesItAndBacksItUp() async throws {
        let inventory = try await store.inventory()
        let agent = try XCTUnwrap(inventory.resources.first { $0.name == "lib-agent" })

        let copied = try await store.transfer(agent, to: .global, mode: .copy)
        XCTAssertEqual(copied.contentURL.pathExtension, "md")
        try "contenu écrasé\n".write(to: copied.url, atomically: true, encoding: .utf8)

        let again = try await store.transfer(agent, to: .global, mode: .copy, overwrite: true)
        XCTAssertEqual(
            try String(contentsOf: again.contentURL, encoding: .utf8),
            try String(contentsOf: agent.contentURL, encoding: .utf8),
            "la source doit avoir remplacé la destination"
        )
        XCTAssertTrue(
            fixture.backupEntries().contains { $0.hasSuffix("global/agents/lib-agent.md") },
            "sauvegardes trouvées : \(fixture.backupEntries())"
        )
    }

    /// A failing copy must not cost the user their existing resource: the destination is
    /// only replaced once the copy succeeded, and the error names the backup.
    func testFailedOverwriteKeepsTheDestinationAndNamesTheBackup() async throws {
        let inventory = try await store.inventory()
        let alpha = try XCTUnwrap(inventory.resources.first { $0.name == "alpha-skill" })
        let existing = try await store.transfer(alpha, to: .library, mode: .copy)
        let before = try String(contentsOf: existing.contentURL, encoding: .utf8)

        let failing = ResourceStore(paths: fixture.paths, fileManager: FailingCopyFileManager())
        await XCTAssertThrowsErrorAsync(
            try await failing.transfer(alpha, to: .library, mode: .copy, overwrite: true)
        ) { error in
            guard case .ioAfterBackup(_, let backup) = error as? SkillsError else {
                return XCTFail("attendu .ioAfterBackup, reçu \(error)")
            }
            XCTAssertTrue(fixture.exists(backup), "la sauvegarde doit exister : \(backup.path)")
            XCTAssertTrue(
                error.localizedDescription.contains(backup.path),
                "le message doit citer la sauvegarde : \(error.localizedDescription)"
            )
        }

        XCTAssertTrue(fixture.exists(existing.url), "l'original doit survivre à une copie ratée")
        XCTAssertEqual(try String(contentsOf: existing.contentURL, encoding: .utf8), before)

        let parent = existing.url.deletingLastPathComponent()
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        XCTAssertFalse(
            leftovers.contains { $0.contains("cockpit-tmp") },
            "aucun fichier temporaire ne doit rester : \(leftovers)"
        )
    }

    // MARK: - Plugin import

    func testImportPluginIntoLibrary() async throws {
        let inventory = try await store.inventory()
        let plugin = try XCTUnwrap(inventory.plugins.first)

        let imported = try await store.importPlugin(plugin, to: .library)

        XCTAssertEqual(imported.level, .library)
        XCTAssertEqual(imported.kind, .skill)
        XCTAssertEqual(imported.name, "plugin-skill")
        XCTAssertEqual(imported.description, "Skill fourni par un plugin")
        XCTAssertTrue(fixture.exists(imported.contentURL))

        let refreshed = try await store.inventory()
        XCTAssertEqual(refreshed.count(kind: .skill, level: .library), 1)

        await XCTAssertThrowsErrorAsync(try await store.importPlugin(plugin, to: .library)) { error in
            guard case .alreadyExists = error as? SkillsError else {
                return XCTFail("attendu .alreadyExists, reçu \(error)")
            }
        }
    }

    // MARK: - Delete

    func testDeleteBacksUpBeforeRemoving() async throws {
        let inventory = try await store.inventory()
        let beta = try XCTUnwrap(inventory.resources.first { $0.name == "beta-skill" })

        let backupURL = try await store.delete(beta)

        XCTAssertFalse(fixture.exists(beta.url))
        XCTAssertTrue(fixture.exists(backupURL.appendingPathComponent("SKILL.md")))
        XCTAssertTrue(backupURL.path.contains("/global/skills/beta-skill"))

        let refreshed = try await store.inventory()
        XCTAssertEqual(refreshed.count(kind: .skill, level: .global), 1)
    }

    // MARK: - Guards

    func testTransferOutsideHomeIsRejected() async throws {
        let inventory = try await store.inventory()
        let alpha = try XCTUnwrap(inventory.resources.first { $0.name == "alpha-skill" })
        let outside = ProjectRef(name: "outside", url: URL(fileURLWithPath: "/tmp/skillskit-outside-home"))

        await XCTAssertThrowsErrorAsync(
            try await store.transfer(alpha, to: .project(outside), mode: .copy)
        ) { error in
            XCTAssertEqual(error as? SkillsError, .outsideHome)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/skillskit-outside-home"))
    }

    func testReadingAResourceOutsideHomeIsRejected() async throws {
        let stray = ClaudeResource(
            kind: .agent,
            name: "stray",
            level: .global,
            url: URL(fileURLWithPath: "/tmp/skillskit-outside-home/stray.md")
        )
        await XCTAssertThrowsErrorAsync(try await store.read(stray)) { error in
            XCTAssertEqual(error as? SkillsError, .outsideHome)
        }
    }

    func testPluginOutsideHomeIsRejected() async throws {
        let forged = PluginResource(
            org: "evil",
            plugin: "evil",
            version: "1.0.0",
            name: "evil-skill",
            url: URL(fileURLWithPath: "/tmp/skillskit-outside-home/evil-skill")
        )
        await XCTAssertThrowsErrorAsync(try await store.read(forged)) { error in
            XCTAssertEqual(error as? SkillsError, .outsideHome)
        }
        await XCTAssertThrowsErrorAsync(try await store.importPlugin(forged, to: .library)) { error in
            XCTAssertEqual(error as? SkillsError, .outsideHome)
        }
        XCTAssertFalse(fixture.exists(fixture.paths.libraryDir.appendingPathComponent("skills/evil-skill")))
    }

    func testDeletingAMissingResourceThrowsNotFound() async throws {
        let ghost = ClaudeResource(
            kind: .agent,
            name: "ghost",
            level: .global,
            url: fixture.paths.agentsDir.appendingPathComponent("ghost.md")
        )
        await XCTAssertThrowsErrorAsync(try await store.delete(ghost)) { error in
            XCTAssertEqual(error as? SkillsError, .notFound)
        }
    }

    // MARK: - Naming

    func testNameSanitizerFollowsSkillManagerRule() {
        XCTAssertEqual(NameSanitizer.sanitize("Mon Skill/v2!"), "Mon-Skill-v2-")
        // One replacement per Unicode scalar, like SkillManager's regex on code points.
        XCTAssertEqual(NameSanitizer.sanitize("caf\u{00E9} pro"), "caf--pro")
        XCTAssertEqual(NameSanitizer.sanitize("../escape"), "---escape")
        XCTAssertEqual(NameSanitizer.sanitize("keep_this-1"), "keep_this-1")
    }
}

// MARK: - Async throwing assertion

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("une erreur était attendue", file: file, line: line)
    } catch {
        handler(error)
    }
}

/// Fails exactly the copy `ResourceStore` makes onto its hidden temporary sibling, leaving
/// the backup copy (which targets `~/.claude/backups`) working.
private final class FailingCopyFileManager: FileManager, @unchecked Sendable {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        guard !dstURL.lastPathComponent.contains("cockpit-tmp") else {
            throw CocoaError(.fileWriteVolumeReadOnly)
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}
