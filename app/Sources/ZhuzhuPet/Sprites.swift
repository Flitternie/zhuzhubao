import AppKit

/// One sprite frame: the pixel art, its alpha mask for hit testing, and display images that are
/// drawn at 2x with a soft one-step edge so the silhouette looks smooth on light backgrounds too.
final class Frame {
    let image: CGImage
    let width: Int
    let height: Int
    private let alpha: [UInt8]
    private let rgba: [UInt8]          // premultiplied, 1x

    init(image: CGImage) {
        let w = image.width, h = image.height
        self.image = image
        width = w
        height = h
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        rgba = buf
        // If the mask cannot be built, treat the whole frame as clickable.
        alpha = drawn ? stride(from: 3, to: buf.count, by: 4).map { buf[$0] }
                      : [UInt8](repeating: 255, count: w * h)
    }

    private lazy var dayImage: CGImage = Frame.smooth(rgba, width, height) ?? image
    /// Columns left of this stay as drawn at night (the drinking clip's bowl: its water is blue too).
    var nightSkipBelowX = 0
    private lazy var nightImage: CGImage = Frame.smooth(Frame.nightPixels(rgba, width: width, skipBelowX: nightSkipBelowX), width, height) ?? image
    var night: CGImage { nightImage }

    func image(night isNight: Bool) -> CGImage { isNight ? nightImage : dayImage }

    /// At night the pupils open wide: blue iris pixels become a deep blue-black.
    private static func nightPixels(_ src: [UInt8], width: Int, skipBelowX: Int) -> [UInt8] {
        var px = src
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 0 && (i / 4) % width >= skipBelowX {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            if b > r + 40 && b > 100 && g < 200 {
                let k = min(1.0, Double(b) / 255.0)
                px[i] = UInt8(18 + 14 * k); px[i + 1] = UInt8(20 + 16 * k); px[i + 2] = UInt8(30 + 30 * k)
            }
        }
        return px
    }

