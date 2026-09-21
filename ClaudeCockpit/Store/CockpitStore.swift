import AppKit
import Foundation
import Observation
import ServiceManagement
import CockpitShared
import UsageKit
import QuotaKit
import RTKKit
import SkillsKit

/// Lifecycle of one data source. Every source is independent: a failure shows
/// in its own section and never blocks the others.
enum SourceState: Equatable {
    case idle
    case loading
    case ready(Date)
    case failed(String)

    var isLoading: Bool { self == .loading }
    var errorMessage: String? { if case .failed(let m) = self { return m } else { return nil } }
    var lastSuccess: Date? { if case .ready(let d) = self { return d } else { return nil } }
}

/// Sidebar sections of the main window.
enum CockpitSection: String, CaseIterable, Identifiable {
    case overview, usage, quotas, rtk, skills, agents, commands, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Vue d'ensemble"
        case .usage: "Usage local"
        case .quotas: "Quotas"
        case .rtk: "RTK"
        case .skills: "Skills"
        case .agents: "Agents"
        case .commands: "Commandes"
        case .settings: "Réglages"
        }
    }
    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .usage: "chart.bar.xaxis"
        case .quotas: "speedometer"
        case .rtk: "leaf.fill"
        case .skills: "sparkles"
        case .agents: "person.2.fill"
        case .commands: "terminal.fill"
        case .settings: "gearshape.fill"
        }
    }
    var resourceKind: ResourceKind? {
        switch self {
        case .skills: .skill
        case .agents: .agent
        case .commands: .command
        default: nil
        }
    }
}

/// The hub: owns the four services, one snapshot + state per source, the
/// refresh loops and the user-facing actions. Everything UI-visible is on the
/// main actor; the work happens in the services (actors / background).
@MainActor @Observable
final class CockpitStore {
    // MARK: Services
    let paths: ClaudePaths
    private let usageService: UsageService
    private let quotaService: QuotaService
    private var rtkService: RTKService
    private let skillsStore: ResourceStore
    private let defaults = UserDefaults.standard

    // MARK: Snapshots & states
    private(set) var usage: UsageSnapshot?
    private(set) var usageState: SourceState = .idle
    private(set) var usageLastScan: Date?

    private(set) var quota: GaugeSnapshot?
    private(set) var quotaState: SourceState = .idle
    private(set) var quotaNextAllowed: Date = .distantPast

    private(set) var rtk: RTKSnapshot?
    private(set) var rtkState: SourceState = .idle

    private(set) var skills: SkillsInventory?
    private(set) var skillsState: SourceState = .idle

    /// Last user-visible notice (toast) from a skills action.
    var notice: String?

    // MARK: Usage filters & pricing
    var usageFilters = UsageFilters(range: .last30Days) {
        didSet { Task { await recomputeUsage() } }
    }
    var pricing: PricingSettings {
        didSet {
            defaults.set(pricing.jsonString, forKey: SettingsKey.pricingJSON)
            Task { await recomputeUsage() }
        }
    }

    // MARK: Derived
    /// Weekly "all models" pace projection, nil when the gauge is unknown.
    var weekProjection: PaceProjection? {
        guard let week = quota?.week else { return nil }
        return UsageMath.projection(for: week, now: Date())
    }
    var sessionProjection: PaceProjection? {
        guard let session = quota?.session else { return nil }
        return UsageMath.projection(for: session, now: Date())
    }
    /// Menu-bar label: weekly percent, or a dash before the first fetch.
    var menuBarTitle: String {
        guard let week = quota?.week else { return "–" }
        return "\(Int(week.utilization.rounded())) %"
    }
    var currency: String { defaults.string(forKey: SettingsKey.currency) ?? "USD" }
    /// Converts a USD amount to the display currency.
    func money(_ usd: Double, digits: Int = 2) -> String {
        if currency == "EUR" {
            let rate = defaults.double(forKey: SettingsKey.eurRate)
            return FRFormat.money(usd * (rate > 0 ? rate : 0.92), currency: "EUR", digits: digits)
        }
        return FRFormat.money(usd, currency: "USD", digits: digits)
    }

