import AppKit
import CoreText

/// Pixel-art speech bubble: drawn on a small bitmap (one bitmap pixel = one sprite pixel) with the
/// Fusion Pixel font and no anti-aliasing, then scaled up with nearest-neighbour like the cat.
/// It can carry a few buttons ("喝了", "等会儿", ...).
final class BubbleWindow: NSPanel {
    struct Button { let title: String; let run: () -> Void }

    static let fontName = "Fusion-Pixel-12px-Prop-zh-Hans-Regular"
    static func registerFont() {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("fonts/fusion-pixel-12px-proportional-zh_hans.otf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    private let view = BubbleView()
    private var hideTimer: Timer?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = view
        view.onButton = { [weak self] i in
            guard let self, i < self.buttons.count else { return }
            let run = self.buttons[i].run
            self.orderOut(nil)
            run()
        }
    }

    override var canBecomeKey: Bool { field != nil }
    private var buttons: [Button] = []
    private var field: NSTextField?
    private var fieldDelegate: FieldDelegate?
    /// What the bubble currently says, for callers that only want to close their own bubble.
    private(set) var text = ""

    /// `pixel` is the size of one art pixel in points (the cat's scale). `tipX` is where the tail points, in screen x.
    func show(_ text: String, buttons: [Button] = [], tipX: CGFloat, baseY: CGFloat, pixel: CGFloat,
              level: NSWindow.Level, seconds: TimeInterval) {
        show(text, buttons: buttons, input: nil, tipX: tipX, baseY: baseY, pixel: pixel, level: level, seconds: seconds)
    }

    /// A bubble with a pixel text box under the text: "好" (or Return) passes what was typed, "算了" (or Esc) nil.
    func ask(_ text: String, initial: String, maxLength: Int, tipX: CGFloat, baseY: CGFloat, pixel: CGFloat,
             level: NSWindow.Level, done: @escaping (String?) -> Void) {
        var finished = false
        let finish: (String?) -> Void = { [weak self] value in
            guard !finished else { return }
            finished = true
            self?.endInput()
            self?.orderOut(nil)
            let v = value.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength)) }
            done(v?.isEmpty == true ? nil : v)
        }
        show(text, buttons: [.init(title: "好") { [weak self] in finish(self?.field?.stringValue) }, .init(title: "算了") { finish(nil) }],
             input: 120, tipX: tipX, baseY: baseY, pixel: pixel, level: level, seconds: 180)
        let r = view.inputRect
        let f = NSTextField(frame: CGRect(x: (r.minX + 4) * pixel, y: (r.minY + 2) * pixel, width: (r.width - 8) * pixel, height: (r.height - 3) * pixel))
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = NSFont(name: BubbleWindow.fontName, size: 12 * pixel)
        f.textColor = NSColor(red: CGFloat(BubbleView.ink.r) / 255, green: CGFloat(BubbleView.ink.g) / 255, blue: CGFloat(BubbleView.ink.b) / 255, alpha: 1)
        f.stringValue = initial
        f.cell?.usesSingleLineMode = true
        f.cell?.lineBreakMode = .byClipping
        let fd = FieldDelegate(submit: { [weak f] in finish(f?.stringValue) }, cancel: { finish(nil) })
        f.delegate = fd
        fieldDelegate = fd
        field = f
        view.addSubview(f)
        ignoresMouseEvents = false
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
    }

    private func endInput() {
        field?.removeFromSuperview()
        field = nil
        fieldDelegate = nil
    }

    override func orderOut(_ sender: Any?) {
        if field != nil { endInput() }
        super.orderOut(sender)
    }

    private func show(_ text: String, buttons: [Button], input: Int?, tipX: CGFloat, baseY: CGFloat, pixel: CGFloat,
                      level: NSWindow.Level, seconds: TimeInterval) {
        if field != nil { endInput() }
        self.text = text
        self.buttons = buttons
        view.layout(text: text, buttons: buttons.map(\.title), input: input)
        let size = CGSize(width: CGFloat(view.artWidth) * pixel, height: CGFloat(view.artHeight) * pixel)
        view.pixel = pixel
        ignoresMouseEvents = buttons.isEmpty
        self.level = level
        var x = tipX - size.width / 2
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: tipX, y: baseY)) }) {
            x = min(max(x, screen.visibleFrame.minX + 4), screen.visibleFrame.maxX - size.width - 4)
        }
        view.tipOffset = Int(((tipX - x) / pixel).rounded())
        view.render()
        setFrame(CGRect(x: x, y: baseY, width: size.width, height: size.height), display: true)
        view.frame = CGRect(origin: .zero, size: size)
        orderFrontRegardless()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.orderOut(nil) }
    }
}