    /// 2x upscale where only the outline gets a half-step of transparency: inner edge pixels become
    /// slightly see-through and the pixels just outside get a faint fringe in the outline's colour.
    /// The inside of the sprite stays crisp.
    private static func smooth(_ src: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        let W = w * 2, H = h * 2
        var a2 = [Int](repeating: 0, count: W * H)
        for y in 0..<H { for x in 0..<W { a2[y * W + x] = Int(src[((y / 2) * w + x / 2) * 4 + 3]) } }
        var out = [UInt8](repeating: 0, count: W * H * 4)
        for y in 0..<H {
            for x in 0..<W {
                let i = y * W + x
                var sum = 0, best = -1, bestA = 0
                for dy in -1...1 {
                    let yy = y + dy
                    guard yy >= 0 && yy < H else { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        guard xx >= 0 && xx < W else { continue }
                        let a = a2[yy * W + xx]
                        sum += a
                        if a > bestA { bestA = a; best = yy * W + xx }
                    }
                }
                let own = a2[i]
                let af = (own + sum / 9) / 2                     // half way between crisp and blurred
                if af == 0 { continue }
                // Colour: the pixel's own (straight) colour, or its most opaque neighbour's just outside.
                let srcIndex = own > 0 ? i : best
                guard srcIndex >= 0 else { continue }
                let sy = srcIndex / W / 2, sx = (srcIndex % W) / 2
                let si = (sy * w + sx) * 4
                let sa = max(1, Int(src[si + 3]))
                for c in 0..<3 {
                    let straight = min(255, Int(src[si + c]) * 255 / sa)
                    out[i * 4 + c] = UInt8(straight * af / 255)
                }
                out[i * 4 + 3] = UInt8(af)
            }
        }
        return out.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    /// First row (from the top) with an opaque pixel: where the cat's head or ears start.
    var topRow: Int {
        for y in 0..<height where (0..<width).contains(where: { alpha[y * width + $0] > 40 }) { return y }
        return 0
    }
    /// Horizontal span of opaque pixels within the top `rows` rows (the head).
    func headSpan(rows: Int = 30) -> (Int, Int) {
        let t = topRow
        var lo = width, hi = 0
        for y in t..<min(height, t + rows) { for x in 0..<width where alpha[y * width + x] > 40 { lo = min(lo, x); hi = max(hi, x) } }
        return lo <= hi ? (lo, hi) : (0, width - 1)
    }

    /// `x`, `y` in sprite pixels with the origin at the top-left.
    func isOpaque(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        // Bitmap context memory starts with the top row of the drawn image.
        return alpha[y * width + x] > 40
    }
}

enum BowlLevel: String, CaseIterable { case full, half, empty }

enum Face: String, CaseIterable {
    case neutral, slit, closed, happy, wide, daylight, lick, meow
}

final class SpriteSet {
    let walk: [Frame]
    let sit: [Face: Frame]
    let standUp: [Frame]
    let sitDown: [Frame]
    let groom: [Frame]
    let drink: [Frame]          // 176-px wide canvas, bowl on the left, cat on the right
    let bowl: [BowlLevel: Frame]
    let lift: [Frame]           // picked up by the scruff; last frames hang
    let lie: [Frame]            // sit -> lying on the chest, head up (160 wide)
    let doze: [Frame]           // lying -> chin down, stretched out asleep (160 wide)
    let loaf: [Face: Frame]     // lying with head up: neutral, slit (drowsy), closed
    let stretch: [Frame]
    let yawn: [Frame]
    let head: CGImage
    let look: [String: Frame]
    let tail: [Frame]           // sitting, tail swish (body identical to sit-neutral)
    let eat: [Frame]            // 176 wide: shrimp on the left, cat walks up, eats it
    let shrimp: Frame
    let pounce: [Frame]
    let crouch: [Frame]
    let rub: [Frame]
    let shake: [Frame]
    let ui: [String: CGImage]   // 16 px action-bar icons
    let jump: [Frame]           // crouch, crouch, reach up, reach up, falling, landed
    let headPose: [String: Frame]
    let perchFaces: [Face: [Frame]]
    let climbLaunch: [Frame]    // 128 x 192: push off, body stretched up (paws top at row 26)
    let climbUp: [Frame]        // 128 x 256: hang from the edge (row 122), scramble, pull up, stand
    let loafTail: [Face: [Frame]]   // lying with the head up, the tail swishing along the ground (160 x 176, feet at 128)
    let wallUp: [Frame]         // 128 x 192 (feet at the bottom): rear up against a wall on the left, paws up, stretch
    let wallScratch: [Frame]    // same canvas: scratching the wall
    let perch: [Frame]          // lying on a window's top edge, tail hanging over (160 x 176, feet at the 128 line)
    let run: [Frame]            // 160 wide, gallop loop facing left (extra width in front), for zoomies
    let curl: [Frame]           // 160 wide: lying -> curled up in a ball, tail round the nose, asleep
    let lieClips: [String: [Frame]] // 160 wide, start in the lying pose: knead, liegroom, belly
    let clips: [String: [Frame]]    // short idle clips that start and end in the sitting pose   // sitting, head turned: l1..l3, r1..r3 (sprite left/right), u1, u2   // sitting, pupils turned toward a direction: c, l, r, u, d, ul, ur, dl, dr

