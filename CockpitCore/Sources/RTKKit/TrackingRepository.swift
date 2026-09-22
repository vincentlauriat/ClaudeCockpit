// RTKKit — see docs/superpowers/specs/2026-09-21-claude-cockpit-design.md
import Foundation
import SQLite
import CockpitShared

/// Read-only access layer for rtk's SQLite tracking database.
///
/// The cockpit never writes to rtk's database. Every query opens its own
/// connection so a long-lived handle can never hold a lock against the rtk
/// writer process, and so a database rtk recreated (after `rtk reset`) is
/// picked up on the next read.
///
/// ## Opening a WAL database read-only
/// rtk runs its database in WAL mode. A read-only connection needs the `-shm`
/// shared-memory file, which does not exist while rtk is idle — SQLite then
/// answers `SQLITE_CANTOPEN (14)`. `Reader` therefore uses a ladder:
/// 1. open `history.db` read-only in place (works whenever rtk is running);
/// 2. otherwise copy `history.db` and its `-wal` sibling into a private temp
///    directory and read the copy, which shows the data as of the last
///    checkpoint plus whatever the WAL carries.
///
/// The copy is made **once per `read` block**, not once per query, so a full
/// snapshot costs at most one copy — and it is cached process-wide, keyed on the
/// modification date and size of `history.db` and its `-wal` sibling. Three
/// callers refresh the RTK screen (the database watcher, the store's 60 s poll
/// and "tout rafraîchir"), and copying 10 MB for each of them while rtk sits
/// idle is pure waste: the copy is remade only once the source actually
/// changed, and the stale one is deleted then.
public struct TrackingRepository: Sendable {

    public let databaseURL: URL

    /// Columns the queries below actually read. Validation checks exactly these:
    /// requiring more (`exec_time_ms`, `project_path`) would reject older
    /// databases the cockpit can still display.
    static let requiredColumns: Set<String> = [
        "id", "timestamp", "original_cmd", "rtk_cmd",
        "input_tokens", "output_tokens", "saved_tokens", "savings_pct",
    ]

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    // MARK: - Database resolution

    /// Picks the database to read.
    ///
    /// An `override` wins outright: if the user typed a path in Réglages and it
    /// does not exist, the caller gets `nil` rather than silently reading a
    /// different database than the one on screen. Without an override, the
    /// first existing entry of `paths.rtkDatabaseCandidates` is returned.
    public static func resolveDatabase(paths: ClaudePaths, override: URL? = nil) -> URL? {
        let exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
        if let override {
            return exists(override) ? override : nil
        }
        return paths.rtkDatabaseCandidates.first(where: exists)
    }

    // MARK: - Read sessions

    /// Runs `body` against one readable copy of the database.
    ///
    /// Use this to group the queries of a single snapshot; each query inside
    /// still opens (and closes) its own connection.
    public func read<T>(_ body: (Reader) throws -> T) throws -> T {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw RTKError.databaseNotFound
        }
        let reader = try Reader(databaseURL: databaseURL)
        defer { reader.discardTemporaryCopy() }
        return try body(reader)
    }

    /// Drops the cached temporary copy, if any. Tests call it between fixtures;
    /// production code never needs to, since the copy invalidates itself as soon
    /// as the source database changes.
    static func invalidateCopyCache() { CopyCache.shared.invalidate() }

    // MARK: - Single-query conveniences

    public func validateSchema() throws -> Bool { try read { try $0.validateSchema() } }

    public func todayTotals(now: Date = Date()) throws -> TotalsStat {
        try read { try $0.todayTotals(now: now) }
    }

    public func allTimeTotals() throws -> TotalsStat { try read { try $0.allTimeTotals() } }

    public func dailyTotals(days: Int = 7, now: Date = Date()) throws -> [DayStat] {
        try read { try $0.dailyTotals(days: days, now: now) }
    }

    public func byCommand(limit: Int = 10) throws -> [CommandStat] {
        try read { try $0.byCommand(limit: limit) }
    }

    public func recentRecords(limit: Int = 50) throws -> [CommandRecord] {
        try read { try $0.recentRecords(limit: limit) }
    }

    public func recordCount() throws -> Int { try read { try $0.recordCount() } }
}

// MARK: - Reader

extension TrackingRepository {

    /// A resolved, readable location for the database plus the queries that run
    /// against it. Obtained from `TrackingRepository.read(_:)`.
    ///
    /// Deliberately a reference type and deliberately **not** `Sendable`: it
    /// owns a temporary copy that `read(_:)` deletes when its closure returns,
    /// so a `Reader` must never outlive that block nor cross a concurrency
    /// boundary. `TrackingRepository` itself is a `Sendable` value type and is
    /// what callers keep.
    public final class Reader {

