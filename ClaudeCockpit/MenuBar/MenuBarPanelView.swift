import SwiftUI

struct MenuBarPanelView: View {
    @Environment(CockpitStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Cockpit").font(.headline)
            Text("Panneau en construction").foregroundStyle(.secondary)
            Button("Ouvrir le cockpit") { store.openMainWindow() }
        }
        .padding(16)
        .frame(width: Theme.panelWidth)
        .onAppear {
            store.openWindowHandler = { openWindow(id: MainWindowView.windowID) }
            store.start()
        }
    }
}
