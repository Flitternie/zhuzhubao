import AppKit
import Sparkle

/// Auto-update with Sparkle. The app checks the appcast on GitHub Releases once a day (Info.plist
/// `SUFeedURL`); updates must be signed with the EdDSA key whose public half is `SUPublicEDKey`.
/// A scheduled check that finds an update does not pop up Sparkle's window by itself: the cat tells
/// you in a bubble, and "更新" opens the window with the release notes and the install button.
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!
    /// Shows the cat's bubble: text and buttons.
    var announce: ((String, [BubbleWindow.Button]) -> Void)?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    func start() { controller.startUpdater() }

    var canCheck: Bool { controller.updater.canCheckForUpdates }

    /// Menu item "检查更新…" (also used by the bubble's "更新" button).
    @objc func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)     // an accessory app: bring Sparkle's window to the front
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate (gentle reminders for a menu-bar app)

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false                                       // the cat announces it instead
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        let lines = ["我学会新本领啦！", "猪猪包有新版本啦～", "叮！我长大了一点点"]
        let text = lines.randomElement()! + "\n要更新到 \(update.displayVersionString) 吗？"
        announce?(text, [
            .init(title: "更新") { [weak self] in self?.checkForUpdates() },
            .init(title: "下次吧") {},
        ])
    }
}
