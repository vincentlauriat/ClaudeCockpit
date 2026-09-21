import SwiftUI
import SkillsKit

struct ResourcesView: View {
    let kind: ResourceKind
    @Environment(CockpitStore.self) private var store
    var body: some View {
        Text("\(kind.pluralLabel) — en construction").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
