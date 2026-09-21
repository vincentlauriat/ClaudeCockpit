// RTKKit — see docs/superpowers/specs/2026-09-21-claude-cockpit-design.md
import Foundation
import CockpitShared

/// The one entry point the app uses for rtk data.
///
/// Resolves the database, reads a whole `RTKSnapshot` in a single pass, and
/// publishes a debounced tick whenever rtk writes. Nothing here mutates rtk's
/// database.
///
/// ```swift
/// let service = RTKService()
/// let snapshot = try service.snapshot()
/// for await _ in service.changes { … }
/// ```
public final class RTKService: @unchecked Sendable {

    /// How many recent commands the live trace carries.
    public static let defaultRecentLimit = 50
    /// How many rtk filters the by-command chart carries.
    public static let defaultCommandLimit = 10
    /// Length of the daily series.
    public static let defaultDays = 7

    private let paths: ClaudePaths
    private let overridePath: URL?
    private let lock = NSLock()
    private var watcher: DBWatcher?
    private var cachedStream: AsyncStream<Void>?

    /// - Parameters:
    ///   - paths: where to look for the database; inject a temp home in tests.
    ///   - overridePath: an explicit `history.db`, as set in Réglages. When it
    ///     is given but missing, resolution fails rather than falling back to a
    ///     candidate — reading a different database than the one on screen is a
    ///     failure the user could not detect.
    public init(paths: ClaudePaths = .live, overridePath: URL? = nil) {
        self.paths = paths
        self.overridePath = overridePath
    }

    deinit { watcher?.stop() }

    /// The resolved `history.db`, or `nil` when rtk is not installed (or the
    /// override path does not exist). Re-evaluated on each access, so a
    /// database created after launch is picked up.
    public var databaseURL: URL? {
        TrackingRepository.resolveDatabase(paths: paths, override: overridePath)
    }

    /// Reads every figure the RTK screen shows, from one readable copy of the
    /// database.
    ///
    /// - Throws: `RTKError.databaseNotFound` when no database resolves,
    ///   `RTKError.invalidSchema` when `commands` lacks a column that is read,
    ///   `RTKError.sqlite` for anything SQLite reported.
    public func snapshot(
        now: Date = Date(),
        days: Int = RTKService.defaultDays,
        commandLimit: Int = RTKService.defaultCommandLimit,
        recentLimit: Int = RTKService.defaultRecentLimit
    ) throws -> RTKSnapshot {
        guard let url = databaseURL else { throw RTKError.databaseNotFound }
        let repository = TrackingRepository(databaseURL: url)
        return try repository.read { reader in
            guard try reader.validateSchema() else { throw RTKError.invalidSchema }
            return RTKSnapshot(
                today: try reader.todayTotals(now: now),
                last7Days: try reader.dailyTotals(days: days, now: now),
                allTime: try reader.allTimeTotals(),
                byCommand: try reader.byCommand(limit: commandLimit),
                recent: try reader.recentRecords(limit: recentLimit),
                generatedAt: now,
                databaseURL: url
            )
        }
    }

    /// Debounced ticks emitted whenever rtk writes to its database.
    ///
    /// The watcher starts on first access. When no database resolves, the
    /// stream is created already finished, so `for await` simply completes and
    /// the caller falls back to manual refreshes.
    public var changes: AsyncStream<Void> {
        lock.lock()
        defer { lock.unlock() }
        if let cachedStream { return cachedStream }
        guard let url = databaseURL else {
            let empty = AsyncStream<Void> { $0.finish() }
            cachedStream = empty
            return empty
        }
        let watcher = DBWatcher(databaseURL: url)
        watcher.start()
        self.watcher = watcher
        cachedStream = watcher.changes
        return watcher.changes
    }

    /// Stops watching. Called automatically on `deinit`; call it explicitly to
    /// release the watcher earlier, for instance when the RTK screen closes.
    public func stop() {
        lock.lock()
        let current = watcher
        watcher = nil
        cachedStream = nil
        lock.unlock()
        current?.stop()
    }
}
