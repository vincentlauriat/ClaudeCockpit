import Foundation
import Observation

enum SourceState: Equatable {
    case idle, loading, ready(Date), failed(String)
}

@MainActor @Observable
final class CockpitStore {
    var usageState: SourceState = .idle
    var quotaState: SourceState = .idle
    var rtkState: SourceState = .idle
    var skillsState: SourceState = .idle
}
