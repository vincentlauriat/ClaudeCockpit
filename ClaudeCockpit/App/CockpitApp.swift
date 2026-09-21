import SwiftUI

@main
struct CockpitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = CockpitStore()
    @StateObject private var updater = UpdaterController()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanelView()
                .environment(store)
                .environmentObject(updater)
        } label: {
            MenuBarLabel(title: store.menuBarTitle)
        }
        .menuBarExtraStyle(.window)

        Window("Claude Cockpit", id: MainWindowView.windowID) {
            MainWindowView()
                .environment(store)
                .environmentObject(updater)
                .background(WindowOpener(store: store))
        }
        .defaultSize(width: 1160, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Rechercher des mises à jour…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
        }

        Settings {
            SettingsView()
                .environment(store)
                .environmentObject(updater)
        }
    }
}

/// Menu-bar label: gauge glyph + weekly percent.
private struct MenuBarLabel: View {
    let title: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.33percent")
            Text(title).monospacedDigit()
        }
    }
}

/// Bridges SwiftUI's `openWindow` action to the store and starts the loops.
private struct WindowOpener: View {
    let store: CockpitStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear
            .onAppear {
                store.openWindowHandler = { openWindow(id: MainWindowView.windowID) }
                store.start()
            }
            .onReceive(NotificationCenter.default.publisher(for: .cockpitOpenMainWindow)) { _ in
                openWindow(id: MainWindowView.windowID)
            }
    }
}