/// Return submits, Esc cancels.
private final class FieldDelegate: NSObject, NSTextFieldDelegate {
    let submit: () -> Void, cancel: () -> Void
    init(submit: @escaping () -> Void, cancel: @escaping () -> Void) { self.submit = submit; self.cancel = cancel }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { submit(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        return false
    }
}

/// Draws the bubble bitmap and handles button clicks / hover.
final class BubbleView: NSView {
    var onButton: ((Int) -> Void)?
    var pixel: CGFloat = 1
    var tipOffset = 0
    private(set) var artWidth = 40
    private(set) var artHeight = 20
    private var lines: [String] = []
    private var buttonTitles: [String] = []
    private var buttonRects: [CGRect] = []      // in art pixels, origin bottom-left
    private(set) var inputRect = CGRect.zero    // the text box, in art pixels (zero when none)
    private var hover: Int? { didSet { if hover != oldValue { render() } } }
    private let imageLayer = CALayer()
    private var tracking: NSTrackingArea?

    static let ink = (r: 64, g: 60, b: 66)
    static let tail = 4, pad = 6, lineH = 14, btnH = 14, btnGap = 4, inputH = 17

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageLayer.magnificationFilter = .nearest
        imageLayer.contentsGravity = .resize
        layer?.addSublayer(imageLayer)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private var font: CTFont { CTFontCreateWithName(BubbleWindow.fontName as CFString, 12, nil) }

