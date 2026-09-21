import SwiftUI

struct MainWindowView: View {
    static let windowID = "main"
    @Environment(CockpitStore.self) private var store
    var body: some View {
        Text("Claude Cockpit — fenêtre principale en construction")
            .frame(minWidth: 1060, minHeight: 700)
    }
}
