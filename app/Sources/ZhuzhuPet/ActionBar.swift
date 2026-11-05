import AppKit

/// A small pill of pixel-art icon buttons that pops up above the cat on right-click.
/// Closes on the × button, a click anywhere else, another right-click, or when the pointer wanders off.
final class ActionBar: NSPanel {
    struct Action { let icon: CGImage; let tip: String; let run: () -> Void }

    private var actions: [Action] = []
    private var watchTimer: Timer?
    private var monitors: [Any] = []
    private var shownAt = Date()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }

    /// `sticky`: stays up (clicks elsewhere and buttons don't close it); × runs `onClose`.
    /// `label`: a pixel tag at the start of the bar ("在小明家").
    func show(_ actions: [Action], close closeIcon: CGImage, above anchor: CGRect, level: NSWindow.Level,
              label: CGImage? = nil, sticky: Bool = false, onClose: (() -> Void)? = nil) {
        self.actions = actions
        self.sticky = sticky
        let button: CGFloat = 22, gap: CGFloat = 2, pad: CGFloat = 3
        let count = CGFloat(actions.count + 1)
        let labelW = label.map { CGFloat($0.width) + 4 } ?? 0
        let width = count * button + (count - 1) * gap + pad * 2 + 6 + labelW    // a little extra room before ×
        let height = button + pad * 2
        let box = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(white: 1, alpha: 0.95).cgColor
        box.layer?.cornerRadius = height / 2
        box.layer?.borderWidth = 1.5
        box.layer?.borderColor = NSColor(red: 0.25, green: 0.24, blue: 0.26, alpha: 1).cgColor
        var x = pad
        if let label {
            let l = CALayer()
            l.contents = label
            l.magnificationFilter = .nearest
            l.frame = CGRect(x: x + 3, y: (height - CGFloat(label.height)) / 2, width: CGFloat(label.width), height: CGFloat(label.height))
            box.layer?.addSublayer(l)
            x += labelW
        }
        for (i, a) in actions.enumerated() {
            box.addSubview(IconButton(frame: CGRect(x: x, y: pad, width: button, height: button), icon: a.icon, tip: a.tip) { [weak self] in
                guard let self else { return }
                let run = self.actions[i].run
                if !self.sticky { self.dismiss() }
                run()
            })
            x += button + gap
        }
        // A thin divider, then ×.
        let divider = NSView(frame: CGRect(x: x + 1, y: pad + 4, width: 1, height: button - 8))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 0.75, alpha: 1).cgColor
        box.addSubview(divider)
        x += 6
        box.addSubview(IconButton(frame: CGRect(x: x, y: pad, width: button, height: button), icon: closeIcon, tip: sticky ? "回家" : "关闭") { [weak self] in
            self?.dismiss()
            onClose?()
        })
        contentView = box
        self.level = level
        setFrame(CGRect(x: anchor.midX - width / 2, y: anchor.maxY + 2, width: width, height: height), display: true)
        orderFrontRegardless()
        shownAt = Date()
        if sticky { unwatch() } else { watch() }
    }

    private var sticky = false

    /// Keep a sticky bar next to something that moves (bottom-left corner at `origin`, kept on screen).
    func move(to origin: CGPoint) {
        var o = origin
        if let s = NSScreen.screens.first(where: { $0.frame.contains(origin) }) ?? NSScreen.main {
            o.x = min(max(o.x, s.visibleFrame.minX + 4), s.visibleFrame.maxX - frame.width - 4)
            o.y = min(max(o.y, s.visibleFrame.minY + 4), s.visibleFrame.maxY - frame.height - 4)
        }
        if abs(o.x - frame.minX) > 0.5 || abs(o.y - frame.minY) > 0.5 { setFrameOrigin(o) }
    }

    private func watch() {
        unwatch()
        // Any click outside the bar closes it (clicks in other apps and in our own windows).
        let outside: (NSEvent) -> Void = { [weak self] _ in
            guard let self, self.isVisible, Date().timeIntervalSince(self.shownAt) > 0.2 else { return }
            if !self.frame.contains(NSEvent.mouseLocation) { self.dismiss() }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: outside) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in outside(e); return e }) { monitors.append(l) }
        // And so does wandering off for a couple of seconds.
        var awaySince: Date?
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.frame.insetBy(dx: -40, dy: -60).contains(NSEvent.mouseLocation) { awaySince = nil }
            else if awaySince == nil { awaySince = Date() }
            if let a = awaySince, Date().timeIntervalSince(a) > 2 { self.dismiss() }
        }
    }

    private func unwatch() {
        watchTimer?.invalidate(); watchTimer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    func dismiss() {
        unwatch()
        orderOut(nil)
    }
}

/// A pixel-art icon button: crisp nearest-neighbour icon, soft highlight on hover.
final class IconButton: NSView {
    private let iconLayer = CALayer()
    private let onClick: () -> Void

    init(frame: CGRect, icon: CGImage, tip: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = frame.height / 2
        iconLayer.contents = icon
        iconLayer.magnificationFilter = .nearest
        iconLayer.frame = CGRect(x: (frame.width - 16) / 2, y: (frame.height - 16) / 2, width: 16, height: 16)
        layer?.addSublayer(iconLayer)
        toolTip = tip
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = NSColor(white: 0.88, alpha: 1).cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
    override func mouseDown(with event: NSEvent) { layer?.backgroundColor = NSColor(white: 0.8, alpha: 1).cgColor }
    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = nil
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
}