    private func textWidth(_ s: String) -> Int {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
        return Int(ceil(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    func layout(text: String, buttons: [String], input: Int? = nil) {
        lines = text.components(separatedBy: "\n")
        buttonTitles = buttons
        let textW = lines.map(textWidth).max() ?? 0
        let btnWs = buttons.map { textWidth($0) + 10 }
        let btnRow = btnWs.reduce(0, +) + max(0, btnWs.count - 1) * Self.btnGap
        artWidth = max(textW, btnRow, input ?? 0) + Self.pad * 2
        let textH = lines.count * Self.lineH
        let inputRow = input == nil ? 0 : Self.inputH + Self.btnGap
        artHeight = Self.tail + Self.pad + textH + inputRow + (buttons.isEmpty ? 0 : Self.btnGap + Self.btnH) + Self.pad - 2
        inputRect = .zero
        if let input {
            let iy = Self.tail + Self.pad - 1 + (buttons.isEmpty ? 0 : Self.btnH + Self.btnGap)
            inputRect = CGRect(x: (artWidth - input) / 2, y: iy, width: input, height: Self.inputH)
        }
        // Buttons centred in a row under the text.
        buttonRects = []
        var bx = (artWidth - btnRow) / 2
        let by = Self.tail + Self.pad - 1
        for w in btnWs {
            buttonRects.append(CGRect(x: bx, y: by, width: w, height: Self.btnH))
            bx += w + Self.btnGap
        }
    }

    func render() {
        let w = artWidth, h = artHeight
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setShouldAntialias(false)
        ctx.setAllowsAntialiasing(false)
        ctx.setShouldSmoothFonts(false)
        ctx.interpolationQuality = .none
        let ink = CGColor(red: CGFloat(Self.ink.r) / 255, green: CGFloat(Self.ink.g) / 255, blue: CGFloat(Self.ink.b) / 255, alpha: 1)
        let paper = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let shade = CGColor(red: 0.86, green: 0.85, blue: 0.88, alpha: 1)
        func px(_ x: Int, _ y: Int, _ c: CGColor) { ctx.setFillColor(c); ctx.fill(CGRect(x: x, y: y, width: 1, height: 1)) }
        func rect(_ x: Int, _ y: Int, _ rw: Int, _ rh: Int, _ c: CGColor) { ctx.setFillColor(c); ctx.fill(CGRect(x: x, y: y, width: rw, height: rh)) }
        // Body: stepped corners, 1 px ink outline, a pixel shadow line on the bottom/right inside.
        let b0 = Self.tail, bh = h - Self.tail
        rect(2, b0, w - 4, bh, paper); rect(1, b0 + 1, w - 2, bh - 2, paper); rect(0, b0 + 2, w, bh - 4, paper)
        rect(2, b0, w - 4, 1, ink); rect(2, b0 + bh - 1, w - 4, 1, ink)
        rect(0, b0 + 2, 1, bh - 4, ink); rect(w - 1, b0 + 2, 1, bh - 4, ink)
        px(1, b0 + 1, ink); px(w - 2, b0 + 1, ink); px(1, b0 + bh - 2, ink); px(w - 2, b0 + bh - 2, ink)
        rect(2, b0 + 1, w - 4, 1, shade); rect(w - 2, b0 + 2, 1, bh - 4, shade)
        // Tail: a small stepped triangle pointing down at the cat.
        let tx = min(max(tipOffset, 6), w - 7)
        for k in 0..<Self.tail {
            let half = Self.tail - 1 - k        // widest just under the body
            rect(tx - half, k, half * 2 + 1, 1, paper)
            px(tx - half - 1, k, ink); px(tx + half + 1, k, ink)
        }
        px(tx, 0, ink)
        rect(tx - Self.tail + 1, b0, (Self.tail - 1) * 2 + 1, 1, paper)    // open the outline where the tail joins
        // Text, top-down.
        ctx.setFillColor(ink)
        for (i, s) in lines.enumerated() {
            let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: ink)!])
            let line = CTLineCreateWithAttributedString(attr)
            let lw = textWidth(s)
            let y = h - Self.pad - (i + 1) * Self.lineH + 4
            ctx.textPosition = CGPoint(x: (w - lw) / 2, y: y)
            CTLineDraw(line, ctx)
        }
        // Text box: sunken, a shade line on top.
        if inputRect != .zero {
            let x = Int(inputRect.minX), y = Int(inputRect.minY), rw = Int(inputRect.width), rh = Int(inputRect.height)
            rect(x, y, rw, rh, ink)
            rect(x + 1, y + 1, rw - 2, rh - 2, paper)
            rect(x + 1, y + rh - 2, rw - 2, 1, shade)
        }
        // Buttons.
        for (i, r) in buttonRects.enumerated() {
            let fill = hover == i ? CGColor(red: 0.80, green: 0.80, blue: 0.84, alpha: 1) : CGColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1)
            let x = Int(r.minX), y = Int(r.minY), rw = Int(r.width), rh = Int(r.height)
            rect(x + 1, y, rw - 2, rh, fill); rect(x, y + 1, rw, rh - 2, fill)
            rect(x + 1, y, rw - 2, 1, ink); rect(x + 1, y + rh - 1, rw - 2, 1, ink)
            rect(x, y + 1, 1, rh - 2, ink); rect(x + rw - 1, y + 1, 1, rh - 2, ink)
            let attr = NSAttributedString(string: buttonTitles[i], attributes: [.font: font, .foregroundColor: NSColor(cgColor: ink)!])
            ctx.textPosition = CGPoint(x: x + 5, y: y + 3)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.contents = ctx.makeImage()
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    override func layout() { super.layout(); imageLayer.frame = bounds }

    /// A small pixel name tag (white pill, ink outline, pixel font), one bitmap pixel per art pixel.
    static func tag(_ text: String, fill: (CGFloat, CGFloat, CGFloat) = (1, 1, 1)) -> CGImage? {
        let font = CTFontCreateWithName(BubbleWindow.fontName as CFString, 12, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let tw = Int(ceil(CTLineGetTypographicBounds(line, nil, nil, nil)))
        let w = tw + 8, h = 15
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(false); ctx.setAllowsAntialiasing(false); ctx.setShouldSmoothFonts(false)
        let ink = CGColor(red: CGFloat(Self.ink.r) / 255, green: CGFloat(Self.ink.g) / 255, blue: CGFloat(Self.ink.b) / 255, alpha: 1)
        func rect(_ x: Int, _ y: Int, _ rw: Int, _ rh: Int, _ c: CGColor) { ctx.setFillColor(c); ctx.fill(CGRect(x: x, y: y, width: rw, height: rh)) }
        let paper = CGColor(red: fill.0, green: fill.1, blue: fill.2, alpha: 1)
        rect(1, 0, w - 2, h, ink); rect(0, 1, w, h - 2, ink)
        rect(1, 1, w - 2, h - 2, paper)
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: ink)!])
        ctx.textPosition = CGPoint(x: 4, y: 4)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        return ctx.makeImage()
    }

    override func updateTrackingAreas() {
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }

    private func buttonAt(_ event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        let ap = CGPoint(x: p.x / pixel, y: p.y / pixel)
        return buttonRects.firstIndex { $0.insetBy(dx: -1, dy: -1).contains(ap) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseMoved(with event: NSEvent) { hover = buttonAt(event) }
    override func mouseExited(with event: NSEvent) { hover = nil }
    override func mouseUp(with event: NSEvent) { if let i = buttonAt(event) { onButton?(i) } }
}
