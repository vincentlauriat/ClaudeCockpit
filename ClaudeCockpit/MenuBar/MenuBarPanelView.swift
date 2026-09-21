import SwiftUI

struct MenuBarPanelView: View {
    @Environment(CockpitStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Cockpit").font(.headline)
            Text("Panneau en construction").foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
    }
}
