import AppKit

/// A borderless, transparent panel that never takes focus and floats above normal windows.
final class PetWindow: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws the current frame with nearest-neighbour scaling and forwards mouse events.
final class PetView: NSView {
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?
    var onRightMouseDown: ((NSEvent) -> Void)?
    private let spriteLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.minificationFilter = .nearest
        spriteLayer.contentsGravity = .resize
        layer?.addSublayer(spriteLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Clip the sprite to the view (used while peeking from behind the screen edge).
    var clips: Bool {
        get { layer?.masksToBounds ?? false }
        set { layer?.masksToBounds = newValue }
    }

    /// Simple form: the sprite fills the view.
    func show(_ frame: Frame, mirrored: Bool, night: Bool = false) {
        show(image: frame.image(night: night), size: bounds.size, anchor: CGPoint(x: 0.5, y: 0.5),
             at: CGPoint(x: bounds.midX, y: bounds.midY), mirrored: mirrored)
    }

    /// Full form: `anchor` is normalized in the sprite (y up), placed at `at` in view points;
    /// rotation (radians) and stretch happen around that anchor.
    func show(image: CGImage, size: CGSize, anchor: CGPoint, at point: CGPoint, mirrored: Bool,
              rotation: CGFloat = 0, scaleX: CGFloat = 1, scaleY: CGFloat = 1) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.contents = image
        spriteLayer.bounds = CGRect(origin: .zero, size: size)
        spriteLayer.anchorPoint = anchor
        spriteLayer.position = point
        var t = CGAffineTransform(rotationAngle: rotation).scaledBy(x: scaleX * (mirrored ? -1 : 1), y: scaleY)
        if !t.isIdentity && t.a == 1 && t.d == 1 { t = .identity }
        spriteLayer.setAffineTransform(t)
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(event) }
    override func rightMouseDown(with event: NSEvent) { onRightMouseDown?(event) }
}