        /// Path actually opened — either the live database or a temp copy of it.
        public let path: String
        /// Whether `path` points at a copy rather than at the live database.
        private let readsACopy: Bool

        /// - Parameter forceCopy: skips the in-place probe and always goes
        ///   through the cached copy. Tests use it; nothing else should.
        init(databaseURL: URL, forceCopy: Bool = false) throws {
            if !forceCopy, Self.canReadInPlace(databaseURL.path) {
                path = databaseURL.path
                readsACopy = false
                return
            }
            guard let signature = CopySignature(databaseURL: databaseURL) else {
                throw RTKError.databaseNotFound
            }
            let fm = FileManager.default
            let directory = try CopyCache.shared.directory(for: signature) { dir in
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let copy = dir.appendingPathComponent("history.db")
                try fm.copyItem(at: databaseURL, to: copy)
                let wal = URL(fileURLWithPath: databaseURL.path + "-wal")
                if fm.fileExists(atPath: wal.path) {
                    try? fm.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
                }
            }
            path = directory.appendingPathComponent("history.db").path
            readsACopy = true
        }

        /// Opening a SQLite database is lazy: `sqlite3_open_v2` succeeds even
        /// when the first statement will fail. A read-only handle on an idle
        /// WAL database is exactly that case — it opens, then refuses to read
        /// because it cannot create the missing `-shm` mapping. So the probe
        /// has to run a statement, not just open a connection.
        private static func canReadInPlace(_ path: String) -> Bool {
            guard let db = try? Connection(path, readonly: true) else { return false }
            return (try? db.scalar("SELECT count(*) FROM sqlite_master")) != nil
        }

        /// Kept for symmetry with `read(_:)`: the temporary copy now outlives the
        /// read block on purpose, and is deleted by `CopyCache` the moment the
        /// source database changes.
        func discardTemporaryCopy() {}

        /// A fresh connection, read-only when the ladder read in place.
        private func connection() throws -> Connection {
            do {
                return try Connection(path, readonly: !readsACopy)
            } catch {
                throw RTKError.sqlite(error.localizedDescription)
            }
        }

        // MARK: Schema

        /// True when `commands` carries every column the queries read.
        public func validateSchema() throws -> Bool {
            let db = try connection()
            var columns: Set<String> = []
            do {
                for row in try db.prepare("PRAGMA table_info(commands)") {
                    // PRAGMA table_info: index 1 is the column name.
                    if let name = row[1] as? String { columns.insert(name) }
                }
            } catch {
                throw RTKError.sqlite(error.localizedDescription)
            }
            return TrackingRepository.requiredColumns.isSubset(of: columns)
        }

        // MARK: Aggregates

        /// Totals for the current UTC day.
        ///
        /// Days are UTC, matching what `rtk gain -d` groups on, so the cockpit
        /// and the rtk CLI always agree. Between local midnight and 01:00/02:00
        /// (Paris) "aujourd'hui" therefore still covers the UTC day that began
        /// the previous evening.
        public func todayTotals(now: Date = Date()) throws -> TotalsStat {
            let start = UTCDay.start(of: now)
            let end = UTCDay.start(of: now.addingTimeInterval(86_400))
            return try totals(from: start, to: end)
        }

        /// Totals over every recorded command.
        public func allTimeTotals() throws -> TotalsStat { try totals(from: nil, to: nil) }

        private func totals(from: Date?, to: Date?) throws -> TotalsStat {
            let db = try connection()
            var sql = """
                SELECT COUNT(*),
                       COALESCE(SUM(input_tokens), 0),
                       COALESCE(SUM(output_tokens), 0),
                       COALESCE(SUM(saved_tokens), 0)
                FROM commands
                """
            var bindings: [Binding?] = []
            if let from {
                sql += "\nWHERE timestamp >= ?"
                bindings.append(UTCDay.lowerBound(from))
                if let to {
                    sql += " AND timestamp < ?"
                    bindings.append(UTCDay.lowerBound(to))
                }
            }
            guard let row = try firstRow(db, sql, bindings) else { return .zero }
            return TotalsStat(
                count: Self.int(row[0]),
                inputTokens: Self.int(row[1]),
                outputTokens: Self.int(row[2]),
                savedTokens: Self.int(row[3])
            )
        }

