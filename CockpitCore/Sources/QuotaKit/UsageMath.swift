import CockpitShared
import Foundation

/// Pace projection for one meter: where it lands at the current rate, and what it
/// would take to land exactly on 100.
public struct PaceProjection: Equatable, Sendable {
    /// Percentage of the window already consumed, 0…100.
    public let used: Double
    public let hoursElapsed: Double
    public let hoursLeft: Double
    public let resetsAt: Date

    public init(used: Double, hoursElapsed: Double, hoursLeft: Double, resetsAt: Date) {
        self.used = used
        self.hoursElapsed = hoursElapsed
        self.hoursLeft = hoursLeft
        self.resetsAt = resetsAt
    }

    /// Percentage the window reaches at the reset if the current average rate holds.
    public var landing: Double {
        let total = hoursElapsed + hoursLeft
        guard total > 0, hoursElapsed > 0 else { return used }
        return used * total / hoursElapsed
    }
    /// Current burn rate, in percent of the window per hour.
    public var runningPerHour: Double { hoursElapsed > 0 ? used / hoursElapsed : 0 }
    /// Sustainable rate: the one that lands exactly on 100 at the reset.
    public var neededPerHour: Double { hoursLeft > 0 ? max(0, 100 - used) / hoursLeft : 0 }
    public var remaining: Double { max(0, 100 - used) }
    public var daysLeft: Double { hoursLeft / 24 }
    /// Daily budget: remaining quota divided by the remaining days.
    public var evenSharePerDay: Double { daysLeft > 0 ? remaining / daysLeft : remaining }
    public var isOver: Bool { landing > 100 }

    /// A projection needs enough elapsed time to mean anything: extrapolating from the
    /// first minutes of a window turns a normal start into an absurd rate (12 % in three
    /// minutes reads as 254 %/h and a 1274 % landing).
    public var isMeaningful: Bool {
        hoursElapsed >= 0.5 && hoursElapsed / (hoursElapsed + hoursLeft) >= 0.05
    }
}

public enum UsageMath {
    /// Nil when the meter carries no reset date — the API omits it for some model windows.
    public static func projection(for meter: Meter, now: Date) -> PaceProjection? {
        guard let reset = meter.resetsAt else { return nil }
        let window = meter.windowHours * 3600
        let start = reset.addingTimeInterval(-window)
        let elapsed = min(window, max(0, now.timeIntervalSince(start)))
        let left = max(0, reset.timeIntervalSince(now))
        return PaceProjection(used: meter.utilization,
                              hoursElapsed: elapsed / 3600,
                              hoursLeft: left / 3600,
                              resetsAt: reset)
    }

    /// Start of the weekly window: 7 days before the `all` meter reset, or 7 days ago.
    public static func weekStart(gauge: GaugeSnapshot?, now: Date) -> Date {
        if let reset = gauge?.week?.resetsAt {
            return reset.addingTimeInterval(-7 * 86_400)
        }
        return now.addingTimeInterval(-7 * 86_400)
    }
}

/// French sentences describing a pace, ported from the ClaudeMenu panel so the wording
/// stays in one place. The app is free to ignore these and format the numbers itself.
public enum PaceSentence {
    /// "À ce rythme, le quota finira la semaine à 92 % : la marge est suffisante."
    public static func pace(_ projection: PaceProjection) -> String {
        if projection.used >= 100 {
            return "Quota épuisé. Il se recharge à la réinitialisation."
        }
        let landing = FRFormat.percent(projection.landing, fraction: false)
        if projection.isOver {
            return "À ce rythme, le quota atteint \(landing) : il sera épuisé avant la réinitialisation."
        }
        return "À ce rythme, le quota finira la semaine à \(landing) : la marge est suffisante."
    }

    /// "Rythme actuel 0,52 %/h · rythme tenable 0,71 %/h · fin de fenêtre prévue à 88 %"
    public static func rates(_ projection: PaceProjection) -> String {
        let running = FRFormat.decimal(projection.runningPerHour, digits: 2)
        let needed = FRFormat.decimal(projection.neededPerHour, digits: 2)
        let landing = FRFormat.percent(projection.landing, fraction: false)
        return "Rythme actuel \(running) %/h · rythme tenable \(needed) %/h · fin de fenêtre prévue à \(landing)"
    }
}
