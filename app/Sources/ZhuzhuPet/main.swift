import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var pet: PetController!
    private let calendar = CalendarWatcher()
    private let updater = Updater()
    private var statusItem: NSStatusItem!
    private let sizes: [(String, CGFloat)] = [("小包", 1.0), ("大包", 1.5)]

    func applicationDidFinishLaunching(_ notification: Notification) {
        BubbleWindow.registerFont()
        let saved = UserDefaults.standard.double(forKey: "scale")
        let onTop = UserDefaults.standard.object(forKey: "onTop") as? Bool ?? true
        // The old 2x size was too big: anything above 1.5 becomes "大包".
        pet = PetController(scale: saved > 0 ? min(1.5, CGFloat(saved)) : 1.0, onTop: onTop)
        pet.start()
        pet.onChange = { [weak self] in self?.rebuildMenu() }
        pet.openSettings = { [weak self] in self?.statusItem.button?.performClick(nil) }
        calendar.onAlert = { [weak self] in self?.pet.announce($0) }
        calendar.onAccessChange = { [weak self] in self?.rebuildMenu() }
        updater.announce = { [weak self] text, buttons in self?.pet.showBubble(text, seconds: 120, buttons: buttons) }
        updater.start()
        if CommandLine.arguments.contains("--sleep-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pet.runSleepTest(wakeAfter: Double(ProcessInfo.processInfo.environment["ZHUZHU_WAKE"] ?? "9") ?? 9) }
        }
        if CommandLine.arguments.contains("--calendar-test") {   // a fake event, to see the alert
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.pet.announce(.init(title: "产品周会", start: Date().addingTimeInterval(600), moment: .soon(minutes: 10),
                                        link: URL(string: "https://zoom.us/j/123")))
            }
        }
        if CommandLine.arguments.contains("--bubble-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.pet.showBubble("该喝水啦～\n喝完告诉我一声", buttons: [.init(title: "喝了") {}, .init(title: "等会儿") {}])
            }
        }
        if CommandLine.arguments.contains("--bar-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pet.showActionBar() }
        }
        if CommandLine.arguments.contains("--feed-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let vf = (self.pet.window.screen ?? NSScreen.main!).visibleFrame
                self.pet.cursorOverride = CGPoint(x: self.pet.window.frame.midX + 300, y: vf.minY + 120)
                self.pet.feedShrimp()
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(ProcessInfo.processInfo.environment["ZHUZHU_HOLD"] ?? "1")!) { self.pet.dropShrimp(); self.pet.cursorOverride = nil }
            }
        }
        if CommandLine.arguments.contains("--play-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pet.runPlayTest() }
        }
        if CommandLine.arguments.contains("--clip-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pet.runClipTest() }
        }
        if CommandLine.arguments.contains("--pet-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pet.runPetTest() }
        }
        if CommandLine.arguments.contains("--dizzy-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pet.runDizzyTest() }
        }
        if CommandLine.arguments.contains("--perch-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pet.runPerchTest() }
        }
        if CommandLine.arguments.contains("--water-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pet.runWaterTest() }
        }
        if CommandLine.arguments.contains("--update-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.updater.checkInBackground() }
        }
        if CommandLine.arguments.contains("--stretch-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pet.stretchNow() }
        }
        if CommandLine.arguments.contains("--wall-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pet.goWallScratch() }
        }
        if CommandLine.arguments.contains("--rest-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pet.restInMiddle() }
        }
        if CommandLine.arguments.contains("--peek-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pet.runPeekTest() }
        }
        if CommandLine.arguments.contains("--look-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pet.runLookTest() }
        }
        if CommandLine.arguments.contains("--lift-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pet.runLiftTest() }
        }
        if CommandLine.arguments.contains("--drink-now") {   // for testing the drinking flow
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pet.goDrink() }
        }
        enableLoginItemOnce()
        buildStatusItem()
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // Monochrome pixel cat head: a template image, so macOS tints it for light and dark menu bars.
            let icon = NSImage(size: NSSize(width: 18, height: 18))
            for name in ["menubar", "menubar@2x"] {
                if let url = Bundle.main.resourceURL?.appendingPathComponent("sprites/icon/\(name).png"),
                   let rep = NSImageRep(contentsOf: url) { rep.size = NSSize(width: 18, height: 18); icon.addRepresentation(rep) }
            }
            icon.isTemplate = true
            button.image = icon
            button.imageScaling = .scaleNone
            button.toolTip = "猪猪包"
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let cups = NSMenuItem(title: "今天喝了 \(pet.cupsToday) 杯水", action: nil, keyEquivalent: "")
        cups.isEnabled = false
        menu.addItem(cups)
        menu.addItem(.separator())
        let remindItem = NSMenuItem(title: "喝水提醒", action: nil, keyEquivalent: "")
        let remindMenu = NSMenu()
        for (name, minutes) in [("每 30 分钟", 30.0), ("每 45 分钟", 45.0), ("每 60 分钟", 60.0), ("每 90 分钟", 90.0), ("关闭", 0.0)] {
            let item = NSMenuItem(title: name, action: #selector(setReminder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = minutes
            item.state = abs(pet.drinkInterval - minutes * 60) < 1 ? .on : .off
            remindMenu.addItem(item)
        }
        remindItem.submenu = remindMenu
        menu.addItem(remindItem)
        let standItem = NSMenuItem(title: "久坐提醒", action: nil, keyEquivalent: "")
        let standMenu = NSMenu()
        for (name, minutes) in [("连续用电脑 30 分钟", 30.0), ("连续用电脑 50 分钟", 50.0), ("连续用电脑 90 分钟", 90.0), ("关闭", 0.0)] {
            let item = NSMenuItem(title: name, action: #selector(setStand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = minutes
            item.state = abs(pet.standInterval - minutes * 60) < 1 ? .on : .off
            standMenu.addItem(item)
        }
        standItem.submenu = standMenu
        menu.addItem(standItem)

        let calItem = NSMenuItem(title: "日程提醒", action: nil, keyEquivalent: "")
        let calMenu = NSMenu()
        let onOff = NSMenuItem(title: calendar.enabled ? "关闭日程提醒" : "开启日程提醒（读取日历）", action: #selector(toggleCalendar), keyEquivalent: "")
        onOff.target = self
        calMenu.addItem(onOff)
        if calendar.enabled && calendar.accessDenied {
            let fix = NSMenuItem(title: "没有日历权限：去系统设置里打开", action: #selector(openCalendarPrivacy), keyEquivalent: "")
            fix.target = self
            calMenu.addItem(fix)
        }
        calMenu.addItem(.separator())
        for m in [5, 10, 15] {
            let item = NSMenuItem(title: "提前 \(m) 分钟", action: #selector(setLead(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m
            item.state = calendar.lead == m ? .on : .off
            calMenu.addItem(item)
        }
        calItem.submenu = calMenu
        menu.addItem(calItem)

        menu.addItem(.separator())

        let pause = NSMenuItem(title: pet.paused ? "继续走动" : "原地坐着", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)

        let placeItem = NSMenuItem(title: "显示位置", action: nil, keyEquivalent: "")
        let placeMenu = NSMenu()
        for (name, value) in [("保持在最前", true), ("只在桌面（在窗口后面）", false)] {
            let item = NSMenuItem(title: name, action: #selector(setPlace(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = pet.onTop == value ? .on : .off
            placeMenu.addItem(item)
        }
        placeItem.submenu = placeMenu
        menu.addItem(placeItem)

        let eyeItem = NSMenuItem(title: "眼睛颜色", action: nil, keyEquivalent: "")
        let eyeMenu = NSMenu()
        for (name, value) in [("自动（白天蓝色，19 点后深色）", "auto"), ("始终蓝色", "day"), ("始终深色", "night")] {
            let item = NSMenuItem(title: name, action: #selector(setEyes(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = pet.eyeMode.rawValue == value ? .on : .off
            eyeMenu.addItem(item)
        }
        eyeItem.submenu = eyeMenu
        menu.addItem(eyeItem)

        let sizeItem = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (name, value) in sizes {
            let item = NSMenuItem(title: name, action: #selector(setSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(pet.scale - value) < 0.01 ? .on : .off
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        let bowlItem = NSMenuItem(title: "水碗", action: nil, keyEquivalent: "")
        let bowlMenu = NSMenu()
        for (name, value) in [("只在喝水时出现", false), ("一直显示", true)] {
            let item = NSMenuItem(title: name, action: #selector(setBowlMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = pet.bowlAlwaysVisible == value ? .on : .off
            bowlMenu.addItem(item)
        }
        bowlItem.submenu = bowlMenu
        menu.addItem(bowlItem)

        menu.addItem(.separator())
        let login = NSMenuItem(title: "开机自动启动", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if SMAppService.mainApp.status == .requiresApproval { login.title = "开机自动启动（需在系统设置里允许）" }
        menu.addItem(login)
        let update = NSMenuItem(title: "检查更新…", action: #selector(Updater.checkForUpdates), keyEquivalent: "")
        update.target = updater
        menu.addItem(update)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let about = NSMenuItem(title: "版本 \(version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        let quit = NSMenuItem(title: "退出猪猪包", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func togglePause() { pet.paused.toggle(); rebuildMenu() }

    @objc private func setSize(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? CGFloat else { return }
        pet.scale = value
        UserDefaults.standard.set(Double(value), forKey: "scale")
        rebuildMenu()
    }

    @objc private func setPlace(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Bool else { return }
        pet.onTop = value
        UserDefaults.standard.set(value, forKey: "onTop")
        rebuildMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() }
            else if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            else { try service.register() }
        } catch {
            NSLog("login item: \(error.localizedDescription)")
        }
        rebuildMenu()
    }
    /// On by default: the first time it runs, add itself to the login items once.
    private func enableLoginItemOnce() {
        let key = "loginItemOffered"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
    }
    @objc private func toggleCalendar() { calendar.enabled.toggle(); rebuildMenu() }
    @objc private func setLead(_ sender: NSMenuItem) { if let m = sender.representedObject as? Int { calendar.lead = m; rebuildMenu() } }
    @objc private func openCalendarPrivacy() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(u) }
    }
    @objc private func setEyes(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String, let mode = PetController.EyeMode(rawValue: v) else { return }
        pet.eyeMode = mode
        rebuildMenu()
    }
    @objc private func setStand(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Double else { return }
        pet.standInterval = minutes * 60
        rebuildMenu()
    }
    @objc private func setBowlMode(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Bool else { return }
        pet.bowlAlwaysVisible = value
        rebuildMenu()
    }
    @objc private func setReminder(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Double else { return }
        pet.drinkInterval = minutes * 60
        rebuildMenu()
    }
    func menuWillOpen(_ menu: NSMenu) {
        // refresh the cup count; rebuild after the menu closes to avoid swapping it while open
        if let first = menu.items.first { first.title = "今天喝了 \(pet.cupsToday) 杯水" }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
