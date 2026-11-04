import AppKit

/// Little pixel particles that float up around the cat: pink hearts after a treat, "Z"s when drowsy.
/// They live in a click-through window over the cat's screen and are animated from the 60 Hz tick.
final class Effects {
    enum Kind { case heart, zzz, star }

    private struct Particle {
        let layer: CALayer
        let start: CGPoint          // screen points
        let drift: CGVector         // points per second
        let sway: CGFloat           // sideways wobble amplitude
        let phase: Double
        let born: Date
        let life: Double
        let kind: Kind
        let size: CGSize
    }

    private let window = PetWindow(size: CGSize(width: 10, height: 10))
    private let root = NSView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    private var particles: [Particle] = []
    private var zCount = 0

    init() {
        root.wantsLayer = true
        root.layer?.backgroundColor = .clear
        window.contentView = root
        window.ignoresMouseEvents = true
    }

    var isEmpty: Bool { particles.isEmpty }
    var count: Int { particles.count }

    /// Little stars circling the head (dizzy). `center` is in screen points; they run for `duration`.
    func orbit(center: CGPoint, radius: CGSize, count: Int, duration: Double, pixel: CGFloat, level: NSWindow.Level, screen: NSScreen) {
        prepare(level: level, screen: screen)
        for i in 0..<count {
            let art = i % 2 == 0 ? Self.star : Self.starSmall
            let size = CGSize(width: CGFloat(art.width) / 2 * pixel, height: CGFloat(art.height) / 2 * pixel)
            let layer = makeLayer(art, size)
            particles.append(Particle(layer: layer, start: center, drift: CGVector(dx: radius.width, dy: radius.height), sway: 0,
                                      phase: Double(i) / Double(count) * 2 * .pi, born: Date(), life: duration, kind: .star, size: size))
        }
        update()
    }

    private func prepare(level: NSWindow.Level, screen: NSScreen) {
        if !window.isVisible || window.frame != screen.frame {
            window.setFrame(screen.frame, display: false)
            root.frame = CGRect(origin: .zero, size: screen.frame.size)
        }
        window.level = level
        if !window.isVisible { window.orderFrontRegardless() }
    }

    private func makeLayer(_ art: CGImage, _ size: CGSize) -> CALayer {
        let layer = CALayer()
        layer.contents = art
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.opacity = 0
        root.layer?.addSublayer(layer)
        return layer
    }

    /// One particle at `point` (screen). `pixel` = points per sprite pixel, so it matches the cat.
    /// `outward` is +1 / -1: which way it drifts sideways.
    func spawn(_ kind: Kind, at point: CGPoint, pixel: CGFloat, outward: CGFloat, level: NSWindow.Level, screen: NSScreen) {
        prepare(level: level, screen: screen)
        zCount += kind == .zzz ? 1 : 0
        let big = kind == .zzz ? zCount % 3 != 1 : Bool.random()     // Z's: big, small, big ...
        let art: CGImage
        switch kind {
        case .heart: art = big ? Self.heart : Self.heartSmall
        case .zzz: art = big ? Self.zBig : Self.zSmall
        case .star: art = Self.star
        }
        let size = CGSize(width: CGFloat(art.width) / 2 * pixel, height: CGFloat(art.height) / 2 * pixel)
        let layer = makeLayer(art, size)

        let drift: CGVector, life: Double, sway: CGFloat
        switch kind {
        case .heart:
            drift = CGVector(dx: CGFloat.random(in: 2...14) * outward * pixel, dy: CGFloat.random(in: 26...40) * pixel)
            life = .random(in: 1.2...1.8); sway = CGFloat.random(in: 2...5) * pixel
        case .zzz, .star:
            drift = CGVector(dx: CGFloat.random(in: 6...12) * outward * pixel, dy: CGFloat.random(in: 12...18) * pixel)
            life = .random(in: 2.2...3.0); sway = CGFloat.random(in: 1.5...3) * pixel
        }
        particles.append(Particle(layer: layer, start: point, drift: drift, sway: sway, phase: .random(in: 0...(2 * .pi)),
                                  born: Date(), life: life, kind: kind, size: size))
        update()
    }