    // MARK: Init
    init(paths: ClaudePaths = .live) {
        SettingsKey.registerDefaults()
        self.paths = paths
        usageService = UsageService(paths: paths)
        quotaService = QuotaService(credentials: CredentialStore(paths: paths), api: QuotaAPI())
        let override = UserDefaults.standard.string(forKey: SettingsKey.rtkDBPath).flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        }
        rtkService = RTKService(paths: paths, overridePath: override)
        skillsStore = ResourceStore(paths: paths)
        pricing = UserDefaults.standard.string(forKey: SettingsKey.pricingJSON)
            .map(PricingSettings.decoded(fromJSONString:)) ?? .default
    }

    // MARK: Loops
    private var loopsStarted = false
    private var loopTasks: [Task<Void, Never>] = []

    /// Starts the independent refresh loops once. Safe to call several times.
    func start() {
        guard !loopsStarted else { return }
        loopsStarted = true

        loopTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshUsage()
                let seconds = max(10, UserDefaults.standard.integer(forKey: SettingsKey.usageRefreshSeconds))
                try? await Task.sleep(for: .seconds(seconds))
            }
        })
        loopTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshQuota(force: false)
                try? await Task.sleep(for: .seconds(180))
            }
        })
        loopTasks.append(Task { [weak self] in
            await self?.refreshRTK()
            guard let stream = self?.rtkService.changes else { return }
            for await _ in stream {
                await self?.refreshRTK()
            }
        })
        loopTasks.append(Task { [weak self] in
            // Fallback poll for rtk in case the watcher stream ended (no DB at launch).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.refreshRTK()
            }
        })
        loopTasks.append(Task { [weak self] in
            await self?.refreshSkills()
            guard let self else { return }
            let watcher = DirectoryWatcher(directories: [
                paths.skillsDir, paths.agentsDir, paths.commandsDir,
                paths.libraryDir.appendingPathComponent("skills"),
                paths.libraryDir.appendingPathComponent("agents"),
                paths.libraryDir.appendingPathComponent("commands"),
            ])
            self.skillsWatcher = watcher
            for await _ in watcher.changes {
                await self.refreshSkills()
            }
        })
    }
    private var skillsWatcher: DirectoryWatcher?

    func refreshAll() async {
        async let a: Void = refreshUsage()
        async let b: Void = refreshQuota(force: true)
        async let c: Void = refreshRTK()
        async let d: Void = refreshSkills()
        _ = await (a, b, c, d)
    }

    // MARK: Usage
    func refreshUsage(rescan: Bool = false) async {
        if usage == nil { usageState = .loading }
        do {
            if rescan { try await usageService.rescan() } else { try await usageService.refresh() }
            await recomputeUsage()
            usageLastScan = Date()
            usageState = .ready(Date())
        } catch {
            usageState = .failed(error.localizedDescription)
        }
    }

    private func recomputeUsage() async {
        let filters = usageFilters
        let pricing = pricing
        let snapshot = await usageService.snapshot(filters: filters, pricing: pricing, now: Date())
        self.usage = snapshot
    }

    // MARK: Quota
    func refreshQuota(force: Bool) async {
        if quota == nil { quotaState = .loading }
        do {
            let snapshot = try await quotaService.refresh(force: force)
            quota = snapshot
            quotaState = .ready(snapshot.fetchedAt)
        } catch let error as QuotaError {
            if case .throttled = error, quota != nil {
                // Too early: keep the current snapshot, do not surface as failure.
            } else {
                quotaState = .failed(error.localizedDescription)
            }
        } catch {
            quotaState = .failed(error.localizedDescription)
        }
        quotaNextAllowed = await quotaService.nextAllowedRefresh
    }

    // MARK: RTK
    func refreshRTK() async {
        if rtk == nil { rtkState = .loading }
        let service = rtkService
        do {
            let snapshot = try await Task.detached(priority: .utility) { try service.snapshot() }.value
            rtk = snapshot
            rtkState = .ready(snapshot.generatedAt)
        } catch {
            rtkState = .failed(error.localizedDescription)
        }
    }

    /// Re-resolves the rtk database after the user changed the path setting.
    func rtkPathDidChange() {
        rtkService.stop()
        let raw = defaults.string(forKey: SettingsKey.rtkDBPath) ?? ""
        let override = raw.isEmpty ? nil : URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        rtkService = RTKService(paths: paths, overridePath: override)
        rtk = nil
        Task { await refreshRTK() }
    }
    var rtkDatabaseURL: URL? { rtkService.databaseURL }

    // MARK: Skills
    var projectRoots: [URL] {
        let raw = defaults.string(forKey: SettingsKey.projectRoots) ?? ""
        let lines = raw.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.isEmpty { return paths.defaultProjectRoots }
        return lines.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }

    func refreshSkills() async {
        if skills == nil { skillsState = .loading }
        let roots = projectRoots
        do {
            let projects = await Task.detached(priority: .utility) { ProjectScanner().scan(roots: roots) }.value
            let inventory = try await skillsStore.inventory(projects: projects)
            skills = inventory
            skillsState = .ready(inventory.generatedAt)
        } catch {
            skillsState = .failed(error.localizedDescription)
        }
    }

    func read(_ resource: ClaudeResource) async throws -> String { try await skillsStore.read(resource) }
    func read(_ plugin: PluginResource) async throws -> String { try await skillsStore.read(plugin) }

    @discardableResult
    func transfer(_ resource: ClaudeResource, to level: ResourceLevel, mode: TransferMode, overwrite: Bool = false) async throws -> ClaudeResource {
        let result = try await skillsStore.transfer(resource, to: level, mode: mode, overwrite: overwrite)
        notice = "\(mode == .copy ? "Copié" : "Déplacé") « \(resource.name) » vers \(level.label)"
        await refreshSkills()
        return result
    }

    @discardableResult
    func importPlugin(_ plugin: PluginResource, to level: ResourceLevel, overwrite: Bool = false) async throws -> ClaudeResource {
        let result = try await skillsStore.importPlugin(plugin, to: level, overwrite: overwrite)
        notice = "Importé « \(plugin.name) » vers \(level.label)"
        await refreshSkills()
        return result
    }

    @discardableResult
    func delete(_ resource: ClaudeResource) async throws -> URL {
        let backup = try await skillsStore.delete(resource)
        notice = "Supprimé « \(resource.name) » (sauvegarde : \(backup.path))"
        await refreshSkills()
        return backup
    }

    func reveal(_ resource: ClaudeResource) {
        NSWorkspace.shared.activateFileViewerSelecting([skillsStore.revealURL(for: resource)])
    }
    func reveal(_ plugin: PluginResource) {
        NSWorkspace.shared.activateFileViewerSelecting([skillsStore.revealURL(for: plugin)])
    }

    // MARK: System integration
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    func setMenuBarOnly(_ enabled: Bool) {
        defaults.set(enabled, forKey: SettingsKey.menuBarOnly)
        NSApp.setActivationPolicy(enabled ? .accessory : .regular)
        if !enabled { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Opens (or focuses) the main window and brings the app forward.
    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(MainWindowView.windowID) == true || $0.title == "Claude Cockpit" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindowHandler?()
        }
    }
    /// Injected by the App scene (SwiftUI `openWindow` action).
    var openWindowHandler: (() -> Void)?
}