        /// One `DayStat` per UTC day for the last `days` days, oldest first,
        /// ending with the day containing `now`. Days without activity are
        /// present with zeros so a bar chart keeps a regular axis.
        public func dailyTotals(days: Int = 7, now: Date = Date()) throws -> [DayStat] {
            guard days > 0 else { return [] }
            let db = try connection()
            let lastDay = UTCDay.start(of: now)
            let firstDay = lastDay.addingTimeInterval(-86_400 * Double(days - 1))

            var buckets: [String: (saved: Int, count: Int)] = [:]
            let sql = """
                SELECT substr(timestamp, 1, 10) AS day,
                       COALESCE(SUM(saved_tokens), 0),
                       COUNT(*)
                FROM commands
                WHERE timestamp >= ?
                GROUP BY day
                """
            do {
                for row in try db.prepare(sql, UTCDay.lowerBound(firstDay)) {
                    guard let day = row[0] as? String else { continue }
                    buckets[day] = (saved: Self.int(row[1]), count: Self.int(row[2]))
                }
            } catch {
                throw RTKError.sqlite(error.localizedDescription)
            }

            return (0..<days).map { offset in
                let date = firstDay.addingTimeInterval(86_400 * Double(offset))
                let bucket = buckets[UTCDay.label(date)] ?? (saved: 0, count: 0)
                return DayStat(date: date, savedTokens: bucket.saved, count: bucket.count)
            }
        }

        /// Top rtk filters by tokens saved, descending.
        public func byCommand(limit: Int = 10) throws -> [CommandStat] {
            guard limit > 0 else { return [] }
            let db = try connection()
            var results: [CommandStat] = []
            let sql = """
                SELECT rtk_cmd,
                       COALESCE(SUM(saved_tokens), 0) AS saved,
                       COUNT(*),
                       COALESCE(100.0 * SUM(saved_tokens) / NULLIF(SUM(input_tokens), 0), 0.0)
                FROM commands
                GROUP BY rtk_cmd
                ORDER BY saved DESC, rtk_cmd ASC
                LIMIT ?
                """
            do {
                for row in try db.prepare(sql, limit) {
                    results.append(CommandStat(
                        name: (row[0] as? String) ?? "",
                        savedTokens: Self.int(row[1]),
                        count: Self.int(row[2]),
                        savingsPct: Self.double(row[3])
                    ))
                }
            } catch {
                throw RTKError.sqlite(error.localizedDescription)
            }
            return results
        }

        /// The `limit` most recent commands, newest first.
        public func recentRecords(limit: Int = 50) throws -> [CommandRecord] {
            guard limit > 0 else { return [] }
            let db = try connection()
            var results: [CommandRecord] = []
            let sql = """
                SELECT id, timestamp, original_cmd, rtk_cmd,
                       input_tokens, output_tokens, saved_tokens, savings_pct
                FROM commands
                ORDER BY timestamp DESC
                LIMIT ?
                """
            do {
                for row in try db.prepare(sql, limit) {
                    guard let raw = row[1] as? String,
                          let timestamp = RTKTimestamp.parse(raw) else { continue }
                    results.append(CommandRecord(
                        id: Self.int(row[0]),
                        timestamp: timestamp,
                        originalCommand: (row[2] as? String) ?? "",
                        rtkCommand: (row[3] as? String) ?? "",
                        inputTokens: Self.int(row[4]),
                        outputTokens: Self.int(row[5]),
                        savedTokens: Self.int(row[6]),
                        savingsPct: Self.double(row[7])
                    ))
                }
            } catch {
                throw RTKError.sqlite(error.localizedDescription)
            }
            return results
        }

        /// Number of rows in `commands`.
        public func recordCount() throws -> Int {
            let db = try connection()
            guard let row = try firstRow(db, "SELECT COUNT(*) FROM commands", []) else { return 0 }
            return Self.int(row[0])
        }

        // MARK: Helpers

        private func firstRow(_ db: Connection, _ sql: String, _ bindings: [Binding?]) throws -> [Binding?]? {
            do {
                return try db.prepare(sql, bindings).failableNext()
            } catch {
                throw RTKError.sqlite(error.localizedDescription)
            }
        }

        private static func int(_ value: Binding?) -> Int {
            switch value {
            case let v as Int64: return Int(v)
            case let v as Double: return Int(v)
            default: return 0
            }
        }

        private static func double(_ value: Binding?) -> Double {
            switch value {
            case let v as Double: return v
            case let v as Int64: return Double(v)
            default: return 0
            }
        }
    }
}

// MARK: - UTC day arithmetic

