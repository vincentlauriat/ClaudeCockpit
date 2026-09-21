import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menuBarOnly = UserDefaults.standard.bool(forKey: SettingsKey.menuBarOnly)
        NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no window open reopens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NotificationCenter.default.post(name: .cockpitOpenMainWindow, object: nil) }
        return true
    }
}

extension Notification.Name {
    static let cockpitOpenMainWindow = Notification.Name("fr.vincentlauriat.claudecockpit.openMainWindow")
}
