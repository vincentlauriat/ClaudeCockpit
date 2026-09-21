// RTKKit — see docs/superpowers/specs/2026-09-21-claude-cockpit-design.md
import Foundation

/// One row of rtk's `commands` table: a single command rtk filtered.
///
/// Mirrors the on-disk schema (`id`, `timestamp`, `original_cmd`, `rtk_cmd`,
/// `input_tokens`, `output_tokens`, `saved_tokens`, `savings_pct`). The
/// `exec_time_ms` and `project_path` columns exist in recent rtk versions but
/// are not read here — nothing in the cockpit displays them.
public struct CommandRecord: Sendable, Equatable, Identifiable {
    /// `commands.id`, stable primary key — usable as a SwiftUI list identity.
    public let id: Int
    public let timestamp: Date
    /// The command the user typed, e.g. `cat library.js`.
    public let originalCommand: String
    /// The rtk filter that handled it, e.g. `rtk read`.
    public let rtkCommand: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let savedTokens: Int
    /// Savings for this row as stored by rtk, in percent (0…100).
    public let savingsPct: Double

    public init(
        id: Int,
        timestamp: Date,
        originalCommand: String,
        rtkCommand: String,
        inputTokens: Int,
        outputTokens: Int,
        savedTokens: Int,
        savingsPct: Double
    ) {
        self.id = id
        self.timestamp = timestamp
        self.originalCommand = originalCommand
        self.rtkCommand = rtkCommand
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.savedTokens = savedTokens
        self.savingsPct = savingsPct
    }
}

/// Aggregated totals over a period — used for both "today" and "all time".
public struct TotalsStat: Sendable, Equatable {
    public let count: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let savedTokens: Int

    public init(count: Int, inputTokens: Int, outputTokens: Int, savedTokens: Int) {
        self.count = count
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.savedTokens = savedTokens
    }

    public static let zero = TotalsStat(count: 0, inputTokens: 0, outputTokens: 0, savedTokens: 0)

    /// Weighted savings in percent (0…100): `100 × Σsaved ⁄ Σinput`.
    ///
    /// This is the same formula rtk itself reports as `avg_savings_pct` in
    /// `rtk gain -f json`; it is deliberately *not* the mean of the per-row
    /// `savings_pct` values, which would over-weight tiny commands.
    public var savingsPct: Double {
        guard inputTokens > 0 else { return 0 }
        return 100 * Double(savedTokens) / Double(inputTokens)
    }

    public var isEmpty: Bool { count == 0 }
}

/// One calendar day of the daily series. Days without activity are present
/// with zeroed values so a chart keeps a regular x-axis.
public struct DayStat: Sendable, Equatable, Identifiable {
    /// Midnight UTC of the day this bucket covers.
    public let date: Date
    public let savedTokens: Int
    public let count: Int

    public var id: Date { date }

    public init(date: Date, savedTokens: Int, count: Int) {
        self.date = date
        self.savedTokens = savedTokens
        self.count = count
    }
}

/// Tokens saved by one rtk filter, across the whole database.
public struct CommandStat: Sendable, Equatable, Identifiable {
    /// The rtk filter name, i.e. the `rtk_cmd` column (`rtk read`, `rtk git log`…).
    public let name: String
    public let savedTokens: Int
    public let count: Int
    /// Weighted savings for this filter, in percent (0…100).
    public let savingsPct: Double

    public var id: String { name }

    public init(name: String, savedTokens: Int, count: Int, savingsPct: Double) {
        self.name = name
        self.savedTokens = savedTokens
        self.count = count
        self.savingsPct = savingsPct
    }
}

/// Everything the RTK screen and the menu-bar strip need, computed in one pass.
public struct RTKSnapshot: Sendable, Equatable {
    public let today: TotalsStat
    /// Chronological, one entry per day, oldest first. Gaps are filled with zeros.
    public let last7Days: [DayStat]
    public let allTime: TotalsStat
    /// Top filters by tokens saved, descending.
    public let byCommand: [CommandStat]
    /// Most recent commands, newest first — the live trace.
    public let recent: [CommandRecord]
    public let generatedAt: Date
    public let databaseURL: URL

    public init(
        today: TotalsStat,
        last7Days: [DayStat],
        allTime: TotalsStat,
        byCommand: [CommandStat],
        recent: [CommandRecord],
        generatedAt: Date,
        databaseURL: URL
    ) {
        self.today = today
        self.last7Days = last7Days
        self.allTime = allTime
        self.byCommand = byCommand
        self.recent = recent
        self.generatedAt = generatedAt
        self.databaseURL = databaseURL
    }

    /// What the compression gauge draws: the share of the raw input that
    /// survives filtering, all-time, clamped to 0…1.
    ///
    /// Matches `CompressionGauge(input:output:)` in RTKInfos, which sizes its
    /// bar with `output / input`. `1 - compressionRatio` is the reclaimed share.
    public var compressionRatio: Double {
        guard allTime.inputTokens > 0 else { return 0 }
        return min(1, Double(allTime.outputTokens) / Double(allTime.inputTokens))
    }

    /// Tokens rtk saved today — the figure shown in the menu-bar panel.
    public var savedTodayTokens: Int { today.savedTokens }

    /// Timestamp of the newest recorded command, or `nil` when the trace is empty.
    public var lastActivity: Date? { recent.first?.timestamp }

    /// An all-zero snapshot, used before the first read completes.
    public static func empty(databaseURL: URL, generatedAt: Date = Date()) -> RTKSnapshot {
        RTKSnapshot(
            today: .zero,
            last7Days: [],
            allTime: .zero,
            byCommand: [],
            recent: [],
            generatedAt: generatedAt,
            databaseURL: databaseURL
        )
    }
}

/// Failures surfaced by `RTKService`. Messages are French, like the rest of the app.
public enum RTKError: Error, Equatable, LocalizedError {
    /// No readable `history.db` at the override path nor at any candidate.
    case databaseNotFound
    /// The `commands` table is missing or lacks a column the queries read.
    case invalidSchema
    /// Anything SQLite reported, carried as text so the type stays `Sendable`.
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case .databaseNotFound:
            return "Base rtk introuvable. Installez rtk ou indiquez le chemin de history.db dans les réglages."
        case .invalidSchema:
            return "La table commands de la base rtk n'a pas le schéma attendu."
        case .sqlite(let message):
            return "Erreur SQLite : \(message)"
        }
    }
}
