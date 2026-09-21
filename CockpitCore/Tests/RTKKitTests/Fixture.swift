import Foundation
import SQLite3
import XCTest

/// Builds `history.db` fixtures with rtk's real schema, using the system
/// SQLite C library so the test target needs no extra package dependency.
enum Fixture {

    /// The schema rtk 0.46 creates, including the two columns added later
    /// (`exec_time_ms`, `project_path`) that RTKKit deliberately does not read.
    static let commandsSchema = """
        CREATE TABLE commands (
            id INTEGER PRIMARY KEY,
            timestamp TEXT NOT NULL,
            original_cmd TEXT NOT NULL,
            rtk_cmd TEXT NOT NULL,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            saved_tokens INTEGER NOT NULL,
            savings_pct REAL NOT NULL,
            exec_time_ms INTEGER DEFAULT 0,
            project_path TEXT DEFAULT ''
        );
        CREATE INDEX idx_timestamp ON commands(timestamp);
        """

    /// The reference instant every fixture row is anchored to: midday UTC, so
    /// "today" is unambiguous whatever the machine's time zone.
    static let now = Date(timeIntervalSince1970: 1_789_992_000)  // 2026-09-21T12:00:00Z

    struct Row {
        let dayOffset: Int
        let hour: Int
        let command: String
        let rtkCommand: String
        let input: Int
        let output: Int

        var saved: Int { input - output }
        var savingsPct: Double { input > 0 ? 100 * Double(saved) / Double(input) : 0 }
    }

    /// 20 rows over five distinct UTC days, with deliberate gaps (no activity on
    /// D-1, D-4, D-5) and one day outside any 7-day window (D-10).
    static let rows: [Row] = [
        // Today — 2026-09-21
        Row(dayOffset: 0, hour: 1, command: "cat a.js", rtkCommand: "rtk read", input: 1000, output: 400),
        Row(dayOffset: 0, hour: 2, command: "cat b.js", rtkCommand: "rtk read", input: 2000, output: 500),
        Row(dayOffset: 0, hour: 3, command: "git log", rtkCommand: "rtk git log", input: 500, output: 100),
        Row(dayOffset: 0, hour: 4, command: "grep x", rtkCommand: "rtk grep", input: 1000, output: 1000),
        // D-2 — 2026-09-19
        Row(dayOffset: -2, hour: 9, command: "cat c.js", rtkCommand: "rtk read", input: 800, output: 200),
        Row(dayOffset: -2, hour: 10, command: "git log", rtkCommand: "rtk git log", input: 1200, output: 600),
        Row(dayOffset: -2, hour: 11, command: "cat d.js", rtkCommand: "rtk read", input: 400, output: 100),
        // D-3 — 2026-09-18
        Row(dayOffset: -3, hour: 8, command: "cat e.js", rtkCommand: "rtk read", input: 1000, output: 250),
        Row(dayOffset: -3, hour: 9, command: "cat f.js", rtkCommand: "rtk read", input: 1000, output: 250),
        Row(dayOffset: -3, hour: 10, command: "git log", rtkCommand: "rtk git log", input: 600, output: 300),
        Row(dayOffset: -3, hour: 11, command: "grep y", rtkCommand: "rtk grep", input: 900, output: 400),
        Row(dayOffset: -3, hour: 12, command: "tsc", rtkCommand: "rtk tsc", input: 2000, output: 1000),
        // D-6 — 2026-09-15, the oldest day still inside a 7-day window
        Row(dayOffset: -6, hour: 14, command: "cat g.js", rtkCommand: "rtk read", input: 500, output: 100),
        Row(dayOffset: -6, hour: 15, command: "git log", rtkCommand: "rtk git log", input: 300, output: 150),
        // D-10 — 2026-09-11, outside the window but inside all-time
        Row(dayOffset: -10, hour: 9, command: "cat h.js", rtkCommand: "rtk read", input: 1000, output: 500),
        Row(dayOffset: -10, hour: 10, command: "cat i.js", rtkCommand: "rtk read", input: 1000, output: 500),
        Row(dayOffset: -10, hour: 11, command: "git log", rtkCommand: "rtk git log", input: 1000, output: 500),
        Row(dayOffset: -10, hour: 12, command: "grep z", rtkCommand: "rtk grep", input: 1000, output: 500),
        Row(dayOffset: -10, hour: 13, command: "tsc", rtkCommand: "rtk tsc", input: 1000, output: 500),
        Row(dayOffset: -10, hour: 14, command: "curl x", rtkCommand: "rtk curl", input: 1000, output: 500),
    ]

    /// Writes a populated `history.db` inside a fresh temp directory.
    @discardableResult
    static func makeDatabase(in directory: URL, name: String = "history.db") throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        var sql = commandsSchema
        for (index, row) in rows.enumerated() {
            sql += """
                \nINSERT INTO commands
                (id, timestamp, original_cmd, rtk_cmd, input_tokens, output_tokens, saved_tokens, savings_pct, exec_time_ms, project_path)
                VALUES (\(index + 1), '\(timestamp(row))', '\(row.command)', '\(row.rtkCommand)', \
                \(row.input), \(row.output), \(row.saved), \(row.savingsPct), 42, '/tmp/project');
                """
        }
        try execute(sql, at: url)
        return url
    }

    /// Writes a valid but empty database — the state right after `rtk reset`.
    @discardableResult
    static func makeEmptyDatabase(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.db")
        try execute(commandsSchema, at: url)
        return url
    }

    /// Writes a database whose only table is not `commands`, to exercise schema validation.
    @discardableResult
    static func makeWrongSchemaDatabase(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.db")
        try execute("CREATE TABLE parse_failures (id INTEGER PRIMARY KEY, raw_command TEXT);", at: url)
        return url
    }

    /// rtk's exact on-disk format: microsecond precision and an explicit UTC offset.
    static func timestamp(_ row: Row) -> String {
        let day = self.day(row.dayOffset)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return String(format: "%@T%02d:00:00.123456+00:00", formatter.string(from: day), row.hour)
    }

    /// Midnight UTC of `now` shifted by `offset` days — what `DayStat.date` carries.
    static func day(_ offset: Int) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.startOfDay(for: now).addingTimeInterval(86_400 * Double(offset))
    }

    // MARK: - Raw SQLite

    private static func execute(_ sql: String, at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "open failed"])
        }
        defer { sqlite3_close(handle) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw NSError(domain: "Fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

extension XCTestCase {
    /// A unique temp directory removed when the test finishes.
    func makeTemporaryDirectory(function: String = #function) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rtkkit-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
