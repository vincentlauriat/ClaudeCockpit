import AppKit
import Sparkle

/// Sparkle's update flow for a hybrid app.
///
/// When the user chooses "menu bar only", the app runs as `.accessory` with no Dock
/// icon: Sparkle's dialogs would open behind everything with nothing to bring them
/// forward. So the app is raised to `.regular` for the duration of an update session
/// and lowered back afterwards when it was an accessory before.
@MainActor
final class UpdaterController: ObservableObject {
    @Published private(set) var canCheck = true
    /// Set when a background check finds a version, so the UI can offer it without
    /// Sparkle stealing focus.
    @Published private(set) var pendingVersion: String?

    private let controller: SPUStandardUpdaterController
    private let driverDelegate = ActivationPolicyDelegate()
    private var observation: NSKeyValueObservation?

    init(starting: Bool = true) {
        controller = SPUStandardUpdaterController(
            startingUpdater: starting,
            updaterDelegate: nil,
            userDriverDelegate: driverDelegate)
        guard starting else { return }
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = false
        driverDelegate.onScheduledUpdateFound = { [weak self] version in
            Task { @MainActor in self?.pendingVersion = version }
        }
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            Task { @MainActor in self?.canCheck = updater.canCheckForUpdates }
        }
    }

    func checkForUpdates() {
        pendingVersion = nil
        controller.updater.checkForUpdates()
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

private final class ActivationPolicyDelegate: NSObject, SPUStandardUserDriverDelegate {
    private var raisedFromAccessory = false
    var onScheduledUpdateFound: ((String) -> Void)?

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool { false }

    func standardUserDriverWillShowModalAlert() { raise() }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if handleShowingUpdate { raise() } else { onScheduledUpdateFound?(update.displayVersionString) }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {}

    func standardUserDriverWillFinishUpdateSession() { lower() }

    private func raise() {
        if NSApp.activationPolicy() == .accessory {
            raisedFromAccessory = true
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func lower() {
        guard raisedFromAccessory else { return }
        raisedFromAccessory = false
        NSApp.setActivationPolicy(.accessory)
    }
}
