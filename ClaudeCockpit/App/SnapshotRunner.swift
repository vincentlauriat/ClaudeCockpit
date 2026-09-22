import AppKit
import SwiftUI

/// Developer mode: when `CLAUDECOCKPIT_SNAPSHOT_DIR` is set, the app walks every
/// section of the main window, renders it from inside the process (no screen
/// recording permission needed), renders the menu-bar panel in a temporary
/// window, writes PNGs into that directory and quits. Used for the README and
/// the landing page screenshots.
@MainActor
enum SnapshotRunner {
    static var requestedDirectory: URL? {
        guard let raw = ProcessInfo.processInfo.environment["CLAUDECOCKPIT_SNAPSHOT_DIR"], !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    static func runIfRequested(store: CockpitStore, updater: UpdaterController, select: @escaping (CockpitSection) -> Void) async {
        guard let dir = requestedDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Let the data sources settle (transcripts, rtk, skills, quota).
        try? await Task.sleep(for: .seconds(8))

        let sections: [(CockpitSection, String)] = [
            (.overview, "overview"), (.usage, "usage"), (.quotas, "quotas"), (.rtk, "rtk"),
            (.skills, "skills"), (.agents, "agents"), (.commands, "commands"), (.settings, "settings"),
        ]
        for (section, name) in sections {
            select(section)
            try? await Task.sleep(for: .seconds(1.5))
            if let window = NSApp.windows.first(where: { $0.title == "Claude Cockpit" && $0.isVisible }) {
                write(window, to: dir.appendingPathComponent("\(name).png"))
            }
        }

        // Menu-bar panel, hosted in a plain window of the same width.
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 720),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView:
            MenuBarPanelView().environment(store).environmentObject(updater))
        panel.center()
        panel.orderFront(nil)
        try? await Task.sleep(for: .seconds(2))
        if let view = panel.contentView {
            view.layoutSubtreeIfNeeded()
            let fitting = view.fittingSize
            if fitting.height > 0 { panel.setContentSize(NSSize(width: Theme.panelWidth, height: min(fitting.height, 900))) }
            try? await Task.sleep(for: .seconds(0.5))
        }
        write(panel, to: dir.appendingPathComponent("panel.png"))
        panel.close()

        NSApp.terminate(nil)
    }

    private static func write(_ window: NSWindow, to url: URL) {
        // The theme frame (content view's superview) includes the title bar & toolbar.
        guard let content = window.contentView else { return }
        let view = content.superview ?? content
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            NSLog("snapshot written: %@", url.path)
        }
    }
}