/// Day bucketing for rtk timestamps, which are always stored in UTC
/// (`2026-09-21T21:11:11.312260+00:00`).
enum UTCDay {
    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private static let labelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")!
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Midnight UTC of the day containing `date`.
    static func start(of date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    /// `yyyy-MM-dd` in UTC — the value `substr(timestamp, 1, 10)` produces.
    static func label(_ date: Date) -> String { labelFormatter.string(from: date) }

    /// A string that sorts at or before every rtk timestamp of that day.
    ///
    /// rtk timestamps share one format, so a plain lexicographic comparison on
    /// the text column is exact and uses `idx_timestamp`. `2026-09-21T00:00:00`
    /// is a prefix of `2026-09-21T00:00:00.000000+00:00`, hence strictly
    /// smaller: the day's first row is always included, and the next day's
    /// midnight row is always excluded.
    static func lowerBound(_ date: Date) -> String { label(date) + "T00:00:00" }
}

// MARK: - Timestamp parsing

/// Parses rtk's ISO 8601 timestamps.
///
/// rtk writes microsecond precision with an explicit offset
/// (`2026-09-21T21:11:11.312260+00:00`). `ISO8601DateFormatter` accepts at most
/// three fractional digits, so the fraction is truncated first. Rows written by
/// other tooling without a fractional part still parse via the second formatter.
enum RTKTimestamp {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ raw: String) -> Date? {
        let normalized = truncatingFraction(raw)
        return fractional.date(from: normalized) ?? plain.date(from: raw) ?? plain.date(from: normalized)
    }

    /// Keeps at most three fractional digits, leaving the offset suffix intact.
    private static func truncatingFraction(_ raw: String) -> String {
        guard let dot = raw.firstIndex(of: ".") else { return raw }
        var end = raw.index(after: dot)
        while end < raw.endIndex, raw[end].isNumber { end = raw.index(after: end) }
        let digits = raw[raw.index(after: dot)..<end]
        guard digits.count > 3 else { return raw }
        return String(raw[...dot]) + digits.prefix(3) + raw[end...]
    }
}


// MARK: - Temporary copy cache

extension TrackingRepository {

    /// What makes one temporary copy still valid: the database and its `-wal`
    /// sibling, each identified by modification date and byte size. rtk only
    /// ever appends, so a source that matches on both cannot have changed
    /// without the copy being stale in a way this misses.
    struct CopySignature: Equatable {
        let path: String
        let databaseModified: Date
        let databaseSize: UInt64
        let walModified: Date?
        let walSize: UInt64?

        init?(databaseURL: URL) {
            guard let stamp = Self.stamp(databaseURL.path) else { return nil }
            path = databaseURL.path
            databaseModified = stamp.modified
            databaseSize = stamp.size
            let wal = Self.stamp(databaseURL.path + "-wal")
            walModified = wal?.modified
            walSize = wal?.size
        }

        private static func stamp(_ path: String) -> (modified: Date, size: UInt64)? {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date,
                  let size = (attrs[.size] as? NSNumber)?.uint64Value
            else { return nil }
            return (modified, size)
        }
    }

    /// Holds at most one temporary copy: the app reads a single database at a
    /// time, so a one-entry cache is enough and a changed path evicts.
    final class CopyCache: @unchecked Sendable {
        static let shared = CopyCache()

        private let lock = NSLock()
        private var signature: CopySignature?
        private var directory: URL?
        /// The previous copy, kept one generation longer. A `Reader` opens a fresh
        /// connection per query, so deleting a superseded copy on the spot would make
        /// another thread's in-flight snapshot fail on a path that just vanished — and
        /// a signature change is exactly when the watcher fires a concurrent refresh.
        private var retired: URL?

        /// The directory holding a copy valid for `signature`, making one with
        /// `make` when the cached one is missing or stale. The copy is built
        /// under the lock so concurrent refreshes share one copy instead of
        /// racing to duplicate a 10 MB database.
        func directory(for signature: CopySignature, make: (URL) throws -> Void) throws -> URL {
            lock.lock()
            defer { lock.unlock() }

            if self.signature == signature, let directory,
               FileManager.default.fileExists(
                   atPath: directory.appendingPathComponent("history.db").path) {
                return directory
            }

            let fresh = FileManager.default.temporaryDirectory
                .appendingPathComponent("rtkkit-\(UUID().uuidString)", isDirectory: true)
            do {
                try make(fresh)
            } catch {
                try? FileManager.default.removeItem(at: fresh)
                throw RTKError.sqlite(error.localizedDescription)
            }
            // Retire the superseded copy rather than deleting it: at most two copies
            // exist at any time, and a reader would have to survive two consecutive
            // signature changes to lose the file under it.
            if let retired { try? FileManager.default.removeItem(at: retired) }
            retired = self.directory
            self.signature = signature
            self.directory = fresh
            return fresh
        }

        func invalidate() {
            lock.lock()
            for url in [directory, retired] {
                guard let url else { continue }
                try? FileManager.default.removeItem(at: url)
            }
            directory = nil
            retired = nil
            signature = nil
            lock.unlock()
        }
    }
}
