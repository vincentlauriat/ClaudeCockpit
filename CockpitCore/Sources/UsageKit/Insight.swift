import Foundation

/// One automatically-derived signal about the currently filtered usage. See `InsightEngine`.
///
/// The source app carried only a `Level` and an English sentence. The sentence is kept
/// verbatim so nothing is lost, and `kind` carries the same information structurally so the
/// French UI can render its own wording without re-parsing the text.
public struct Insight: Identifiable, Hashable, Sendable {
    public enum Level: String, CaseIterable, Hashable, Sendable {
        case critical = "Critical"
        case warning = "Warning"
        case good = "Good"
        case info = "Info"
    }

    public enum Kind: Hashable, Sendable {
        /// Cost rose by this fraction (0.35 == +35 %) versus last week.
        case costUp(fraction: Double)
        /// Cost fell by this fraction (positive value) versus last week.
        case costDown(fraction: Double)
        /// This model id has no dedicated pricing tier and falls back to the Sonnet rate.
        case unpricedModel(String)
        /// Cache read tokens over cacheable tokens, when notably high.
        case cacheHitRate(Double)
        /// Nothing worth reporting in this range.
        case noNotableChange
    }

    public var id: String { level.rawValue + text }
    public let level: Level
    public let kind: Kind
    /// English sentence, identical to the source app's.
    public let text: String

    public init(level: Level, kind: Kind, text: String) {
        self.level = level
        self.kind = kind
        self.text = text
    }
}