    init() {
        walk = SpriteSet.sequence("walk/walk")
        standUp = SpriteSet.sequence("trans/up")
        sitDown = SpriteSet.sequence("trans/down")
        groom = SpriteSet.sequence("groom/groom")
        drink = SpriteSet.sequence("drink/drink")
        for f in drink { f.nightSkipBelowX = 44 }      // bowl is x 4..<44; the cat starts at 44
        lift = SpriteSet.sequence("lift/lift")
        lie = SpriteSet.sequence("lie/lie")
        doze = SpriteSet.sequence("doze/doze")
        var loafFaces: [Face: Frame] = [:]
        for face in [Face.neutral, .slit, .closed] { loafFaces[face] = SpriteSet.tryLoad("loaf/loaf-\(face.rawValue)") }
        loaf = loafFaces
        stretch = SpriteSet.sequence("stretch/stretch")
        yawn = SpriteSet.sequence("yawn/yawn")
        var faces: [Face: Frame] = [:]
        for face in Face.allCases { faces[face] = SpriteSet.load("sit/sit-\(face.rawValue)") }
        sit = faces
        var bowls: [BowlLevel: Frame] = [:]
        for level in BowlLevel.allCases { bowls[level] = SpriteSet.load("bowl/bowl-\(level.rawValue)") }
        bowl = bowls
        head = SpriteSet.load("icon/head").image
        var lk: [String: Frame] = [:]
        for d in ["c", "l", "r", "u", "d", "ul", "ur", "dl", "dr"] { lk[d] = SpriteSet.tryLoad("look/sit-\(d)") }
        look = lk
        tail = SpriteSet.sequence("tail/tail")
        eat = SpriteSet.sequence("eat/eat")
        shrimp = SpriteSet.load("shrimp/shrimp-1")
        pounce = SpriteSet.sequence("pounce/pounce")
        crouch = SpriteSet.sequence("crouch/crouch")
        rub = SpriteSet.sequence("rub/rub")
        shake = SpriteSet.sequence("shake/shake")
        jump = SpriteSet.sequence("jump/jump")
        var lt: [Face: [Frame]] = [:]
        for face in [Face.neutral, .slit, .closed] { let f = SpriteSet.sequence("loaftail/tail-\(face.rawValue)"); if !f.isEmpty { lt[face] = f } }
        loafTail = lt
        run = SpriteSet.sequence("run/run")
        curl = SpriteSet.sequence("curl/curl")
        var lc: [String: [Frame]] = [:]
        for n in ["knead", "liegroom", "belly"] { let f = SpriteSet.sequence("\(n)/\(n)"); if !f.isEmpty { lc[n] = f } }
        lieClips = lc
        wallUp = SpriteSet.sequence("wall/up")
        wallScratch = SpriteSet.sequence("wall/scratch")
        perch = SpriteSet.sequence("perch/perch")
        climbLaunch = SpriteSet.sequence("climb/launch")
        climbUp = SpriteSet.sequence("climb/up")
        perchFaces = [.neutral: perch, .slit: SpriteSet.sequence("perch/slit"), .closed: SpriteSet.sequence("perch/closed")]
        var hp: [String: Frame] = [:]
        for n in ["l1", "l2", "l3", "r1", "r2", "r3", "u1", "u2", "ur1", "ul1", "dr1", "dl1", "d1"] { hp[n] = SpriteSet.tryLoad("head/\(n)") }
        headPose = hp
        var cl: [String: [Frame]] = [:]
        for n in ["scratch", "sneeze", "swat", "ear", "headshake"] { let f = SpriteSet.sequence("\(n)/\(n)"); if !f.isEmpty { cl[n] = f } }
        clips = cl
        var icons: [String: CGImage] = [:]
        for n in ["shrimp", "toy", "water", "gear", "close", "pin", "pin-off"] { icons[n] = SpriteSet.tryLoad("ui/\(n)")?.image }
        ui = icons
    }

    /// Loads name-1.png, name-2.png, ... until the next file is missing.
    private static func sequence(_ name: String) -> [Frame] {
        var frames: [Frame] = []
        while let f = tryLoad("\(name)-\(frames.count + 1)") { frames.append(f) }
        return frames
    }

    static func tryLoad(_ name: String) -> Frame? {
        guard let base = Bundle.main.resourceURL,
              case let url = base.appendingPathComponent("sprites/\(name).png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return Frame(image: image)
    }

    private static func load(_ name: String) -> Frame {
        guard let f = tryLoad(name) else { fatalError("Missing sprite \(name)") }
        return f
    }
}
