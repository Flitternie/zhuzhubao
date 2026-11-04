import AppKit
import Sparkle

/// Auto-update with Sparkle. The app checks the appcast on GitHub Releases once a day (Info.plist
/// `SUFeedURL`); updates must be signed with the EdDSA key whose public half is `SUPublicEDKey`.
/// Updates install by themselves (`SUAutomaticallyUpdate`): downloaded quietly, then the cat says it
/// will be right back and the app restarts as the new version, and says so after the restart.
/// Only if Sparkle cannot install silently (e.g. no write access to the app's folder) does the cat
/// ask in a bubble, and "更新" opens Sparkle's window.
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!
    /// Shows the cat's bubble: text and buttons.
    var announce: ((String, [BubbleWindow.Button]) -> Void)?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    func start() {
        controller.startUpdater()
        // Back after an update: say so once.
        let now = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let last = UserDefaults.standard.string(forKey: "lastRunBuild")
        UserDefaults.standard.set(now, forKey: "lastRunBuild")
        if let last, !last.isEmpty, last.compare(now, options: .numeric) == .orderedAscending {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.announce?(["更新好啦！现在是 \(short)", "换好新毛毛啦～现在是 \(short)"].randomElement()!, [])
            }
        }
    }

    // MARK: SPUUpdaterDelegate

    /// Testing only: ZHUZHU_FEED points at a local appcast instead of GitHub.
    func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["ZHUZHU_FEED"]
    }

    /// The update is downloaded and ready: install it now (restart) instead of waiting for a quit,
    /// which for a desktop pet may be weeks away.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        announce?("我去换身新毛毛，马上回来～", [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { immediateInstallHandler() }
        return true
    }

    var canCheck: Bool { controller.updater.canCheckForUpdates }

    /// The same quiet check the daily schedule runs (used by --update-test).
    func checkInBackground() { controller.updater.checkForUpdatesInBackground() }

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
