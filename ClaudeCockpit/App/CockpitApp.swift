import SwiftUI

@main
struct CockpitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = CockpitStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanelView()
                .environment(store)
        } label: {
            Label("Claude Cockpit", systemImage: "gauge.with.dots.needle.33percent")
        }
        .menuBarExtraStyle(.window)

        Window("Claude Cockpit", id: MainWindowView.windowID) {
            MainWindowView()
                .environment(store)
        }
        .defaultSize(width: 1160, height: 760)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}
