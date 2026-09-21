import SwiftUI
import CockpitShared
import UsageKit

/// App-layer presentation of the UsageKit value types: colours (UsageKit is Foundation-only)
/// and French labels (its raw values stay English so persisted selections and grouping keys
/// survive the port untouched).
enum UsagePalette {
    /// The four token series, in a blue/violet/teal family so the terracotta cost line
    /// overlaid on the same chart never reads as one more token bucket.
    static let input = Theme.blue
    static let output = Theme.violet
    static let cacheRead = Theme.adaptive(light: 0x0E9AA7, dark: 0x3ECFD5)
    static let cacheCreation = Theme.adaptive(light: 0x6C8AA8, dark: 0x8FA8C0)
    /// Cost overlay on the daily chart. Cost *figures* use `Theme.blue`, the usage accent;
    /// the line needs a hue no token series occupies.
    static let cost = Theme.accent
    /// Context series (last week / yesterday) — never competes with the emphasis series.
    static let context = Theme.mist
}

extension UsageSeries {
    var frenchLabel: String {
        switch self {
        case .input: "Entrée"
        case .output: "Sortie"
        case .cacheRead: "Cache lu"
        case .cacheCreation: "Cache créé"
        }
    }

    var color: Color {
        switch self {
        case .input: UsagePalette.input
        case .output: UsagePalette.output
        case .cacheRead: UsagePalette.cacheRead
        case .cacheCreation: UsagePalette.cacheCreation
        }
    }

    /// Keys of the chart's foreground style scale — must match the series values passed to
    /// `.value(_:_:)`, or Swift Charts silently falls back to its default palette.
    static var styleScale: KeyValuePairs<String, Color> {
        [
            UsageSeries.input.frenchLabel: UsagePalette.input,
            UsageSeries.output.frenchLabel: UsagePalette.output,
            UsageSeries.cacheRead.frenchLabel: UsagePalette.cacheRead,
            UsageSeries.cacheCreation.frenchLabel: UsagePalette.cacheCreation,
        ]
    }
}

extension ModelFamily {
    /// Family names are proper nouns — identical in French.
    var label: String { rawValue }

    var color: Color {
        switch self {
        case .opus: Theme.violet
        case .sonnet: Theme.blue
        case .haiku: UsagePalette.cacheRead
        case .fable: Theme.accent
        }
    }
}

extension BreakdownDimension {
    var frenchLabel: String {
        switch self {
        case .project: "Projet"
        case .agent: "Agent"
        case .skill: "Skill"
        }
    }

    /// Turns not run by a sub-agent are grouped under the module's English key.
    func frenchRowLabel(_ label: String) -> String {
        label == BreakdownDimension.directLabel ? "Direct (session principale)" : label
    }
}

extension Insight.Level {
    var frenchLabel: String {
        switch self {
        case .critical: "Critique"
        case .warning: "Attention"
        case .good: "Bon"
        case .info: "Info"
        }
    }

    var color: Color {
        switch self {
        case .critical: .red
        case .warning: .orange
        case .good: .green
        case .info: Theme.blue
        }
    }
}

extension Insight {
    /// French sentence rebuilt from `kind`. `text` is the source app's English wording, kept
    /// verbatim by UsageKit on purpose — it is never displayed here.
    var frenchText: String {
        switch kind {
        case .costUp(let fraction):
            "Coût en hausse de \(FRFormat.percent(fraction)) par rapport à la semaine dernière."
        case .costDown(let fraction):
            "Coût en baisse de \(FRFormat.percent(fraction)) par rapport à la semaine dernière."
        case .unpricedModel(let model):
            "\(model) n'a pas de tarif dédié — le tarif Sonnet par défaut est appliqué."
        case .cacheHitRate(let rate):
            "Taux de lecture du cache à \(FRFormat.percent(rate)) — cela contient les coûts."
        case .noNotableChange:
            "Aucun changement notable sur cette période."
        }
    }
}
