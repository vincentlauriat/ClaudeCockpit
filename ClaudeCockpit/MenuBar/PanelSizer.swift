import AppKit
import SwiftUI

/// Sizes a SwiftUI view the way a popover does: AppKit lays it out and reports the
/// size it asks for.
///
/// A `ScrollView` has no intrinsic height. Inside a `MenuBarExtra(.window)` the
/// popover then asks for a handful of points and the panel looks like it never
/// opens; `maxHeight` does not fix that, only a concrete `height` does. And SwiftUI
/// cannot measure the height from the inside: the scroll view's height *is* what is
/// being measured, so during the sizing pass it proposes zero to its content and
/// every reading comes back zero. Asking AppKit to size a non-scrolling copy has no
/// such loop.
@MainActor
enum PanelSizer {
    /// The controller has to live in a window: outside one, `preferredContentSize`
    /// comes back larger than what the popover would actually use.
    private static let host: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 10, height: 10),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isExcludedFromWindowsMenu = true
        return window
    }()

    static func naturalHeight(of view: some View) -> CGFloat {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        host.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        let height = controller.preferredContentSize.height
        host.contentViewController = nil
        return height
    }
}