    func update() {
        guard !particles.isEmpty else { return }
        let now = Date()
        let origin = window.frame.origin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        particles.removeAll { p in
            let t = now.timeIntervalSince(p.born)
            if t >= p.life { p.layer.removeFromSuperlayer(); return true }
            let u = t / p.life
            if p.kind == .star {                 // circling: bigger and brighter in front, smaller behind
                let ang = p.phase + t * 2 * .pi * 0.9
                let depth = CGFloat(sin(ang))
                let x = p.start.x + p.drift.dx * CGFloat(cos(ang)) - origin.x
                let y = p.start.y - p.drift.dy * depth - origin.y
                let fade = min(1, t / 0.25, (p.life - t) / 0.4)
                p.layer.position = CGPoint(x: x.rounded(), y: y.rounded())
                let s = 0.8 + 0.25 * depth
                p.layer.setAffineTransform(CGAffineTransform(scaleX: s, y: s))
                p.layer.opacity = Float(fade * (0.7 + 0.3 * Double(depth)))
                return false
            }
            let wobble = p.sway * CGFloat(sin(t * (p.kind == .heart ? 7 : 3.5) + p.phase))
            let x = p.start.x + p.drift.dx * CGFloat(t) + wobble - origin.x
            let y = p.start.y + p.drift.dy * CGFloat(t) - origin.y
            // Pop in (hearts with a little overshoot), grow slowly, fade out over the last part.
            let s: Double
            switch p.kind {
            case .heart: s = t < 0.12 ? 0.4 + 0.8 * t / 0.12 : (t < 0.24 ? 1.2 - 0.2 * (t - 0.12) / 0.12 : 1.0)
            case .zzz, .star: s = 0.6 + 0.6 * u
            }
            let a = t < 0.15 ? t / 0.15 : (u > 0.6 ? (1 - u) / 0.4 : 1)
            p.layer.position = CGPoint(x: x.rounded(), y: y.rounded())
            p.layer.setAffineTransform(CGAffineTransform(scaleX: CGFloat(s), y: CGFloat(s)))
            p.layer.opacity = Float(a)
            return false
        }
        CATransaction.commit()
        if particles.isEmpty { window.orderOut(nil) }
    }

    func clear() {
        particles.forEach { $0.layer.removeFromSuperlayer() }
        particles.removeAll()
        window.orderOut(nil)
    }

    // MARK: pixel art (drawn as text so it is easy to tweak)

    private static let palette: [Character: (UInt8, UInt8, UInt8)] = [
        "o": (178, 62, 112),     // heart outline
        "p": (255, 128, 172),    // pink
        "d": (228, 92, 142),     // pink shade
        "l": (255, 192, 216),    // light pink
        "h": (255, 255, 255),    // shine
        "k": (66, 72, 108),      // Z outline
        "w": (234, 238, 255),    // Z fill
        "s": (176, 112, 28),     // star outline
        "y": (255, 212, 84),     // star
        "Y": (255, 240, 160),    // star light
    ]

    private static let heart = art([
        ".ooo...ooo.",
        "ohlpo.opppo",
        "olpppoppppo",
        "opppppppppo",
        "opppppppppo",
        ".oppppppdo.",
        "..oppppdo..",
        "...oppdo...",
        "....odo....",
        ".....o.....",
    ])
    private static let heartSmall = art([
        ".oo.oo.",
        "ohpoppo",
        "opppppo",
        ".opppo.",
        "..odo..",
        "...o...",
    ])
    private static let star = art([
        "....s....",
        "...sYs...",
        "sssyYysss",
        "sYyyhyyys",
        ".syyyyys.",
        "..syyys..",
        ".syysyys.",
        ".sys.sys.",
        ".ss...ss.",
    ])
    private static let starSmall = art([
        "...s...",
        "..sYs..",
        "sssyyss",
        "sYyhyys",
        "ssyyyss",
        "..sys..",
        "...s...",
    ])
    private static let zBig = art([
        "kkkkkkkk",
        "kwwwwwwk",
        "kkkkkwwk",
        "...kwwk.",
        "..kwwk..",
        ".kwwkkkk",
        "kwwwwwwk",
        "kkkkkkkk",
    ])
    private static let zSmall = art([
        "kkkkkk",
        "kwwwwk",
        "kkkwwk",
        ".kwwk.",
        "kwwkkk",
        "kwwwwk",
        "kkkkkk",
    ])

    /// Builds the sprite and runs it through the same 2x soft edge as the cat (so it is twice the size).
    private static func art(_ rows: [String]) -> CGImage {
        let h = rows.count, w = rows[0].count
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                guard let c = palette[ch] else { continue }
                let i = (y * w + x) * 4
                px[i] = c.0; px[i + 1] = c.1; px[i + 2] = c.2; px[i + 3] = 255
            }
        }
        let image = px.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        return Frame(image: image).image(night: false)
    }
}
