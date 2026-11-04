import AppKit

/// Behaviour: mostly sits and makes faces; sometimes grooms, yawns, walks or naps; sleeps at night
/// and while you are away; drinks from its bowl as a water reminder; stretches as a sit-too-long
/// reminder; can be picked up by the scruff, swung and thrown.
final class PetController {
    enum After { case sit, drink, stretch, play, eat, announce, zoom, nap, leap, rest, wall }
    enum State {
        case sitting(until: Date)
        case standingUp(Int, targetX: CGFloat, then: After)
        case walking(targetX: CGFloat, then: After)
        case sittingDown(Int, sitFor: TimeInterval)
        case grooming(Int)
        case yawning(Int, thenSleep: Bool)
        case drinking(Int)
        case stretching(Int)
        case lyingDown(Int)
        case loafing(until: Date)
        case dozing(Int)
        case sleeping
        case wakingUp(Int)
        case held(since: Date)
        case flying
        case landing(Int)
        case tailFlick(Int)
        case petted(since: Date)
        case crouching(Int)
        case pouncing(Int, fromX: CGFloat, toX: CGFloat)
        case eating(Int)
        case shaking(Int)
        case jumping(tick: Int, vy: CGFloat, y: CGFloat, caught: Bool)
        case clip(String, Int)
        case dizzy(until: Date)
        case leaping(tick: Int, from: CGPoint, to: CGPoint, ticks: Int, up: Bool)   // onto / off a window's top edge
        case perchLying(until: Date)                    // lying on a window's top edge, tail hanging down
        case climbing(tick: Int, x: CGFloat, top: CGFloat)     // a high ledge: spring up, hook the paws over, scramble up
        case peeking(side: CGFloat, y: CGFloat, until: Date)   // hiding behind the left (-1) / right (+1) screen edge
        case wallScratch(Int)                           // at a screen edge: up on the hind legs, paws on the edge, stretch and scratch
    }
    /// The top edge of another app's window the cat is standing on (screen points, Cocoa coordinates).
    struct Perch { let id: CGWindowID; var top: CGFloat; var minX: CGFloat; var maxX: CGFloat; var windowFrame: CGRect }

    static let canvas: CGFloat = 128            // standard sprite canvas in pixels
    /// On a window edge the canvas bottom sits this many sprite pixels below the edge, so the feet
    /// (row ~122) press a few pixels onto the window instead of leaving a gap.
    static let perchSink: CGFloat = 10
    static let tick: TimeInterval = 0.11        // frame time
    static let stepPixels: CGFloat = 3.33       // ground speed per walk frame, matches the stride
    // Drink canvas layout (pixels): bowl at x 4..44, cat canvas starts at x 44.
    static let drinkCanvas: CGFloat = 176
    static let drinkCatOffset: CGFloat = 44
    static let drinkBowlX: CGFloat = 4
    static let bowlWidth: CGFloat = 40
    static let drinkApproachShift: CGFloat = -11   // the cat steps toward the bowl inside the clip
    // Frame orders (each index is one tick). Lapping uses only the two steadiest frames, held two ticks each.
    static let drinkSequence: [Int] = [0, 1, 2, 3, 3] + Array(repeating: [3, 3, 4, 4], count: 8).flatMap { $0 } + [3, 3, 2, 2]
    /// Builds a frame order from segments: each frame index held `hold` ticks, segments repeated.
    static func seq(_ parts: [([Int], Int, Int)]) -> [Int] {
        parts.flatMap { frames, hold, times in Array(repeating: frames.flatMap { Array(repeating: $0, count: hold) }, count: times).flatMap { $0 } }
    }
    static func slow(_ n: Int, _ hold: Int) -> [Int] { (0..<n).flatMap { Array(repeating: $0, count: hold) } }
    // Picked up by the scruff: frames of `lift` and the scruff point (sprite pixels, top-left origin).
    static let liftSurprised = 4, liftRelaxed = 5, liftWiggle = [3, 4, 5, 4]
    static let scruff = CGPoint(x: 74, y: 16)
    static let heldPad: CGFloat = 70            // room around the sprite for swinging while held

    let window: PetWindow
    let view: PetView
    let bowlWindow: PetWindow
    let bowlView: PetView
    let bubble = BubbleWindow()
    let actionBar = ActionBar()
    private var pendingAlert: CalendarWatcher.Alert?
    var openSettings: (() -> Void)?
    let sprites = SpriteSet()
    var onChange: (() -> Void)?

    var scale: CGFloat { didSet { layoutBowl(); render() } }
    /// true: float above all windows; false: stay on the desktop, behind every app window.
    var onTop: Bool { didSet { applyLevel() } }
    var paused = false { didSet { if paused { stopWalking(sitFor: .infinity) } else { sit(for: 2) } } }

    // Water reminder.
    var drinkInterval: TimeInterval {     // 0 = off
        didSet { UserDefaults.standard.set(drinkInterval, forKey: "drinkInterval"); restartReminder() }
    }
    private(set) var lastRefill: Date
    private var reminded = 0               // reminders shown in the current cycle
    /// false: the bowl only shows up when it is time to drink and leaves once you have drunk.
    /// The bowl only shows while the cat is thirsty or drinking (there used to be an "always" option).
    let bowlAlwaysVisible = false
    private var bowlNeeded = false         // a drink is pending: keep the bowl out
    /// Drinking is a little two-way deal: when its bowl is empty the cat asks you to drink a glass first;
    /// only then do you get to fill its bowl, and it drinks with you.
    private var waitingForWater = false    // sitting by its empty bowl, asking
    private var waterReady = false         // the bowl was just filled: walk over and drink
    private var thirstyAsks = 0            // asked (and put off) since the last cup: lines get more pitiful
    private var thirstyToken = 0
    private var bowlFill: BowlLevel?       // overrides the time-based level while it is being filled
    private var bowlShown: Bool { bowlAlwaysVisible || bowlNeeded }
    private var nextReminder = Date.distantFuture
    var cupsToday: Int {
        UserDefaults.standard.string(forKey: "cupsDay") == Self.today ? UserDefaults.standard.integer(forKey: "cups") : 0
    }

    // Sit-too-long reminder: continuous computer use (no break of 5+ minutes).
    var standInterval: TimeInterval {      // 0 = off
        didSet { UserDefaults.standard.set(standInterval, forKey: "standInterval"); activeSince = Date() }
    }
    private var activeSince = Date()
    private var standReminded = false

    private var state: State = .sitting(until: Date().addingTimeInterval(20))
    private var catX: CGFloat = 0          // left edge of the 128-px cat canvas, in screen points
    private var bowlX: CGFloat = 0         // left edge of the bowl, in screen points
    private var walkIndex = 0
    private var facingRight = false
    private var face: Face = .neutral
    private var faceQueue: [(Face, TimeInterval)] = []
    private var faceUntil = Date()
    private var nextIdleMove = Date().addingTimeInterval(4)
    private var wokenAt = Date.distantPast // a click wakes the cat for a while
    private var timers: [Timer] = []

    // Mouse and physics.
    private var pressPoint = CGPoint.zero
    private var dragMoved = false
    private var cursorOverCat = false
    // Petting, play and feeding.
    private var sitUntil = Date()
    private var petFrameTick = 0
    private var petMeter: CGFloat = 0
    private var petSessions: [Date] = []       // recent petting spells; too many and it walks off
    private var lastPetSession = Date.distantPast
    private var napAfterSit = false
    // Window ledges.
    var perch: Perch?
    private var pendingPerch: Perch?
    private var pendingLandX: CGFloat = 0
    private var leapPos = CGPoint.zero
    private var afterLanding: (() -> Void)?
    private var perchTick = 0
    /// Lying with the head up: a tail swish along the ground is playing (tick into `loafTailSequence`).
    private var loafTailTick: Int?
    private var nextLoafTail = Date.distantPast
    /// On a window edge: the tail hangs over (true) or lies along the edge and swishes now and then.
    private var perchTailDown = true
    private var lastPerchCheck = Date.distantPast
    private var flyLedges: [Perch] = []
    private var restAfterSit = false
    // Peeking from behind a screen edge: how far out (0.15 = just an ear, 1 = half the face) and where it is heading.
    private var peekOut: CGFloat = 0
    private var peekTarget: CGFloat = 1
    private var peekNextChange = Date()
    private var cursorNearPeekSince: Date?
    private var napUntil = Date.distantPast     // after walking off in a huff it sleeps a good while
    private var moveAwayAfterWake = false
    private var sleepPetUntil = Date.distantPast
    private var lastPetMove = Date.distantPast
    private var lastPetPoint: CGPoint?
    private var playLastMove = Date()
    private var playLastPoint = CGPoint.zero
    let toyWindow = PetWindow(size: CGSize(width: 12, height: 12))
    let toyView = PetView(frame: CGRect(x: 0, y: 0, width: 12, height: 12))
    let shrimpWindow = PetWindow(size: CGSize(width: 26, height: 19))
    let shrimpView = PetView(frame: CGRect(x: 0, y: 0, width: 26, height: 19))
    var shrimpX: CGFloat = 0
    private var shrimpY: CGFloat = 0
    private var shrimpVY: CGFloat = 0
    private var shrimpFalling = false
    private var shrimpHeld = false          // following the cursor until the user clicks to drop it
    private var shrimpHeldSince = Date()
    private(set) var shrimpOnFloor = false
    var playMode = false { didSet { playModeChanged() } }
    // Floating hearts / Z's.
    let effects = Effects()
    private var heartsUntil = Date.distantPast
    private var nextParticle = Date.distantPast
    // Eyes follow the cursor while it moves.
    private var lastCursor = CGPoint.zero
    private var cursorMovedAt = Date.distantPast
    private var lookTarget = ""
    private var glance: (pose: String, until: Date)?
    private var restOnly = false
    // Red-dot boredom: where the last pounce/jump went, and whether we already walked away from it.
    private var strikePoint: CGPoint?
    private var walkedAwayFromStrike = false
    private var playMonitors: [Any] = []
    private var lookPose = ""
    // Swinging the cursor back and forth in front of it: it follows with its head until it gets dizzy.
    private var swingDir: CGFloat = 0
    private var swingExtreme: CGFloat = 0
    private var swingFlips: [Date] = []
    private var lookRestUntil = Date.distantPast
    static let eyeMid = CGPoint(x: 33.5, y: 39.7)      // between the eyes in the sitting sprite (pixels, top-left origin)
    private var grip = CGPoint.zero        // where the scruff is, in screen points
    private var samples: [(CGPoint, TimeInterval)] = []
    private var angle: CGFloat = 0, angularVelocity: CGFloat = 0
    private var stretchY: CGFloat = 1
    private var velocity = CGVector.zero   // while flying, points per second
    private var flyPos = CGPoint.zero      // while flying: bottom-left of the 128 canvas
    private var squash: CGFloat = 1        // landing squash (scaleY)
    private var lastPhysics = Date()
    private var bowlDragOffset: CGFloat = 0
    private var bowlDragMoved = false
    /// Test hook: a scripted cursor instead of the real one.
    var cursorOverride: CGPoint?
    private var mouse: CGPoint { cursorOverride ?? NSEvent.mouseLocation }

    init(scale: CGFloat, onTop: Bool) {
        self.scale = scale
        self.onTop = onTop
        let d = UserDefaults.standard
        drinkInterval = d.object(forKey: "drinkInterval") as? TimeInterval ?? 45 * 60
        standInterval = d.object(forKey: "standInterval") as? TimeInterval ?? 50 * 60
        lastRefill = (d.object(forKey: "lastRefill") as? Date) ?? Date()
        window = PetWindow(size: CGSize(width: 128, height: 128))
        view = PetView(frame: CGRect(x: 0, y: 0, width: 128, height: 128))
        window.contentView = view
        bowlWindow = PetWindow(size: CGSize(width: 40, height: 20))
        bowlView = PetView(frame: CGRect(x: 0, y: 0, width: 40, height: 20))
        bowlWindow.contentView = bowlView
        // The toy dot and the shrimp each get their own little window.
        toyWindow.contentView = toyView
        shrimpWindow.contentView = shrimpView
        for w in [toyWindow, shrimpWindow] { w.ignoresMouseEvents = true }
        view.onMouseDown = { [weak self] in self?.mouseDown($0) }
        view.onMouseDragged = { [weak self] in self?.mouseDragged($0) }
        view.onMouseUp = { [weak self] in self?.mouseUp($0) }
        view.onRightMouseDown = { [weak self] _ in self?.showActionBar() }
        bowlView.onMouseDown = { [weak self] in self?.bowlMouseDown($0) }
        bowlView.onMouseDragged = { [weak self] in self?.bowlMouseDragged($0) }
        bowlView.onMouseUp = { [weak self] in self?.bowlMouseUp($0) }
        applyLevel()
    }

    func start() {
        let away = affection.checkIn()
        if away >= 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.showBubble(["好想你啊～", "你终于来啦！好想你", "这几天去哪儿啦？想你了"].randomElement()!, seconds: 3)
                self?.heartsUntil = Date().addingTimeInterval(1.6)
            }
        }
        let vf = currentScreen.visibleFrame
        catX = vf.midX - Self.canvas * scale / 2
        let savedBowl = UserDefaults.standard.double(forKey: "bowlX")
        bowlX = savedBowl > 0 ? CGFloat(savedBowl) : vf.minX + 160
        layoutBowl()
        window.orderFrontRegardless()
        scheduleReminder()
        render()
        timers.append(Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in self?.step() })
        // Mouse pass-through and the held/flying physics run at 60 Hz.
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.fastTick() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.renderBowl() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.checkActivity() })
    }

    // MARK: geometry and environment

    private var currentScreen: NSScreen { window.screen ?? NSScreen.main ?? NSScreen.screens[0] }
    private var floorY: CGFloat { currentScreen.visibleFrame.minY - 4 * scale }      // canvases have empty rows under the paws
    /// On a window it sits 3 px lower, so its belly presses onto the edge rather than hovering above it.
    private var groundY: CGFloat { perch.map { $0.top - Self.perchSink * scale } ?? floorY }
    private var levelValue: NSWindow.Level {
        onTop ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }
    private var hour: Int { Calendar.current.component(.hour, from: Date()) }
    /// Dark, dilated eyes in the evening and at night.
    enum EyeMode: String { case auto, day, night }
    /// Always automatic now (blue by day, dark from 19:00); the menu option was removed.
    var eyeMode: EyeMode = .auto {
        didSet { render() }
    }
    private var isNight: Bool {
        switch eyeMode { case .day: return false; case .night: return true; case .auto: return hour >= 19 || hour < 7 }
    }
    /// Bedtime: the cat sleeps unless you wake it.
    private var isBedtime: Bool { hour >= 23 || hour < 7 }
    /// Seconds since the last keyboard or mouse input anywhere.
    private var userIdle: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func applyLevel() {
        window.level = levelValue
        bowlWindow.level = levelValue
        shrimpWindow.level = levelValue
        window.orderFrontRegardless()
    }

    private var isRunning: Bool {
        if case .walking(_, let then) = state, then == .zoom, !sprites.run.isEmpty { return true } else { return false }
    }
    private var isDrinking: Bool { if case .drinking = state { return true } else { return false } }
    private var isEating: Bool { if case .eating = state { return true } else { return false } }
    private var isAirborne: Bool {
        switch state { case .held, .flying: return true; default: return false }
    }

    /// Origin of the wide drinking canvas so that its bowl sits exactly on the real bowl.
    private var drinkOriginX: CGFloat {
        facingRight ? bowlX - (Self.drinkCanvas - Self.drinkBowlX - Self.bowlWidth) * scale
                    : bowlX - Self.drinkBowlX * scale
    }

    /// Where the 128 canvas must stand to start the drinking clip.
    private var drinkStartCatX: CGFloat {
        facingRight ? drinkOriginX + (Self.drinkCanvas - Self.drinkCatOffset - Self.canvas) * scale
                    : drinkOriginX + Self.drinkCatOffset * scale
    }

    private func layoutBowl() {
        bowlWindow.setFrame(CGRect(x: bowlX, y: currentScreen.visibleFrame.minY + 1 * scale,
                                   width: Self.bowlWidth * scale, height: 20 * scale), display: false)
        bowlView.frame = CGRect(x: 0, y: 0, width: Self.bowlWidth * scale, height: 20 * scale)
        renderBowl()
    }

    // MARK: main loop (frame ticks)

    private func step() {
        let now = Date()
        if now >= nextReminder { remind() }
        switch state {
        case .walking(let targetX, let then):
            let dx = targetX - catX
            let hurry: CGFloat = then == .zoom ? 2.8 : ((then == .play || then == .eat) ? 1.8 : 1)
            if abs(dx) <= Self.stepPixels * scale * hurry {
                catX = targetX
                switch then {
                case .sit: stopWalking(sitFor: TimeInterval.random(in: 60...240))
                case .drink: facingRight = bowlX > catX; if waterReady { waterReady = false; state = .drinking(0) } else { arriveThirsty() }
                case .stretch: state = sprites.stretch.isEmpty ? .sittingDown(0, sitFor: 120) : .stretching(0)
                case .play: sit(for: 0.6)
                case .zoom: stopWalking(sitFor: TimeInterval.random(in: 40...120)); play([(.wide, 1.2), (.closed, 0.12)])
                case .nap: napAfterSit = true; stopWalking(sitFor: 1.2)
                case .leap: leapOntoPending()
                case .rest: restAfterSit = true; stopWalking(sitFor: 0.8)
                case .announce:
                    stopWalking(sitFor: 120)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.showPendingAlert() }
                case .eat: facingRight = shrimpX > catX; state = .eating(0)
                case .wall: facingRight = catX > currentScreen.visibleFrame.midX; state = .wallScratch(0)
                }
            } else {
                facingRight = dx > 0
                walkIndex = (walkIndex + 1) % sprites.walk.count
                runIndex += 1
                // Chasing the toy or going for a shrimp: hurry.
                let fast: CGFloat = then == .zoom ? 2.8 : ((then == .play || then == .eat) ? 1.8 : 1)
                let stepLen = min(abs(dx), Self.stepPixels * scale * fast)
                catX += (dx > 0 ? 1 : -1) * stepLen
            }
        case .sitting(let until):
            stepLook()
            updateFace(now)
            if now >= until && (napAfterSit || !paused) && !playMode { decideNext() }
        case .standingUp(let i, let targetX, let then):
            if i + 1 < sprites.standUp.count { state = .standingUp(i + 1, targetX: targetX, then: then) }
            else if then == .stretch { state = sprites.stretch.isEmpty ? .sittingDown(0, sitFor: 120) : .stretching(0) }
            else { state = .walking(targetX: targetX, then: then) }
        case .sittingDown(let i, let sitFor):
            if i + 1 < sprites.sitDown.count { state = .sittingDown(i + 1, sitFor: sitFor) } else { sit(for: sitFor) }
        case .grooming(let i):
            if i + 1 < groomSequence.count { state = .grooming(i + 1) } else { sit(for: TimeInterval.random(in: 60...180)) }
        case .yawning(let i, let thenSleep):
            if i + 1 < yawnSequence.count { state = .yawning(i + 1, thenSleep: thenSleep) }
            else if thenSleep { lieDown() } else { sit(for: TimeInterval.random(in: 30...120)) }
        case .drinking(let i):
            if i + 1 < Self.drinkSequence.count { state = .drinking(i + 1) } else { finishDrinking() }
        case .stretching(let i):
            if i + 1 < stretchSequence.count { state = .stretching(i + 1) } else { state = .sittingDown(0, sitFor: TimeInterval.random(in: 90...200)) }
        case .lyingDown(let i):
            if i + 1 < lieSequence.count { state = .lyingDown(i + 1) }
            else if perch != nil, !sprites.perch.isEmpty {
                state = .perchLying(until: Date().addingTimeInterval(.random(in: 40...120)))
                face = .neutral; perchTick = 0
                perchTailDown = sprites.loafTail.isEmpty || Bool.random()
                loafTailTick = nil; nextLoafTail = Date().addingTimeInterval(.random(in: 2...5))
                lieClip = nil; curledSleep = false; nextLieClip = Date().addingTimeInterval(.random(in: 8...25))
            } else {
                state = .loafing(until: Date().addingTimeInterval(isBedtime ? .random(in: 20...40) : .random(in: 40...100)))
                face = .neutral
                loafTailTick = nil; nextLoafTail = Date().addingTimeInterval(.random(in: 2...5))
                lieClip = nil; curledSleep = false; nextLieClip = Date().addingTimeInterval(.random(in: 6...20))
                if let p = pendingLieClip, sprites.lieClips[p] != nil { lieClip = (p, 0); loafTailTick = nil }
                pendingLieClip = nil
                nextIdleMove = Date().addingTimeInterval(3)
            }
        case .loafing(let until):
            updateLoafFace(now)
            if !stepLieClip(now, allowBelly: true) { stepLoafTail(now) }
            if now >= until, lieClip == nil {
                if restOnly { restOnly = false; state = .wakingUp(wakeFromLoafStart) }      // just a rest: sit back up
                else {
                    // Either stretched out (doze) or curled up in a ball with the tail round the nose.
                    curledSleep = !sprites.curl.isEmpty && (sprites.doze.isEmpty || Bool.random())
                    state = (sprites.doze.isEmpty && !curledSleep) ? .sleeping : .dozing(0)
                }
            }
        case .dozing(let i):
            if i + 1 < currentDozeSequence.count { state = .dozing(i + 1) } else { state = .sleeping }
        case .sleeping:
            if shouldWake() { wake() }
        case .wakingUp(let i):
            if i + 1 < wakeFrames.count { state = .wakingUp(i + 1) } else if moveAwayAfterWake {
                moveAwayAfterWake = false
                walkAwayToNap()
            } else {
                sit(for: TimeInterval.random(in: 60...150))
                play([(.slit, 0.4), (.closed, 0.3), (.neutral, 0.2), (.closed, 0.12)])
            }
        case .landing(let i):
            if i + 1 < 5 { state = .landing(i + 1) } else {
                squash = 1
                sit(for: TimeInterval.random(in: 40...120))
                if let next = afterLanding { afterLanding = nil; next() }
                else if Bool.random() { state = .grooming(0) } else { play([(.closed, 0.12), (.neutral, 0.2), (.closed, 0.12)]) }
            }
        case .clip(let name, let i):
            if i + 1 < clipSequence(name).count { state = .clip(name, i + 1) }
            else {
                state = .sitting(until: sitUntil)
                if name == "sneeze" { play([(.wide, 0.8)]) }                 // a little surprised at itself
            }
        case .wallScratch(let i):
            if i + 1 < wallSequence.count { state = .wallScratch(i + 1) }
            else { state = .sittingDown(0, sitFor: TimeInterval.random(in: 60...150)) }
        case .tailFlick(let i):
            if i + 1 < tailSequence.count { state = .tailFlick(i + 1) } else { state = .sitting(until: sitUntil) }
        case .petted(let since):
            petFrameTick += 1
            if Date().timeIntervalSince(lastPetMove) > 1.4 || Date().timeIntervalSince(since) > 20 {
                sit(for: TimeInterval.random(in: 90...200)); play([(.happy, 1.5)])
            }
        case .crouching(let i):
            if i + 1 < crouchSequence.count { state = .crouching(i + 1) } else { startPounce() }
        case .pouncing(let i, let fromX, let toX):
            let n = pounceSequence.count
            catX = fromX + (toX - fromX) * CGFloat(i + 1) / CGFloat(n)
            if i + 1 < n { state = .pouncing(i + 1, fromX: fromX, toX: toX) } else {
                if playMode { strikePoint = dotPoint; walkedAwayFromStrike = false }
                let caught = playMode && abs(dotPoint.x - faceX) < 40 * scale
                state = .sittingDown(0, sitFor: playMode ? 1.4 : TimeInterval.random(in: 40...90))
                if caught { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.play([(.happy, 0.8)]) } }
            }
        case .eating(let i):
            if i + 1 < Self.eatSequence.count { state = .eating(i + 1) } else { finishEating() }
        case .shaking(let i):
            if i + 1 < shakeSequence.count { state = .shaking(i + 1) } else { sit(for: TimeInterval.random(in: 40...120)) }
        case .leaping, .climbing:
            break                                       // 60 Hz, see physicsLeap / physicsClimb
        case .peeking:
            updateFace(now)                             // stays tucked away until you drag it out
        case .perchLying(let until):
            perchTick += 1
            updateLoafFace(now)
            if !perchTailDown, !stepLieClip(now, allowBelly: false) { stepLoafTail(now) }
            if now >= until, lieClip == nil { state = .wakingUp(wakeFromLoafStart) }
        case .dizzy(let until):
            updateFace(now)
            if now >= until {
                sit(for: TimeInterval.random(in: 40...100))
                play([(.closed, 0.3), (.slit, 0.5), (.closed, 0.15), (.neutral, 0.3), (.closed, 0.12)])
                if Bool.random() { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.showBubble("呼…好了", seconds: 1.6) } }
            }
        case .held, .flying, .jumping:
            break
        }
        if !isAirborne { render() }
    }

    /// Idle clips play every frame twice, except the quick ones (an ear flick, a head shake).
    private func clipSequence(_ name: String) -> [Int] {
        Self.slow(sprites.clips[name]?.count ?? 0, ["ear", "headshake"].contains(name) ? 1 : 2)
    }
    /// Up the wall (2 ticks a frame), hold the stretch, scratch three rounds (quick), then back down.
    /// Indices run over wallUp followed by wallScratch.
    private var wallSequence: [Int] {
        let up = sprites.wallUp.count, sc = sprites.wallScratch.count
        guard up > 0, sc > 0 else { return [] }
        var seq = Self.slow(up, 2)
        seq += Array(repeating: up - 1, count: 8)
        for _ in 0..<3 { seq += (0..<sc).map { up + $0 } }
        seq += Array(repeating: up - 1, count: 3)
        seq += (0..<up).reversed().map { $0 }
        return seq
    }

    /// Walk to the nearer screen edge, stand up against it and scratch. The frames were drawn against a
    /// wall; the screen edge takes its place (paw tips land on the edge).
    @discardableResult
    func goWallScratch() -> Bool {
        guard perch == nil, !isLeaping, !isPeeking, !paused, !sprites.wallUp.isEmpty, !sprites.wallScratch.isEmpty else { return false }
        let vf = currentScreen.visibleFrame
        let left = vf.minX - 2 * scale, right = vf.maxX - 126 * scale
        let target = abs(catX - left) < abs(catX - right) ? left : right
        startWalking(to: target, then: .wall)
        return true
    }

    private var yawnSequence: [Int] { Self.slow(sprites.yawn.count, 2) }
    /// Sitting wash (13 frames): paw up, lick the paw, wipe the face and behind the ear, paw down.
    /// Frame 13 is never held (its eye looks cross).
    private var groomSequence: [Int] {
        let n = sprites.groom.count
        guard n >= 12 else { return Self.slow(n, 4) }
        return Self.seq([([0, 1, 2, 3], 2, 1), ([4, 5, 6, 7, 6, 5], 2, 2), ([7, 8, 9], 2, 1),
                         ([10, 11, 10, 11], 2, 2), ([9, 8, 3, 2, 1, 0], 2, 1)])
    }
    /// Lying clips, all starting and ending in the lying pose.
    private func lieClipSequence(_ name: String) -> [Int] {
        let n = sprites.lieClips[name]?.count ?? 0
        guard n >= 9 else { return Self.slow(n, 2) }
        switch name {
        case "knead":     // paws press in turn, eyes half shut
            // 17 frames: 2...11 is one left-right cycle ending back at the lying pose (11 ~ 1);
            // 12...17 + 8...11 is a slightly different one. Alternate them so it doesn't look looped.
            guard n >= 17 else { return Self.seq([([0, 1, 2, 3], 2, 1), ([3, 4, 5, 6, 7, 8, 7, 6, 5, 4], 2, 3), ([3, 2, 1, 0], 2, 1)]) }
            let a = Array(1...10), b = Array(11...16) + Array(7...10)
            return Self.seq([([0], 2, 1), (a, 1, 1), (b, 1, 1), (a, 1, 1), (b, 1, 1), (a, 1, 1), ([0], 2, 1)])
        case "liegroom":  // lick a front paw, wipe the face
            guard n >= 13 else { return Self.slow(n, 2) }
            return Self.seq([([0, 1, 2, 3], 2, 1), ([4, 5, 6, 7, 6, 5], 2, 2), ([8, 9], 2, 1),
                             ([10, 11, 12, 11], 2, 2), ([9, 8, 3, 2, 1, 0], 2, 1)])
        case "belly":     // roll onto the back, wiggle, roll back
            guard n >= 13 else { return Self.slow(n, 2) }
            return Self.seq([([0, 1, 2, 3], 2, 1), (Array(4..<n) + Array((5..<(n - 1)).reversed()), 2, 2), ([3, 2, 1, 0], 2, 1)])
        default: return Self.slow(n, 2)
        }
    }
    private var curlSequence: [Int] { Self.slow(sprites.curl.count, 4) }
    private var stretchSequence: [Int] {
        let n = sprites.stretch.count
        guard n > 0 else { return [] }
        // Down into the long stretch, hold it (the last two frames rock slightly), then back up.
        var seq: [Int] = []
        for i in 0..<n { seq.append(contentsOf: [i, i]) }
        for k in 0..<4 { seq.append(contentsOf: Array(repeating: k % 2 == 0 ? n - 1 : n - 2, count: 5)) }
        for i in stride(from: n - 2, through: 0, by: -1) { seq.append(contentsOf: [i, i]) }
        return seq
    }
    private var lieSequence: [Int] { Self.slow(sprites.lie.count, 3) }
    private var dozeSequence: [Int] { Self.slow(sprites.doze.count, 5) }
    /// Waking up plays the whole lie-down backwards: chin up, a moment lying, then sit up.
    /// Lying down to asleep: stretched out (doze) or curled up (curl).
    private var currentDozeSequence: [Int] { curledSleep ? curlSequence : dozeSequence }
    private func dozeFrame(_ k: Int) -> Frame { curledSleep ? sprites.curl[k] : sprites.doze[k] }
    private var wakeFrames: [Frame] {
        let doze = currentDozeSequence.reversed().map { dozeFrame($0) }
        let hold = Array(repeating: sprites.loaf[.neutral] ?? sprites.lie.last!, count: 8)
        let lie = lieSequence.reversed().map { sprites.lie[$0] }
        return doze + hold + lie
    }
    private var wakeFromLoafStart: Int { currentDozeSequence.count + 6 }

    private func wake() {
        lieClip = nil
        switch state {
        case .sleeping, .dozing: state = .wakingUp(0)
        case .lyingDown, .loafing: state = .wakingUp(wakeFromLoafStart)
        default: break
        }
    }

    /// Each frame held 2 ticks; one swish out and back is ~1.8 s.
    private var loafTailSequence: [Int] { Self.slow(sprites.loafTail[.neutral]?.count ?? 0, 2) }

    /// Lying with the head up: now and then the tail sweeps out along the ground and curls back,
    /// sometimes twice in a row.
    private func stepLoafTail(_ now: Date) {
        let n = loafTailSequence.count
        guard n > 0 else { return }
        if let t = loafTailTick {
            if t + 1 < n { loafTailTick = t + 1; return }
            loafTailTick = nil
            nextLoafTail = now.addingTimeInterval(Int.random(in: 0..<3) == 0 ? 0.3 : .random(in: 5...14))
        } else if now >= nextLoafTail {
            loafTailTick = 0
        }
    }

    /// Lying: now and then knead, lick a paw, or (on the floor) roll onto the back.
    /// Returns true while a clip is playing (the tail swish waits).
    @discardableResult
    private func stepLieClip(_ now: Date, allowBelly: Bool) -> Bool {
        if let c = lieClip {
            if c.tick + 1 < lieClipSequence(c.name).count { lieClip = (c.name, c.tick + 1); return true }
            lieClip = nil
            nextLieClip = now.addingTimeInterval(.random(in: 20...45))
            return false
        }
        guard now >= nextLieClip, loafTailTick == nil else { return false }
        var names = ["knead", "liegroom", "liegroom"]
        if allowBelly { names += ["belly"] }
        guard let name = names.filter({ sprites.lieClips[$0] != nil }).randomElement() else { nextLieClip = .distantFuture; return false }
        lieClip = (name, 0)
        return true
    }

    private func loafFrame(_ face: Face) -> Frame? {
        if let c = lieClip, let frames = sprites.lieClips[c.name] {
            let q = lieClipSequence(c.name)
            if c.tick < q.count { return frames[q[c.tick]] }
        }
        guard let t = loafTailTick, let frames = sprites.loafTail[face] ?? sprites.loafTail[.neutral],
              t < loafTailSequence.count else { return nil }
        return frames[loafTailSequence[t]]
    }

    /// Lying with the head up: slow, drowsy blinks.
    private func updateLoafFace(_ now: Date) {
        if now < faceUntil { return }
        if !faceQueue.isEmpty {
            let (f, d) = faceQueue.removeFirst(); face = f; faceUntil = now.addingTimeInterval(d); return
        }
        face = .neutral
        guard now >= nextIdleMove else { return }
        nextIdleMove = now.addingTimeInterval(.random(in: 4...9))
        play([[(.closed, 0.14)], [(.slit, 0.5), (.closed, 1.2), (.slit, 0.4)], [(.slit, 1.6)]].randomElement()!)
    }

    /// What to do when a sitting spell ends.
    private func decideNext() {
        if restAfterSit { restAfterSit = false; restOnly = true; lieDown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in self?.askToRest() }; return }
        if perch != nil { decideOnPerch(); return }
        if napAfterSit { napAfterSit = false; napUntil = Date().addingTimeInterval(.random(in: 180...420)); goToSleep(); return }
        if (isBedtime || userIdle > 600), !sprites.lie.isEmpty { goToSleep(); return }
        let r = Int.random(in: 0..<20)
        if r >= 17, onTop, !paused, goPerch() { return }                                          // up onto a window
        if r < 3, !sprites.lie.isEmpty, wokenAt.timeIntervalSinceNow < -600 { goToSleep() }      // a daytime nap
        else if r < 7, !sprites.lie.isEmpty { restOnly = true; lieDown() }                        // lie down for a bit, no sleep
        else if r < 9 { zoomies() }                                                               // a sudden mad dash
        else if r < 11, goWallScratch() { }                                                       // stretch up a screen edge and scratch it
        else { startWalking(to: nil, then: .sit) }
    }

    private func startWalking(to target: CGFloat?, then: After) {
        let vf = currentScreen.visibleFrame
        let w = Self.canvas * scale
        var goal = target ?? CGFloat.random(in: vf.minX...(vf.maxX - w))
        if target == nil, let p = perch {                    // up on a window: stroll along its edge
            let lo = p.minX - 20 * scale, hi = max(lo, p.maxX - w + 20 * scale)
            goal = CGFloat.random(in: lo...hi)
        } else if target == nil, abs(goal - catX) < 120 * scale {   // prefer a walk long enough to read as walking
            goal = catX > vf.midX ? vf.minX + 20 : vf.maxX - w - 20
        }
        faceQueue = []
        face = .neutral
        bubble.orderOut(nil)
        if goal != catX { facingRight = goal > catX }
        switch state {
        case .walking: state = .walking(targetX: goal, then: then)
        default: state = .standingUp(0, targetX: goal, then: then)
        }
    }

    /// Play the sit-down transition (when standing) and then sit.
    private func stopWalking(sitFor seconds: TimeInterval) {
        switch state {
        case .walking, .standingUp: state = .sittingDown(0, sitFor: seconds)
        default: sit(for: seconds)
        }
    }

    private func sit(for seconds: TimeInterval) {
        state = .sitting(until: seconds.isFinite ? Date().addingTimeInterval(seconds) : .distantFuture)
        face = .neutral
        nextIdleMove = Date().addingTimeInterval(TimeInterval.random(in: 3...8))
    }

    // MARK: sleep

    /// Zoomies: a sudden sprint to the far side of the screen.
    func zoomies() {
        if perch != nil || isLeaping || isPeeking { whenOnFloor { [weak self] in self?.zoomies() }; return }
        let vf = currentScreen.visibleFrame
        let w = Self.canvas * scale
        let target = catX > vf.midX ? vf.minX + 30 : vf.maxX - w - 30
        play([(.wide, 0.6)])
        startWalking(to: target, then: .zoom)
    }

    private func goToSleep() {
        if perch != nil || isLeaping || isPeeking { whenOnFloor { [weak self] in self?.goToSleep() }; return }
        restOnly = false
        // A yawn first, when we have one.
        state = sprites.yawn.isEmpty ? .lyingDown(0) : .yawning(0, thenSleep: true)
        if sprites.yawn.isEmpty { lieDown() }
    }

    private func lieDown() {
        guard !sprites.lie.isEmpty else { sit(for: 120); return }
        state = .lyingDown(0)
    }

    private func shouldWake() -> Bool {
        if isBedtime || Date() < napUntil { return false }
        // Daytime nap: wake when you come back, or after a while.
        return userIdle < 3 && Int.random(in: 0..<400) == 0
    }

    // MARK: reminders

    private static var today: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    var bowlLevel: BowlLevel {
        guard drinkInterval > 0 else { return .full }
        let t = Date().timeIntervalSince(lastRefill) / drinkInterval
        return t < 0.5 ? .full : (t < 1 ? .half : .empty)
    }

    private func scheduleReminder() {
        nextReminder = drinkInterval > 0 ? lastRefill.addingTimeInterval(drinkInterval) : .distantFuture
    }

    /// Time for water: the cat walks to its bowl and drinks, then asks you to drink too.
    private func remind() {
        // Nobody at the computer, or it is bedtime: try again later.
        if userIdle > 120 || isBedtime { nextReminder = Date().addingTimeInterval(5 * 60); return }
        reminded += 1
        // One gentle repeat 10 minutes later, then leave it.
        nextReminder = reminded < 2 ? Date().addingTimeInterval(10 * 60) : .distantFuture
        goDrink()
    }

    func goDrink() {
        if isPeeking { play([(.wide, 0.6)]); askToDrink(); return }      // tucked away: just ask from the edge
        if perch != nil || isLeaping || isPeeking { whenOnFloor { [weak self] in self?.goDrink() }; return }
        switch state {
        case .held, .flying, .drinking, .landing: return
        case .sleeping, .lyingDown, .loafing, .dozing: wake(); DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.goDrink() }; return
        default: break
        }
        bowlNeeded = true
        waterReady = false
        bowlFill = .empty                  // it comes because the bowl is empty
        renderBowl()
        render()
        facingRight = bowlX > catX
        startWalking(to: drinkStartCatX, then: .drink)
    }

    private func finishDrinking() {
        // Hand back to the normal canvas where the cat stands after stepping to the bowl.
        let shift = Self.drinkApproachShift * scale
        catX = drinkStartCatX + (facingRight ? -shift : shift)
        state = .sittingDown(0, sitFor: TimeInterval.random(in: 90...240))
        render()
        heartsUntil = Date().addingTimeInterval(1.4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            self.play([(.happy, 2.0)])
            self.showBubble(Self.afterDrinkLine(self.cupsToday), seconds: 4)
        }
        // The bowl is only out for the drink itself (unless it is set to stay): once the cat has had its
        // water it goes away again. The bubble keeps asking; "later" brings cat and bowl back in 10 minutes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !self.isDrinking else { return }
            self.bowlNeeded = false
            self.bowlFill = nil
            self.render()
        }
    }

    /// Start a fresh reminder cycle without counting a cup (used when the interval changes).
    func restartReminder() {
        lastRefill = Date()
        reminded = 0
        UserDefaults.standard.set(lastRefill, forKey: "lastRefill")
        scheduleReminder()
        renderBowl()
    }

    /// The user drank a glass: count it, fill the cat's bowl, and the cat has a drink too.
    /// (From the bubble, the right-click bar or a click on the bowl.)
    func refill() {
        lastRefill = Date()
        reminded = 0
        thirstyAsks = 0
        let d = UserDefaults.standard
        d.set(lastRefill, forKey: "lastRefill")
        d.set(cupsToday + 1, forKey: "cups")
        d.set(Self.today, forKey: "cupsDay")
        gainAffection(.water, delay: 4.5)
        scheduleReminder()
        onChange?()
        let asked = waitingForWater
        waitingForWater = false
        thirstyToken += 1
        let floorFree: Bool = {
            if perch != nil || isLeaping || isPeeking || isDrinking { return false }
            switch state { case .held, .flying, .landing, .sleeping, .dozing, .lyingDown, .loafing, .perchLying: return false; default: return true }
        }()
        guard floorFree else {                      // busy or tucked away: just say thanks
            renderBowl()
            showBubble(Self.afterDrinkLine(cupsToday), seconds: 3)
            return
        }
        bowlNeeded = true
        render()
        let atBowl = abs(catX - drinkStartCatX) < 6 * scale
        if !asked { showBubble(Self.joinYouLines.randomElement()!, seconds: 2.4) } else { bubble.orderOut(nil) }
        play([(.happy, 1.2)])
        // Pour: empty -> half -> full, then (already sitting by the bowl, or after walking over) drink.
        bowlFill = .empty; renderBowl()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.bowlFill = .half; self?.renderBowl() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.bowlFill = .full; self?.renderBowl() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, !self.isDrinking else { return }
            self.facingRight = self.bowlX > self.catX
            if atBowl, case .sitting = self.state {
                self.state = .drinking(0)
            } else {
                self.waterReady = true
                self.startWalking(to: self.drinkStartCatX, then: .drink)
            }
        }
    }

    /// Arrived at the bowl and it is empty: peer into it, look up at you, ask.
    private func arriveThirsty() {
        sit(for: 300)
        facingRight = bowlX > catX
        waitingForWater = true
        thirstyToken += 1
        let token = thirstyToken
        play([(.wide, 0.9), (.slit, 1.0)])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.waitingForWater, token == self.thirstyToken else { return }
            self.askToDrink()
        }
        // Nobody came: after a while it gives up and the bowl goes away (the reminder comes round again).
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            guard let self, self.waitingForWater, token == self.thirstyToken else { return }
            self.waitingForWater = false
            self.bowlNeeded = false
            self.render()
            if case .sitting = self.state { self.showBubble("…那我晚点再来找你", seconds: 2.5) }
        }
    }

    static let joinYouLines = ["你喝水啦？\n那我也陪你喝一口～", "好习惯！\n我也来一口", "干杯喵！"]

    static func afterDrinkLine(_ n: Int) -> String {
        if n == 1 { return "咕嘟咕嘟…今天的第一杯！\n好的开始喵～" }
        if n >= 8 { return "第 \(n) 杯！今天的水喝够啦\n你是最会照顾自己的人类" }
        return ["咕嘟咕嘟…好喝！\n今天第 \(n) 杯啦",
                "哈～活过来了\n我们今天喝了 \(n) 杯",
                "谢谢你加的水～\n今天第 \(n) 杯，继续保持",
                "（舔舔嘴）满足了\n今天第 \(n) 杯"].randomElement()!
    }

    /// Track continuous computer use; after `standInterval` the cat gets up and stretches.
    private func checkActivity() {
        let idle = userIdle
        if idle > 300 { activeSince = Date(); standReminded = false; return }
        guard standInterval > 0, !standReminded, Date().timeIntervalSince(activeSince) >= standInterval else { return }
        switch state {
        case .sitting, .walking, .sleeping, .loafing, .perchLying, .peeking:
            standReminded = true
            // Either a big stretch, or it walks to the middle of the screen and lies down: time for a break.
            if Bool.random() { restInMiddle() } else { stretchNow(remind: true) }
        default: break
        }
    }

    func stretchNow(remind: Bool = false) {
        if isPeeking { if remind { askToStand() }; return }
        if perch != nil || isLeaping || isPeeking { whenOnFloor { [weak self] in self?.stretchNow(remind: remind) }; return }
        switch state {
        case .held, .flying, .drinking, .landing, .stretching: return
        case .sleeping, .lyingDown, .loafing, .dozing:
            wake()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.stretchNow(remind: remind) }
            return
        default: break
        }
        bubble.orderOut(nil)
        switch state {
        case .walking: state = .stretching(0)
        default: state = .standingUp(0, targetX: catX, then: .stretch)
        }
        if remind {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.askToStand()
            }
        }
    }

    /// Restart the sit-too-long timer (e.g. after the user took a break).
    func resetStandTimer() { activeSince = Date(); standReminded = false }

    /// The cat's bowl is empty and it is thirsty; you drink a glass first, then you may fill its bowl.
    /// The more often it is put off, the more pitiful it gets.
    func askToDrink() {
        let lines: [String]
        switch thirstyAsks {
        case 0: lines = ["碗空了…\n我渴了喵", "（舔了舔碗底）\n一滴水都没有了…", "喵…嗓子好干"]
        case 1: lines = ["我还在等你哦…\n你喝了没？", "喵呜…快渴成猫干了\n你也好久没喝水了吧"]
        default: lines = ["（可怜巴巴地看着你）\n就一杯…你喝我也喝", "再不喝水\n我们俩都要变成葡萄干了"]
        }
        let ask = lines.randomElement()! + "\n你先喝一杯，再帮我把碗加满好不好？"
        showBubble(ask, seconds: 300, buttons: [
            .init(title: "我喝了，加水！") { [weak self] in self?.refill() },
            .init(title: "等会儿") { [weak self] in self?.snoozeDrink() },
        ])
    }

    func snoozeDrink() {
        nextReminder = Date().addingTimeInterval(10 * 60)
        reminded = 0
        thirstyAsks += 1
        let wasWaiting = waitingForWater
        waitingForWater = false
        thirstyToken += 1
        showBubble(["好吧…那我先忍着", "说好了哦\n10 分钟后我再来找你", "呜…我等你"].randomElement()!, seconds: 2.8)
        if case .sitting = state { play([(.slit, 2.0)]) }
        if wasWaiting {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.waitingForWater, !self.isDrinking, !self.waterReady else { return }
                self.bowlNeeded = false
                self.render()
            }
        }
    }

    /// Sit-too-long bubble after the stretch.
    func askToStand() {
        let minutes = Int(Date().timeIntervalSince(activeSince) / 60)
        showBubble("已经连续坐了 \(minutes) 分钟啦\n起来活动一下吧", seconds: 300, buttons: [
            .init(title: "起来了") { [weak self] in
                self?.resetStandTimer()
                self?.play([(.happy, 1.6)])
                self?.showBubble("好耶，动一动～", seconds: 2.5)
            },
            .init(title: "等会儿") { [weak self] in
                guard let self else { return }
                // Ask again in 10 minutes.
                self.standReminded = false
                self.activeSince = Date().addingTimeInterval(-(self.standInterval - 10 * 60))
                self.showBubble("好，10 分钟后再提醒你", seconds: 2.5)
            },
        ])
    }

    /// Speak: a pixel bubble just above the cat's head (never over the cat), tail pointing at the face.
    func showBubble(_ text: String, seconds: TimeInterval = 60, buttons: [BubbleWindow.Button] = []) {
        if case .peeking(let side, let y, _) = state {        // above the head poking out of the edge
            let vf = currentScreen.visibleFrame
            let tipX = side > 0 ? vf.maxX - 22 * scale : vf.minX + 22 * scale
            bubble.show(text, buttons: buttons, tipX: tipX, baseY: y + 128 * scale, pixel: scale, level: .floating, seconds: seconds)
            return
        }
        let f = window.frame
        let frame = currentFrame()
        let w = CGFloat(frame.width) * scale
        let topY = f.minY + CGFloat(frame.height - frame.topRow) * scale * (f.height / max(1, CGFloat(frame.height) * scale))
        var (lo, hi) = frame.headSpan()
        if facingRight { (lo, hi) = (frame.width - 1 - hi, frame.width - 1 - lo) }
        let tipX = f.minX + CGFloat(lo + hi) / 2 * scale * (f.width / max(1, w))
        bubble.show(text, buttons: buttons, tipX: tipX, baseY: topY + 2 * scale, pixel: scale, level: .floating, seconds: seconds)
    }

    /// Close the bubble only if it still shows `text`.
    func hideBubble(ifShowing text: String) { if bubble.text == text { bubble.orderOut(nil) } }

    // MARK: faces

    private func play(_ moves: [(Face, TimeInterval)]) {
        faceQueue = moves
        faceUntil = .distantPast
    }

    private func updateFace(_ now: Date) {
        if now < faceUntil { return }
        if !faceQueue.isEmpty {
            let (f, d) = faceQueue.removeFirst()
            face = f
            faceUntil = now.addingTimeInterval(d)
            return
        }
        face = .neutral
        guard now >= nextIdleMove else { return }
        nextIdleMove = now.addingTimeInterval(TimeInterval.random(in: 6...14))
        if !lookTarget.isEmpty && glance == nil { return }        // busy watching the cursor: no idle business
        if case .sitting = state, Int.random(in: 0..<3) == 0, !sprites.headPose.isEmpty {   // look around a bit
            glanceAround(); return
        }
        if case .sitting = state {
            let r = Int.random(in: 0..<20)
            if r < 2 { state = .grooming(0); return }                       // now and then, a grooming session
            if r < 5, !sprites.tail.isEmpty, case .sitting(let until) = state {   // a lazy tail swish
                sitUntil = until; state = .tailFlick(0); return
            }
            // Now and then: scratch an itch, sneeze, swat at a bug, flick an ear or shake its head.
            if r < 8, case .sitting(let until) = state,
               let name = ["scratch", "sneeze", "swat", "ear", "ear", "headshake"].filter({ sprites.clips[$0] != nil }).randomElement() {
                sitUntil = until; state = .clip(name, 0); return
            }
            let yawnChance = (hour >= 21 || hour < 8) ? 3 : 1
            if r < 2 + yawnChance, !sprites.yawn.isEmpty { state = .yawning(0, thenSleep: false); return }
        }
        // Mostly a single calm blink; the other moves are occasional.
        var options: [[(Face, TimeInterval)]] = [
            [(.closed, 0.12)], [(.closed, 0.12)], [(.closed, 0.12)],
            [(.closed, 0.12), (.neutral, 0.18), (.closed, 0.12)],
            [(.slit, 0.22), (.closed, 0.8), (.slit, 0.22)],
            [(.wide, 1.8)],
            [(.lick, 0.16), (.neutral, 0.11), (.lick, 0.16)],
            [(.happy, 1.4)],
        ]
        if (8..<18).contains(hour) { options.append([(.daylight, 1.5)]) }
        play(options.randomElement()!)
    }

    // MARK: drawing

    private func currentFrame() -> Frame {
        switch state {
        case .walking(_, let then) where then == .zoom && !sprites.run.isEmpty: return sprites.run[runIndex % sprites.run.count]
        case .walking: return sprites.walk[walkIndex]
        case .standingUp(let i, _, _): return sprites.standUp[i]
        case .sittingDown(let i, _): return sprites.sitDown[i]
        case .grooming(let i): return sprites.groom[groomSequence[i]]
        case .yawning(let i, _): return sprites.yawn[yawnSequence[i]]
        case .drinking(let i): return sprites.drink[Self.drinkSequence[i]]
        case .stretching(let i): return sprites.stretch[stretchSequence[i]]
        case .lyingDown(let i): return sprites.lie[lieSequence[i]]
        case .loafing: return loafFrame(face) ?? sprites.loaf[face] ?? sprites.loaf[.neutral] ?? sprites.lie.last!
        case .dozing(let i): return dozeFrame(currentDozeSequence[i])
        case .wakingUp(let i): return wakeFrames[i]
        case .sleeping: return (curledSleep ? sprites.curl.last : sprites.doze.last) ?? sprites.lie.last!
        case .held(let since): return sprites.lift[heldFrameIndex(since)]
        case .flying: return sprites.lift[Self.liftSurprised]
        case .landing: return sprites.sit[.closed]!
        case .tailFlick(let i): return sprites.tail[tailSequence[i]]
        case .wallScratch(let i): let n = sprites.wallUp.count, k = wallSequence[i]
            return k < n ? sprites.wallUp[k] : sprites.wallScratch[k - n]
        case .clip(let name, let i): return sprites.clips[name]![clipSequence(name)[i]]
        case .petted: return sprites.rub.isEmpty ? sprites.sit[.happy]! : sprites.rub[rubSequence[petFrameTick % rubSequence.count]]
        case .crouching(let i): return sprites.crouch[crouchSequence[i]]
        case .pouncing(let i, _, _): return sprites.pounce[pounceSequence[i]]
        case .eating(let i): return sprites.eat[Self.eatSequence[i]]
        case .shaking(let i): return sprites.shake[shakeSequence[i]]
        case .jumping(let tick, let vy, let y, _):
            if sprites.jump.count < 6 { return sprites.sit[.wide]! }
            _ = y
            if tick <= Self.jumpCrouchTicks { return sprites.jump[tick < 6 ? 0 : 1] }    // crouch before take-off
            if tick >= Self.jumpLanded { return sprites.jump[5] }                       // landed
            return vy > 0 ? sprites.jump[(tick / 6) % 2 == 0 ? 2 : 3] : sprites.jump[4]
        case .leaping(let tick, _, _, let ticks, let up):
            if tick < Self.jumpCrouchTicks { return sprites.jump[tick < 6 ? 0 : 1] }
            let u = Double(tick - Self.jumpCrouchTicks) / Double(max(1, ticks))
            if up { return u < 0.6 ? sprites.jump[(tick / 6) % 2 == 0 ? 2 : 3] : sprites.jump[4] }
            return u < 0.25 ? sprites.jump[2] : sprites.jump[4]
        case .climbing(let tick, _, _):
            return climbFrame(tick).0
        case .perchLying:
            if !perchTailDown { return loafFrame(face) ?? sprites.loafTail[face]?.first ?? sprites.loafTail[.neutral]!.first! }
            let loop = sprites.perchFaces[face].flatMap { $0.isEmpty ? nil : $0 } ?? sprites.perch
            return loop[(perchTick / 2) % loop.count]
        case .sitting where face == .neutral && !lookPose.isEmpty: return sprites.headPose[lookPose] ?? sprites.sit[face]!
        default: return sprites.sit[face]!
        }
    }

    private func heldFrameIndex(_ since: Date) -> Int {
        let t = Date().timeIntervalSince(since)
        if t < 1.2 { return Self.liftSurprised }
        if t < 5 { return Self.liftRelaxed }
        return Self.liftWiggle[Int(t / 0.14) % Self.liftWiggle.count]      // wants down: paddling
    }

    /// Ground-bound drawing (everything except held/flying, which `drawAirborne` handles).
    private func render() {
        if case .peeking(let side, let y, _) = state { renderPeek(side: side, y: y); return }
        view.clips = false
        let frame = currentFrame()
        let w = CGFloat(frame.width) * scale, h = CGFloat(frame.height) * scale
        var origin = isDrinking ? CGPoint(x: drinkOriginX, y: groundY)
                   : isEating ? CGPoint(x: eatOriginX, y: groundY) : CGPoint(x: catX, y: groundY)
        if case .jumping(_, _, let y, _) = state { origin.y += y }
        if case .leaping = state { origin = leapPos }
        if case .climbing(let tick, let x, let top) = state { origin = CGPoint(x: x, y: climbOriginY(tick, top: top)) }
        else if case .wallScratch = state { origin.x += (facingRight ? 2 : -2) * scale }   // 128 x 192, feet at the bottom like the 128 canvas
        else if CGFloat(frame.height) > Self.canvas { origin.y -= (CGFloat(frame.height) - Self.canvas) * scale }   // tail hangs below the ledge
        // Wider canvases (lying down) keep the cat's sitting spot on the left; mirrored, it is on the right.
        if isRunning || { if case .stretching = state { return true } else { return false } }() {
            // The stretch canvas is wider in front of the cat (front paws reach forward), body at the usual spot.
            if !facingRight { origin.x -= (CGFloat(frame.width) - Self.canvas) * scale }
        } else if !isDrinking && !isEating && facingRight && CGFloat(frame.width) > Self.canvas { origin.x -= (CGFloat(frame.width) - Self.canvas) * scale }
        setWindow(CGRect(origin: origin, size: CGSize(width: w, height: h)))
        var sy: CGFloat = 1
        if case .sleeping = state {                       // slow breathing
            sy = 1 + 0.018 * CGFloat(sin(Date().timeIntervalSinceReferenceDate * 2 * .pi / 3.2))
        }
        if case .landing = state { sy = squash }
        var lean: CGFloat = 0
        if case .dizzy(let until) = state {                // woozy: a slow sway that eases off at the end
            let left = until.timeIntervalSinceNow
            let ease = CGFloat(min(1, max(0, left / 1.2)))
            lean = 0.075 * ease * CGFloat(sin(Date().timeIntervalSinceReferenceDate * 2 * .pi * 0.75))
            sy = 1 + 0.01 * ease * CGFloat(sin(Date().timeIntervalSinceReferenceDate * 2 * .pi * 1.5))
        }
        if case .petted = state {                          // purring: a tiny quick rumble
            sy = 1 + 0.006 * CGFloat(sin(Date().timeIntervalSinceReferenceDate * 2 * .pi * 3))
        }
        view.show(image: frame.image(night: isNight), size: CGSize(width: w, height: h),
                  anchor: CGPoint(x: 0.5, y: 0.03), at: CGPoint(x: w / 2, y: h * 0.03),
                  mirrored: facingRight, rotation: lean, scaleX: 1 / sqrt(sy), scaleY: sy)
        // The drinking clip has its own bowl; hide the real one meanwhile.
        // Swaps between the clip's bowl and the real one are instant both ways (a fade here leaves a
        // see-through gap for a moment); only plain showing / putting away fades.
        let drinking = isDrinking
        setBowlVisible(!drinking && bowlShown, animated: !drinking && !wasDrinking)
        wasDrinking = drinking
        // Likewise the eating clip draws the shrimp itself.
        var realShrimpVisible = true
        if case .eating(let i) = state { realShrimpVisible = Self.eatSequence[i] < Self.eatPickupFrame }
        if (shrimpOnFloor || shrimpFalling || shrimpHeld) && realShrimpVisible { if !shrimpWindow.isVisible { shrimpWindow.orderFrontRegardless() } } else { shrimpWindow.orderOut(nil) }
    }

    private func setWindow(_ rect: CGRect) {
        if window.frame != rect { window.setFrame(rect, display: false) }
        if view.frame.size != rect.size { view.frame = CGRect(origin: .zero, size: rect.size) }
    }

    private var bowlVisible = false
    private var wasDrinking = false
    /// A lying clip (knead / liegroom / belly) playing over the lying pose, and when the next may start.
    private var lieClip: (name: String, tick: Int)?
    /// A lying clip to play as soon as the cat has lain down (petting at high affection).
    private var pendingLieClip: String?
    /// Long-term affection: drinking, petting and shrimp (capped per day) make it a cuddlier cat.
    let affection = Affection()
    private var nextLieClip = Date.distantFuture
    /// This sleep is curled up in a ball (`curl`) instead of stretched out (`doze`).
    private var curledSleep = false
    private var runIndex = 0
    private func setBowlVisible(_ visible: Bool, animated: Bool) {
        guard visible != bowlVisible else { return }
        bowlVisible = visible
        if visible {
            bowlWindow.alphaValue = animated ? 0 : 1
            bowlWindow.orderFrontRegardless()
            if animated { NSAnimationContext.runAnimationGroup { $0.duration = 0.4; bowlWindow.animator().alphaValue = 1 } }
        } else if animated {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; bowlWindow.animator().alphaValue = 0 },
                                                 completionHandler: { [weak self] in if self?.bowlVisible == false { self?.bowlWindow.orderOut(nil) } })
        } else {
            bowlWindow.orderOut(nil)
        }
    }

    private func renderBowl() {
        bowlView.show(sprites.bowl[bowlFill ?? bowlLevel]!, mirrored: false)
    }

    // MARK: 60 Hz: pass-through, cursor, held swing and flight

    private func fastTick() {
        let now = Date()
        let dt = CGFloat(min(0.05, now.timeIntervalSince(lastPhysics)))
        lastPhysics = now
        switch state {
        case .held(let since): physicsHeld(dt: dt, since: since)
        case .flying: physicsFlying(dt: dt)
        case .sleeping, .petted, .dizzy: render()  // breathing / leaning / swaying
        case .jumping: physicsJump(dt: dt)
        case .leaping: physicsLeap()
        case .climbing: physicsClimb()
        case .peeking: updatePeek(dt: dt)
        default: break
        }
        updatePetting()
        updatePlay(dt: dt)
        updateShrimp(dt: dt)
        switch state {
        default: break
        }
        updateMousePassThrough()
        updateLook()
        updateParticles(now)
        if perch != nil, now.timeIntervalSince(lastPerchCheck) > 0.1 { lastPerchCheck = now; checkPerch() }
        if logPhysics, Int(now.timeIntervalSinceReferenceDate * 60) % 6 == 0 {
            let f = window.frame
            print(String(format: "%.2f %@ x=%.0f y=%.0f w=%.0f angle=%.2f squash=%.2f ground=%.0f look=%@ fx=%d tail=%d perch=%@",
                         now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000),
                         "\(state)".components(separatedBy: "(").first ?? "", f.minX, f.minY, f.width, angle, squash, groundY, lookPose.isEmpty ? "-" : lookPose, effects.count, loafTailTick ?? -1, perch.map { String(format: "%.0f", $0.top) } ?? (isPeeking ? String(format: "peek%.2f", peekOut) : "-")))
            fflush(stdout)
        }
    }
    /// Where the top of the head is on screen, plus which way the face points (+1 = right on screen).
    private func headTop() -> (CGPoint, CGFloat) {
        let frame = currentFrame()
        let f = window.frame
        let (lo, hi) = frame.headSpan()
        // Lying sprites are wide and the head is at the left end; sitting ones fit the span.
        let sx = CGFloat(frame.width) > Self.canvas ? CGFloat(lo) + 20 : CGFloat(lo + hi) / 2
        let x = facingRight ? f.minX + (CGFloat(frame.width) - sx) * scale : f.minX + sx * scale
        return (CGPoint(x: x, y: f.maxY - CGFloat(frame.topRow) * scale), facingRight ? 1 : -1)
    }

    /// Hearts after a treat or while being petted; Z's while drowsy or asleep. Each one pops up at a
    /// slightly different spot so it never looks stamped.
    private func updateParticles(_ now: Date) {
        effects.update()
        guard now >= nextParticle, !isAirborne else { return }
        var kind: Effects.Kind?
        var gap: ClosedRange<Double> = 1...2
        var drowsy = false
        switch state {
        case .sleeping: drowsy = true; gap = 1.3...2.2
        case .dozing: drowsy = true; gap = 1.8...2.6
        case .loafing: drowsy = !restOnly && face != .neutral; gap = 2.2...3.4
        default: break
        }
        if drowsy && now < sleepPetUntil { kind = .heart; gap = 0.7...1.2 }
        else if drowsy { kind = .zzz }
        else if now < heartsUntil, !isEating { kind = .heart; gap = 0.18...0.45 }
        else if case .petted = state, Date().timeIntervalSince(lastPetMove) < 0.5 { kind = .heart; gap = 0.9...1.6 }
        guard let kind else { return }
        nextParticle = now.addingTimeInterval(.random(in: gap))
        let (top, facing) = headTop()
        let jitter: CGPoint
        let outward: CGFloat
        if kind == .zzz {
            jitter = CGPoint(x: facing * CGFloat.random(in: 4...16) * scale, y: CGFloat.random(in: 0...10) * scale)
            outward = facing
        } else {
            let side: CGFloat = Bool.random() ? 1 : -1
            // Close to the middle they start above the ears; further out they can start lower, beside the head.
            let dx = CGFloat.random(in: 6...34)
            jitter = CGPoint(x: side * dx * scale, y: (dx < 24 ? CGFloat.random(in: 4...14) : CGFloat.random(in: -12...6)) * scale)
            outward = side
        }
        effects.spawn(kind, at: CGPoint(x: top.x + jitter.x, y: top.y + jitter.y), pixel: scale, outward: outward,
                      level: levelValue, screen: currentScreen)
    }

    var logPhysics: Bool { ProcessInfo.processInfo.environment["ZHUZHU_LOG"] != nil }

    /// Turn the head toward the cursor when it moves near the cat (8 directions); turn back when it rests or leaves.
    /// With no cursor around, an idle glance (`glance`) may set the target instead.
    private func updateLook() {
        let p = mouse
        if hypot(p.x - lastCursor.x, p.y - lastCursor.y) > 2 { cursorMovedAt = Date(); lastCursor = p }
        var target = ""
        if case .sitting = state, face == .neutral {
            let f = window.frame
            let head = CGPoint(x: f.minX + (facingRight ? Self.canvas - Self.eyeMid.x : Self.eyeMid.x) * scale,
                               y: f.minY + (Self.canvas - Self.eyeMid.y) * scale)
            let dx = p.x - head.x, dy = p.y - head.y, dist = hypot(dx, dy)
            if Date() < lookRestUntil {
                // just got over being dizzy: not looking at that cursor for a bit
            } else if Date().timeIntervalSince(cursorMovedAt) < 2.5, !cursorOverCat, dist < 320 * scale, dist > 50 * scale {
                trackSwing(p.x)
                var a = atan2(dy, dx) * 180 / .pi                    // screen: 0 = right, 90 = up
                if facingRight { a = 180 - a }                         // into sprite left/right
                if a > 180 { a -= 360 }
                // Sectors (sprite space) with a little stickiness so the head doesn't flicker on borders.
                let sectors: [(String, CGFloat)] = [("r", 0), ("ur", 45), ("u", 90), ("ul", 135), ("l", 180), ("l", -180),
                                                    ("dl", -135), ("d", -90), ("dr", -45)]
                func dist(_ x: CGFloat, _ y: CGFloat) -> CGFloat { let d = abs(x - y); return min(d, 360 - d) }
                let current = String(lookPose.prefix { $0.isLetter })
                var family = sectors.min { dist(a, $0.1) < dist(a, $1.1) }!.0
                if let c = sectors.first(where: { $0.0 == current }), dist(a, c.1) < 22.5 + 12 { family = current }
                switch family {
                case "r", "l":
                    let h = abs(dx)
                    target = family + (h < 140 * scale ? "1" : (h < 230 * scale ? "2" : "3"))
                case "u": target = dy > 170 * scale ? "u2" : "u1"
                default: target = family + "1"
                }
                if sprites.headPose[target] == nil { target = "" }
            } else if let g = glance, Date() < g.until {
                target = g.pose
            }
        }
        lookTarget = target
    }

    /// Counts left-right swings of the cursor (each at least ~50 pt). Seven turns within six seconds
    /// and the cat, which has been following with its head, gets dizzy.
    private func trackSwing(_ x: CGFloat) {
        let now = Date()
        let minSwing = 50 * scale
        if swingDir == 0 { swingDir = x >= swingExtreme ? 1 : -1; swingExtreme = x; return }
        if (x - swingExtreme) * swingDir > 0 { swingExtreme = x }              // still going the same way
        else if abs(x - swingExtreme) > minSwing {                              // turned around
            swingDir = -swingDir; swingExtreme = x
            swingFlips = swingFlips.filter { now.timeIntervalSince($0) < 6 } + [now]
            if swingFlips.count >= 7 { getDizzy() }
        }
    }

    private func getDizzy() {
        swingFlips = []
        guard case .sitting(let until) = state else { return }
        _ = until
        let duration = TimeInterval.random(in: 3.2...4.2)
        lookPose = ""; lookTarget = ""; glance = nil
        state = .dizzy(until: Date().addingTimeInterval(duration))
        var faces: [(Face, TimeInterval)] = [(.wide, 0.35)]
        while faces.reduce(0, { $0 + $1.1 }) < duration { faces += [(.slit, 0.5), (.closed, 0.35)] }
        play(faces)
        lookRestUntil = Date().addingTimeInterval(duration + 8)
        showBubble(["晕了～", "@_@ 晕…", "转晕啦～"].randomElement()!, seconds: 2.2)
        let (top, _) = headTop()
        effects.orbit(center: CGPoint(x: top.x, y: top.y + 9 * scale), radius: CGSize(width: 26 * scale, height: 7 * scale),
                      count: 3, duration: duration, pixel: scale, level: levelValue, screen: currentScreen)
    }

    /// Look around on its own for a moment (idle variety).
    func glanceAround() {
        let poses = ["l2", "r2", "l3", "r3", "u1", "u2", "ul1", "ur1", "dl1", "dr1", "d1"].filter { sprites.headPose[$0] != nil }
        guard let p = poses.randomElement() else { return }
        glance = (p, Date().addingTimeInterval(.random(in: 1.4...3.2)))
    }

    /// One step per frame tick toward the target head pose, so the head turns rather than snaps.
    func stepLook() {
        guard lookTarget != lookPose else { return }
        // Shortest path through neighbouring poses, so e.g. up-left -> up -> up-right sweeps across
        // instead of dropping back to the front first.
        var prev: [String: String] = [lookPose: lookPose]
        var queue = [lookPose], i = 0
        while i < queue.count, prev[lookTarget] == nil {
            let n = queue[i]; i += 1
            for m in Self.lookGraph[n] ?? [] where prev[m] == nil && (m.isEmpty || sprites.headPose[m] != nil) {
                prev[m] = n; queue.append(m)
            }
        }
        guard prev[lookTarget] != nil else { lookPose = lookTarget; return }
        var step = lookTarget
        while let p = prev[step], p != lookPose { step = p }
        lookPose = step
    }

    /// Which head poses are next to each other ("" = facing front).
    private static let lookGraph: [String: [String]] = {
        let edges: [(String, String)] = [
            ("", "l1"), ("", "r1"), ("", "u1"), ("", "d1"),
            ("l1", "l2"), ("l2", "l3"), ("r1", "r2"), ("r2", "r3"), ("u1", "u2"),
            ("ul1", "u1"), ("ul1", "u2"), ("ul1", "l1"), ("ul1", "l2"),
            ("ur1", "u1"), ("ur1", "u2"), ("ur1", "r1"), ("ur1", "r2"),
            ("dl1", "d1"), ("dl1", "l1"), ("dl1", "l2"),
            ("dr1", "d1"), ("dr1", "r1"), ("dr1", "r2"),
        ]
        var g: [String: [String]] = [:]
        for (a, b) in edges { g[a, default: []].append(b); g[b, default: []].append(a) }
        return g
    }()

    private func updateMousePassThrough() {
        if isAirborne { window.ignoresMouseEvents = false; return }
        let p = mouse
        if isPeeking {
            let f = window.frame
            // A strip along the edge where the head is can be grabbed, even while it has ducked back in,
            // so you can always drag it out (a click right at the screen edge is easy to miss).
            let vf = currentScreen.visibleFrame
            let onRight = f.maxX >= vf.maxX - 1
            let reach = max(26 * scale, (10 + 36 * peekOut) * scale)
            let band = CGRect(x: onRight ? f.maxX - reach : f.minX, y: f.minY + 40 * scale, width: reach, height: 95 * scale)
            let over = band.contains(p)
            window.ignoresMouseEvents = !over
            if over { NSCursor.openHand.set() } else if cursorOverCat { NSCursor.arrow.set() }
            cursorOverCat = over
            return
        }
        let f = window.frame
        var over = false
        if f.contains(p) {
            let frame = currentFrame()
            var sx = Int((p.x - f.minX) / scale)
            let sy = Int((f.maxY - p.y) / scale)
            if facingRight { sx = frame.width - 1 - sx }
            over = frame.isOpaque(x: sx, y: sy)
        }
        window.ignoresMouseEvents = !over
        if over { NSCursor.openHand.set() } else if cursorOverCat { NSCursor.arrow.set() }
        cursorOverCat = over
    }

    /// Spring-damped pendulum hanging from the cursor.
    private func physicsHeld(dt: CGFloat, since: Date) {
        let p = mouse
        let t = Date().timeIntervalSinceReferenceDate
        samples.append((p, t))
        samples.removeAll { t - $0.1 > 0.12 }
        let v = cursorVelocity()
        // The body lags behind horizontal motion; a gentle pull back to hanging straight down.
        // Smoothed hand acceleration drives the swing.
        let rawAccel = (v.dx - lastVX) / max(dt, 0.001)
        lastVX = v.dx
        smoothAccel += (rawAccel - smoothAccel) * min(1, dt * 12)
        let accelX = smoothAccel
        let k: CGFloat = 38, c: CGFloat = 4.2
        var torque = -k * angle - c * angularVelocity - max(-30, min(30, accelX * 0.011))
        if case .held(let s) = state, Date().timeIntervalSince(s) > 5 {
            torque += CGFloat.random(in: -14...14)                     // wriggling
        }
        angularVelocity += torque * dt
        angle = max(-0.7, min(0.7, angle + angularVelocity * dt))
        // A little stretch when yanked upward, like a liquid cat.
        let targetStretch = 1 + min(0.12, max(0, v.dy) / 6000)
        stretchY += (targetStretch - stretchY) * min(1, dt * 10)
        grip = p
        drawAirborne(frame: currentFrame(), anchorScreen: p, rotation: angle, stretch: stretchY)
    }
    private var lastVX: CGFloat = 0
    private var smoothAccel: CGFloat = 0

    private func cursorVelocity() -> CGVector {
        guard let first = samples.first, let last = samples.last, last.1 - first.1 > 0.005 else { return .zero }
        let dt = CGFloat(last.1 - first.1)
        return CGVector(dx: (last.0.x - first.0.x) / dt, dy: (last.0.y - first.0.y) / dt)
    }

    /// Draw the 128 sprite with its scruff at `anchorScreen` inside a padded window.
    private func drawAirborne(frame: Frame, anchorScreen: CGPoint, rotation: CGFloat, stretch: CGFloat) {
        let pad = Self.heldPad * scale
        let size = Self.canvas * scale
        let side = size + 2 * pad
        let ax = Self.scruff.x * scale, ay = (Self.canvas - Self.scruff.y) * scale   // in sprite points, y up
        let anchorInView = CGPoint(x: pad + ax, y: pad + ay)
        setWindow(CGRect(x: anchorScreen.x - anchorInView.x, y: anchorScreen.y - anchorInView.y, width: side, height: side))
        var anchorNorm = CGPoint(x: Self.scruff.x / Self.canvas, y: 1 - Self.scruff.y / Self.canvas)
        if facingRight { anchorNorm.x = 1 - anchorNorm.x }
        view.show(image: frame.image(night: isNight), size: CGSize(width: size, height: size), anchor: anchorNorm,
                  at: anchorInView, mirrored: facingRight, rotation: rotation, scaleX: 1 / sqrt(stretch), scaleY: stretch)
    }

    /// Thrown or dropped: fly with gravity, bounce off the screen edges, land on the floor.
    private func physicsFlying(dt: CGFloat) {
        let vf = currentScreen.visibleFrame
        let g: CGFloat = 2600
        velocity.dy -= g * dt
        velocity.dx *= (1 - 0.6 * dt)
        flyPos.x += velocity.dx * dt
        flyPos.y += velocity.dy * dt
        let w = Self.canvas * scale
        if flyPos.x < vf.minX { flyPos.x = vf.minX; velocity.dx = abs(velocity.dx) * 0.4 }
        if flyPos.x > vf.maxX - w { flyPos.x = vf.maxX - w; velocity.dx = -abs(velocity.dx) * 0.4 }
        if flyPos.y > vf.maxY - w { flyPos.y = vf.maxY - w; velocity.dy = -abs(velocity.dy) * 0.3 }
        // Turn back upright while flying.
        angle += (0 - angle) * min(1, dt * 6)
        if velocity.dy < 0, let ledge = flyLedges.first(where: { l in
            let mid = flyPos.x + w / 2
            return mid > l.minX + 20 * scale && mid < l.maxX - 20 * scale
                && flyPos.y <= l.top - Self.perchSink * scale && flyPos.y - velocity.dy * dt > l.top - Self.perchSink * scale
        }) {
            flyPos.y = ledge.top - Self.perchSink * scale
            perch = ledge
            flyLedges = []
            land(impact: -velocity.dy)
            return
        }
        if flyPos.y <= groundY {
            flyLedges = []
            land(impact: -velocity.dy)
            return
        }
        let anchor = CGPoint(x: flyPos.x + Self.scruff.x * scale * (facingRight ? -1 : 1) + (facingRight ? w : 0),
                             y: flyPos.y + (Self.canvas - Self.scruff.y) * scale)
        drawAirborne(frame: currentFrame(), anchorScreen: anchor, rotation: angle, stretch: 1)
    }

    private func land(impact: CGFloat) {
        catX = min(max(flyPos.x, currentScreen.visibleFrame.minX), currentScreen.visibleFrame.maxX - Self.canvas * scale)
        if let p = perch { catX = min(max(catX, p.minX - 30 * scale), p.maxX - Self.canvas * scale + 30 * scale) }
        angle = 0; angularVelocity = 0
        // Squash on landing, harder from higher up, then spring back.
        let depth = min(0.28, 0.08 + impact / 9000)
        state = .landing(0)
        squash = 1 - depth
        for (k, s) in [(1, 1 + depth * 0.4), (2, 1 - depth * 0.3), (3, 1 + depth * 0.1), (4, 1.0)].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07 * Double(k + 1)) { [weak self] in
                if case .landing = self?.state { self?.squash = s.1; self?.render() }
            }
        }
        render()
    }

    // MARK: mouse: cat

    fileprivate func mouseDown(_ event: NSEvent) {
        pressPoint = mouse
        dragMoved = false
        NSCursor.closedHand.set()
    }

    fileprivate func mouseDragged(_ event: NSEvent) {
        if isDrinking { return }
        let p = mouse
        if !dragMoved {
            guard hypot(p.x - pressPoint.x, p.y - pressPoint.y) > 3 else { return }
            dragMoved = true
            bubble.orderOut(nil)
            faceQueue = []
            samples = []
            angle = 0; angularVelocity = 0; stretchY = 1; lastVX = 0
            perch = nil
            view.clips = false
            state = .held(since: Date())
        }
        NSCursor.closedHand.set()
    }

    fileprivate func mouseUp(_ event: NSEvent) {
        if dragMoved {
            // Throw with the hand's last velocity, or just let go.
            var v = cursorVelocity()
            let speed = hypot(v.dx, v.dy)
            if speed > 3000 { v.dx *= 3000 / speed; v.dy *= 3000 / speed }
            velocity = v
            let w = Self.canvas * scale
            flyPos = CGPoint(x: grip.x - (facingRight ? w - Self.scruff.x * scale : Self.scruff.x * scale),
                             y: grip.y - (Self.canvas - Self.scruff.y) * scale)
            let vf = currentScreen.visibleFrame
            let hand = mouse
            if hypot(v.dx, v.dy) < 900, hand.x - vf.minX < 36 || vf.maxX - hand.x < 36 {
                startPeek(side: hand.x - vf.minX < 36 ? -1 : 1, y: flyPos.y)
                NSCursor.openHand.set()
                return
            }
            flyLedges = onTop ? ledges() : []
            state = .flying
            NSCursor.openHand.set()
            return
        }
        NSCursor.openHand.set()
        // A click: wake up, or stop walking and look happy.
        if isPeeking { leavePeek(); return }
        switch state {
        case .sleeping, .lyingDown, .loafing, .dozing:
            wokenAt = Date()
            wake()
        case .walking(_, .sit), .standingUp(_, _, .sit): stopWalking(sitFor: TimeInterval.random(in: 60...180))
        case .sitting:
            if Int.random(in: 0..<3) == 0 { play([(.meow, 0.5), (.neutral, 0.15)]); showBubble("喵～", seconds: 1.6) }
            else { play([(.happy, 1.2)]) }
        default: break
        }
        render()
    }

    // MARK: mouse: bowl (click = "I drank", drag = move it along the floor)

    private func bowlMouseDown(_ event: NSEvent) {
        bowlDragOffset = NSEvent.mouseLocation.x - bowlX
        bowlDragMoved = false
    }

    private func bowlMouseDragged(_ event: NSEvent) {
        if isDrinking { return }
        bowlDragMoved = true
        let vf = currentScreen.visibleFrame
        bowlX = min(max(NSEvent.mouseLocation.x - bowlDragOffset, vf.minX), vf.maxX - Self.bowlWidth * scale)
        layoutBowl()
    }

    private func bowlMouseUp(_ event: NSEvent) {
        if bowlDragMoved { UserDefaults.standard.set(Double(bowlX), forKey: "bowlX"); return }
        refill()
    }
}

extension PetController {
    /// Test: the reminder (cat asks by its empty bowl), then "drank it, fill it" after 9 s.
    func runWaterTest() {
        goDrink()
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in self?.refill() }
    }

    /// Test: fall asleep now, then get woken by a click after `wakeAfter` seconds.
    func runSleepTest(wakeAfter: TimeInterval) {
        goToSleep()
        DispatchQueue.main.asyncAfter(deadline: .now() + wakeAfter) { [weak self] in
            self?.dragMoved = false
            self?.mouseUp(NSEvent())
        }
    }

    /// Demo: every new move in a row, each announced in a bubble first.
    func runDemo() {
        var t: TimeInterval = 0
        func at(_ d: TimeInterval, _ label: String, _ run: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.showBubble(label, seconds: 2) }
            DispatchQueue.main.asyncAfter(deadline: .now() + d + 2.2) { run() }
        }
        at(t, "① 舔爪洗脸，然后蹭蹭你的手") { [weak self] in self?.groomNow() }
        t += 2.2 + Double(groomSequence.count) * Self.tick + 1 + 6.5
        let lieT = 3.5 + ["knead", "liegroom", "belly"].reduce(0.0) { $0 + Double(lieClipSequence($1).count) * Self.tick + 1.5 }
        at(t, "② 趴下：踩奶 → 舔爪 → 翻肚皮") { [weak self] in self?.runLieClipTest() }
        t += 2.2 + lieT + 4
        at(t, "③ 团成一团睡，一会儿醒来") { [weak self] in self?.runCurlTest(wakeAfter: 11) }
        t += 2.2 + 11 + 5
        at(t, "④ 跑酷！") { [weak self] in self?.zoomies() }
        t += 2.2 + 7
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.showBubble("演示完啦～", seconds: 2.5) }
    }

    /// Test: a full wash, then being stroked (rubbing against the hand) for a few seconds.
    func groomNow() {
        state = .grooming(0)
        let after = Double(groomSequence.count) * Self.tick + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
            guard let self else { return }
            self.state = .petted(since: Date()); self.petFrameTick = 0
            for k in 0..<12 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.5) { [weak self] in self?.lastPetMove = Date() } }
        }
    }

    /// Test: lie down, then knead, lick a paw and roll onto the back in turn; then sit up.
    func runLieClipTest() {
        lieDown()
        var t: TimeInterval = 3.5
        for name in ["knead", "liegroom", "belly"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self, case .loafing = self.state else { return }
                self.loafTailTick = nil; self.lieClip = (name, 0)
            }
            t += Double(lieClipSequence(name).count) * Self.tick + 1.5
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.wake() }
    }

    /// Test: lie down and fall asleep curled up; wake after `wakeAfter` seconds.
    func runCurlTest(wakeAfter: TimeInterval) {
        lieDown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, case .loafing = self.state else { return }
            self.curledSleep = true; self.state = .dozing(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + wakeAfter) { [weak self] in self?.wake() }
    }

    /// Scripted pick-up, swing and throw, for checking the physics without a real mouse.
    /// Scripted red-dot play: the dot sweeps along the floor near the cat for a while.
    func runPlayTest() {
        let vf = (window.screen ?? NSScreen.main!).visibleFrame
        let x0 = window.frame.midX
        playMode = true
        let t0 = Date()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = Date().timeIntervalSince(t0)
            if t > 20 { timer.invalidate(); self.cursorOverride = nil; self.playMode = false; return }
            // far away (chase), still nearby (stalk + pounce), dart off (chase), still again
            let x: CGFloat = t < 6 ? x0 + 300 : (t < 13 ? x0 + 300 : x0 - 150)
            let y: CGFloat = t < 6 ? vf.minY + 30 : (t < 13 ? vf.minY + 240 : vf.minY + 700)
            self.cursorOverride = CGPoint(x: x, y: y)
        }
    }

    /// Test: play each idle clip once, then a glance and a zoomies run.
    func runClipTest() {
        var t = 1.0
        for name in ["scratch", "sneeze", "swat", "ear", "headshake"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.sitUntil = Date().addingTimeInterval(60); self?.state = .clip(name, 0) }
            t += 3.5
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.glanceAround() }
        DispatchQueue.main.asyncAfter(deadline: .now() + t + 4) { [weak self] in self?.zoomies() }
    }

    /// Scripted cursor circling near the cat's head, for the head-turn logic.
    /// Test hook: three stroking spells over the sitting cat, a few seconds apart.
    func runPetTest() {
        sit(for: 120)
        let t0 = Date()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = Date().timeIntervalSince(t0)
            if t > 40 { timer.invalidate(); self.cursorOverride = nil; return }
            let f = self.window.frame
            let spell = t.truncatingRemainder(dividingBy: 8)
            if t < 24 && spell < 3 {
                self.cursorOverride = CGPoint(x: f.midX + 18 * self.scale * CGFloat(sin(t * 9)), y: f.minY + 50 * self.scale)
            } else {
                self.cursorOverride = CGPoint(x: f.midX + 400, y: f.minY + 300)
            }
        }
    }

    /// Test hook: wave the cursor left and right in front of the sitting cat.
    func runDizzyTest() {
        sit(for: 120)
        let t0 = Date()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = Date().timeIntervalSince(t0)
            if t > 20 { timer.invalidate(); self.cursorOverride = nil; return }
            let f = self.window.frame
            let c = CGPoint(x: f.minX + 34 * self.scale, y: f.minY + 130 * self.scale)
            self.cursorOverride = t < 12 ? CGPoint(x: c.x + 150 * self.scale * CGFloat(sin(t * 5)), y: c.y) : CGPoint(x: c.x + 600, y: c.y + 400)
        }
    }

    /// Test hook: go up onto a window now, lie there, then come down.
    func runPerchTest() {
        sit(for: 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            print("ledges", self.ledges().map { "\(Int($0.top)) \(Int($0.minX))-\(Int($0.maxX))" })
            if !self.goPerch() { print("no ledge") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
            guard let self, self.perch != nil else { return }
            self.restOnly = true; self.lieDown()
        }
    }

    /// Test hook: drop it at the right edge, then the left, with the cursor coming close once.
    func runPeekTest() {
        let vf = currentScreen.visibleFrame
        startPeek(side: 1, y: vf.minY + 200)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.cursorOverride = CGPoint(x: vf.maxX - 40, y: vf.minY + 290) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in self?.cursorOverride = CGPoint(x: vf.midX, y: vf.midY) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 11) { [weak self] in self?.startPeek(side: -1, y: vf.minY + 120) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in self?.goDrink(); print("bubble:", self?.bubble.isVisible ?? false) }
    }

    func runLookTest() {
        sit(for: 60)
        let f = window.frame
        let c = CGPoint(x: f.minX + 34 * scale, y: f.minY + 88 * scale)
        let t0 = Date()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = Date().timeIntervalSince(t0)
            if t > 14 { timer.invalidate(); self.cursorOverride = nil; return }
            // sweep over the top: left -> up -> right, then back right -> up -> left, then rest
            let a = (t < 6 ? t / 6 : max(0, 1 - (t - 6) / 6)) * .pi
            let r: CGFloat = 200
            self.cursorOverride = t < 12 ? CGPoint(x: c.x - r * CGFloat(cos(a)), y: c.y + 30 + r * CGFloat(sin(a))) : self.cursorOverride
        }
    }

    func runLiftTest() {
        let vf = (window.screen ?? NSScreen.main!).visibleFrame
        let start = CGPoint(x: window.frame.midX, y: vf.minY + 250)
        cursorOverride = start
        mouseDown(NSEvent())
        let t0 = Date()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = Date().timeIntervalSince(t0)
            if t < 4 {
                let x = start.x + 160 * CGFloat(sin(t * 2.4)) * CGFloat(min(1, t))
                self.cursorOverride = CGPoint(x: x, y: start.y + 60 * CGFloat(min(1, t)))
                self.mouseDragged(NSEvent())
            } else if t < 4.25 {
                self.cursorOverride = CGPoint(x: self.cursorOverride!.x + 22, y: self.cursorOverride!.y + 14)
                self.mouseDragged(NSEvent())
            } else {
                timer.invalidate()
                self.mouseUp(NSEvent())
                self.cursorOverride = nil
            }
        }
    }
}

// MARK: - Tail swish, petting, play with a red dot, feeding a shrimp

extension PetController {
    var tailSequence: [Int] { let n = sprites.tail.count; return n == 0 ? [] : Self.slow(n, 2) + Self.slow(n, 2).reversed() }
    // Eyes shut, chin slowly up, hold, slowly down.
    /// Petted: rubs the head against the hand, side to side (ping-pong through the frames).
    var rubSequence: [Int] {
        let n = sprites.rub.count
        if n < 2 { return [0] }
        if n < 4 { return [0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0] }
        return Self.slow(n, 2) + Array((1..<(n - 1)).reversed()).flatMap { [$0, $0] }
    }
    var crouchSequence: [Int] {
        let n = sprites.crouch.count
        guard n > 0 else { return [] }
        // Settle into the crouch, then wiggle a few times on the last frames.
        let wiggle = n >= 2 ? Array(repeating: [n - 2, n - 2, n - 1, n - 1], count: 3).flatMap { $0 } : []
        return Self.slow(n, 2) + wiggle
    }
    var pounceSequence: [Int] { Self.slow(sprites.pounce.count, 2) }
    var shakeSequence: [Int] { Self.slow(sprites.shake.count, 1) }
    // Eat clip: approach, sniff, pick up, chew a few times, done.
    static let eatSequence: [Int] = [0, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 6, 6, 7, 7, 8, 8, 8, 8]
    // The real shrimp sits where the clip's cat picks it up (x 39 in the 176 canvas); eat-1..4 have no shrimp drawn.
    static let eatShrimpX: CGFloat = 39, eatShrimpWidth: CGFloat = 26, eatCatOffset: CGFloat = 44, eatEndShift: CGFloat = -10
    static let eatPickupFrame = 4

    // MARK: petting: stroke the cat with the cursor (no click needed)

    /// Test: one petting spell as if stroked with the cursor (sitting cat), with the stroke kept going for a bit.
    func runPetOnce() {
        guard case .sitting = state else { return }
        petMeter = 0
        lastPetMove = Date()
        for k in 1..<8 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.5) { [weak self] in self?.lastPetMove = Date() } }
        if petSessionStarted() { return }
        reactToPetting()
    }

    func updatePetting() {
        let p = mouse
        defer { lastPetPoint = cursorOverCat ? p : nil }
        guard cursorOverCat, let last = lastPetPoint else { petMeter = max(0, petMeter - 2); return }
        let d = hypot(p.x - last.x, p.y - last.y)
        if d > 0.5 { lastPetMove = Date() }
        petMeter = max(0, petMeter + d - 1.5)
        guard petMeter > 140 * scale else { return }
        switch state {
        case .sitting, .tailFlick:
            petMeter = 0
            if petSessionStarted() { return }
            reactToPetting()
        case .loafing, .sleeping, .dozing:
            petMeter = 0
            // One spell per few seconds of stroking, however long the stroke goes on.
            guard Date().timeIntervalSince(lastPetSession) > 4 else { lastPetSession = Date(); return }
            if petSessionStarted() { return }
            if case .loafing = state {
                play([(.closed, 2.0)])
                gainAffection(.pet, delay: 2.5)
                // The more it likes you, the more often it kneads or rolls onto its back; otherwise it just purrs.
                let r = Int.random(in: 0..<100)
                let clip: String? = r < affection.bellyWhenLyingChance ? "belly"
                                  : r < affection.bellyWhenLyingChance + affection.kneadWhenLyingChance ? "knead" : nil
                if let clip, lieClip == nil, sprites.lieClips[clip] != nil { lieClip = (clip, 0); loafTailTick = nil }
            }
            sleepPetUntil = Date().addingTimeInterval(2.5)
            showBubble(Bool.random() ? "呼噜…" : "呼噜呼噜…", seconds: 2)
        default: break
        }
    }

    /// Adds affection; on a new step the cat says so with hearts. Returns false when today's cap was reached.
    @discardableResult
    func gainAffection(_ source: Affection.Source, delay: TimeInterval) -> Bool {
        let g = affection.add(source)
        if g.counted { onChange?() }
        if let lv = g.levelUp {
            let lines = [1: ["我们好像熟一点了～", "我开始喜欢你啦"], 2: ["我好像更喜欢你了！", "和你待着好舒服"],
                         3: ["最想黏着你了～", "离不开你啦"], 4: ["最最喜欢你啦！", "你是我最喜欢的人！"]]
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.showBubble(lines[lv]?.randomElement() ?? "喜欢你～", seconds: 3)
                self?.heartsUntil = Date().addingTimeInterval(2.5)
                self?.play([(.happy, 2.0)])
            }
        }
        return g.counted
    }

    /// Counts a petting spell. The third one within a few minutes is too much: it gets a bit cross,
    /// walks off somewhere else and lies down again. Returns true when that happened.
    private func petSessionStarted() -> Bool {
        let now = Date()
        lastPetSession = now
        petSessions = petSessions.filter { now.timeIntervalSince($0) < 300 } + [now]
        guard petSessions.count >= affection.walkOffLimit else { return false }
        petSessions = []
        showBubble(["喵…别摸啦", "够了够了", "哼，换个地方睡"].randomElement()!, seconds: 2.2)
        switch state {
        case .sleeping, .dozing, .loafing, .lyingDown:
            moveAwayAfterWake = true
            wake()
        default:
            play([(.slit, 1.0)])
            state = .tailFlick(0)        // a cross flick of the tail first
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.walkAwayToNap() }
        }
        return true
    }

    /// Walk to a spot well away from here (and from the cursor), then lie down and sleep.
    private func walkAwayToNap() {
        if perch != nil || isLeaping || isPeeking { whenOnFloor { [weak self] in self?.walkAwayToNap() }; return }
        if paused { napAfterSit = true; sit(for: 0.8); return }      // told to stay put: lies down right here
        let vf = currentScreen.visibleFrame
        let w = Self.canvas * scale
        let lo = vf.minX + 20, hi = vf.maxX - w - 20
        let away = catX > vf.midX ? CGFloat.random(in: lo...max(lo, catX - 320 * scale))
                                  : CGFloat.random(in: min(hi, catX + 320 * scale)...hi)
        play([(.slit, 0.8)])
        startWalking(to: away, then: .nap)
    }

    /// Being petted while awake: mostly purring, but sometimes it stretches, gives the spot a lick,
    /// or just squints happily and meows.
    private func reactToPetting() {
        gainAffection(.pet, delay: 2.8)
        // The more it likes you, the more often it flops down to knead or show its belly.
        if Int.random(in: 0..<100) < affection.cuddleChance, perch == nil, !sprites.lieClips.isEmpty, !sprites.lie.isEmpty {
            showBubble(["呼噜…最喜欢你了", "呼噜呼噜～"].randomElement()!, seconds: 2)
            pendingLieClip = Bool.random() ? "belly" : "knead"
            restOnly = true
            lieDown()
            return
        }
        let r = Int.random(in: 0..<20)
        if r < 11 || sprites.rub.isEmpty && r < 14 {
            state = .petted(since: Date()); petFrameTick = 0; faceQueue = []
            showBubble(["呼噜呼噜～", "呼噜～", "咕噜咕噜～"].randomElement()!, seconds: 2.5)
        } else if r < 15, !sprites.stretch.isEmpty {
            showBubble("嗯～", seconds: 1.6)
            stretchNow()
        } else if r < 18, !sprites.groom.isEmpty {
            play([(.happy, 0.8)])
            state = .grooming(0)                   // tidies the fur where it was touched
        } else {
            play([(.happy, 1.2), (.meow, 0.4), (.happy, 0.8)])
            showBubble("喵～", seconds: 1.6)
            heartsUntil = Date().addingTimeInterval(0.6)
        }
    }

    // MARK: play: a red dot follows the cursor; the cat chases, crouches and pounces

    func playModeChanged() {
        if playMode, perch != nil { hopDown() }
        if playMode, isPeeking { leavePeek() }
        if playMode {
            toyView.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
            toyWindow.ignoresMouseEvents = true
            toyWindow.level = .floating
            if let img = Self.redDot() { toyView.show(image: img, size: CGSize(width: 12, height: 12), anchor: CGPoint(x: 0.5, y: 0.5), at: CGPoint(x: 6, y: 6), mirrored: false) }
            toyWindow.orderFrontRegardless()
            playLastMove = Date()
            switch state { case .sleeping, .lyingDown, .loafing, .dozing: wake(); default: break }
            showBubble("移动鼠标，红点会跟着跑\n右键一下就收起", seconds: 4)
            strikePoint = nil
            let stop: (NSEvent) -> Void = { [weak self] _ in DispatchQueue.main.async { self?.playMode = false } }
            if let g = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown, handler: stop) { playMonitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown, handler: { e in stop(e); return nil }) { playMonitors.append(l) }
        } else {
            playMonitors.forEach { NSEvent.removeMonitor($0) }
            playMonitors = []
            toyWindow.orderOut(nil)
            switch state {
            case .walking(_, .play), .crouching, .standingUp(_, _, .play): stopWalking(sitFor: 60)
            default: break
            }
        }
        onChange?()
    }

    static func redDot() -> CGImage? {
        let w = 12, h = 12
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let d = hypot(Double(x) - 5.5, Double(y) - 5.5)
            let i = (y * w + x) * 4
            if d <= 2.6 { px[i] = 255; px[i+1] = 40; px[i+2] = 40; px[i+3] = 255 }
            else if d <= 4.2 { px[i] = 255; px[i+1] = 70; px[i+2] = 70; px[i+3] = 140 }
            else if d <= 5.8 { px[i] = 255; px[i+1] = 90; px[i+2] = 90; px[i+3] = 50 }
            if d <= 1.0 { px[i] = 255; px[i+1] = 200; px[i+2] = 200 }
            // premultiply
            let a = Double(px[i+3]) / 255
            px[i] = UInt8(Double(px[i]) * a); px[i+1] = UInt8(Double(px[i+1]) * a); px[i+2] = UInt8(Double(px[i+2]) * a)
        } }
        return px.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    /// x of the cat's face on screen (the front of the body).
    var faceX: CGFloat { facingRight ? catX + (Self.canvas - 20) * scale : catX + 20 * scale }

    /// The red dot follows the cursor anywhere on screen.
    var dotPoint: CGPoint { mouse }
    /// How high a standing cat reaches with its front paws, above the ground line.
    var reach: CGFloat { 104 * scale }

    func updatePlay(dt: CGFloat) {
        guard playMode else { return }
        let dot = dotPoint
        toyWindow.setFrameOrigin(CGPoint(x: dot.x - 6, y: dot.y - 6))
        if hypot(dot.x - playLastPoint.x, dot.y - playLastPoint.y) > 2 { playLastMove = Date(); playLastPoint = dot }
        if Date().timeIntervalSince(playLastMove) > 45 { playMode = false; return }    // bored: game over
        let height = dot.y - (groundY + 4 * scale)        // above the floor
        let still = Date().timeIntervalSince(playLastMove) > 0.35
        // Already went for the dot here: lose interest until it moves somewhere new.
        if let sp = strikePoint {
            if hypot(dot.x - sp.x, dot.y - sp.y) > 80 * scale { strikePoint = nil }
            else {
                if case .sitting = state, !walkedAwayFromStrike {
                    walkedAwayFromStrike = true
                    let vf = currentScreen.visibleFrame
                    let away: CGFloat = (dot.x > catX + Self.canvas * scale / 2 ? -1 : 1) * CGFloat.random(in: 250...400) * scale
                    let target = min(max(catX + away, vf.minX + 10), vf.maxX - Self.canvas * scale - 10)
                    startWalking(to: target, then: .sit)
                }
                return
            }
        }
        let centerX = catX + Self.canvas * scale / 2
        let dxCenter = dot.x - centerX
        let dx = dot.x - faceX
        switch state {
        case .sitting:
            if height < 50 * scale {
                // On the floor: chase, stalk, pounce.
                if abs(dx) > 150 * scale { startWalking(to: chaseTarget(dot.x), then: .play) }
                else if still { facingRight = dx > 0; startCrouch() }
                else { facingRight = dx > 0 }
            } else if height < reach + 270 * scale {
                // In the air but reachable: get under it, then jump for it.
                if abs(dxCenter) > 50 * scale { startWalking(to: dot.x - Self.canvas * scale / 2, then: .play) }
                else if still { startJump(to: height) }
            } else {
                // Too high: watch, hop now and then.
                facingRight = dxCenter > 0
                if abs(dxCenter) > 120 * scale { startWalking(to: dot.x - Self.canvas * scale / 2, then: .play) }
                else if still, Int.random(in: 0..<90) == 0 {
                    startJump(to: reach + 40 * scale)
                    if Int.random(in: 0..<2) == 0 { showBubble("够不着～", seconds: 1.5) }
                }
            }
        case .walking(_, .play):
            let target = height < 50 * scale ? chaseTarget(dot.x) : dot.x - Self.canvas * scale / 2
            state = .walking(targetX: target, then: .play)                       // keep steering
        case .crouching:
            if abs(dx) > 220 * scale || height > 80 * scale { sit(for: 0.3) }    // it got away
        default: break
        }
    }

    /// Jump straight up so the paws reach `height` above the floor.
    func startJump(to height: CGFloat) {
        let rise = max(18 * scale, min(270 * scale, height - reach))
        let g: CGFloat = 2600 * scale
        state = .jumping(tick: 0, vy: sqrt(2 * g * rise), y: 0, caught: false)
        faceQueue = []
    }

    // Jump timeline in 60 Hz ticks: 0..<12 crouch, then flight, then 1000+ = landed and holding.
    static let jumpCrouchTicks = 12, jumpLanded = 1000

    func physicsJump(dt: CGFloat) {
        guard case .jumping(var tick, var vy, var y, var caught) = state else { return }
        tick += 1
        let g: CGFloat = 2600 * scale
        if tick >= Self.jumpLanded {
            if tick > Self.jumpLanded + 10 {
                if playMode { strikePoint = dotPoint; walkedAwayFromStrike = false }
                state = .sittingDown(0, sitFor: playMode ? 1.0 : 30)
                if caught { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.play([(.happy, 0.9)]) } }
                render(); return
            }
        } else if tick > Self.jumpCrouchTicks {
            vy -= g * dt
            y += vy * dt
            // Paws near the dot around the top of the jump: got it.
            if playMode, abs(vy) < 320 * scale {
                let paw = CGPoint(x: catX + Self.canvas * scale / 2, y: groundY + y + reach)
                if hypot(dotPoint.x - paw.x, dotPoint.y - paw.y) < 45 * scale { caught = true }
            }
            if y <= 0 { y = 0; vy = 0; tick = Self.jumpLanded }
        }
        state = .jumping(tick: tick, vy: vy, y: y, caught: caught)
        render()
    }

    /// Stand so the cat's face ends up a little short of the dot.
    func chaseTarget(_ x: CGFloat) -> CGFloat {
        // faceX = catX + 108 (facing right) or catX + 20 (facing left); stop 50 px short of the dot.
        let right = x > faceX
        return right ? x - (Self.canvas - 20 + 50) * scale : x + (50 - 20) * scale
    }

    func startCrouch() {
        guard !sprites.crouch.isEmpty else { startPounce(); return }
        state = .crouching(0)
    }

    func startPounce() {
        guard !sprites.pounce.isEmpty else { sit(for: 2); return }
        let target = playMode ? dotPoint.x : faceX + (facingRight ? 60 : -60) * scale
        let vf = currentScreen.visibleFrame
        // Leap so the paws land on the dot, at most a short distance.
        var jump = target - faceX
        jump = max(-90 * scale, min(90 * scale, jump))
        let toX = min(max(catX + jump, vf.minX), vf.maxX - Self.canvas * scale)
        state = .pouncing(0, fromX: catX, toX: toX)
    }

    // MARK: feeding a shrimp

    var eatOriginX: CGFloat {
        facingRight ? shrimpX - (176 - Self.eatShrimpX - Self.eatShrimpWidth) * scale : shrimpX - Self.eatShrimpX * scale
    }
    var eatStartCatX: CGFloat {
        facingRight ? eatOriginX + (176 - Self.eatCatOffset - Self.canvas) * scale : eatOriginX + Self.eatCatOffset * scale
    }

    /// Pick up a shrimp: it sticks to the cursor until you click where it should land.
    func feedShrimp() {
        if shrimpOnFloor || shrimpFalling || shrimpHeld { return }
        shrimpHeld = true
        shrimpHeldSince = Date()
        shrimpView.frame = CGRect(x: 0, y: 0, width: 26 * scale, height: 19 * scale)
        shrimpView.show(sprites.shrimp, mirrored: false)
        shrimpView.onMouseDown = { [weak self] _ in self?.dropShrimp() }
        shrimpView.onMouseUp = { [weak self] _ in self?.dropShrimp() }
        shrimpWindow.ignoresMouseEvents = false
        shrimpWindow.level = .floating
        followCursorWithShrimp()
        shrimpWindow.alphaValue = 1
        shrimpWindow.orderFrontRegardless()
        showBubble("把虾放到地上给我吧～\n移到想放的地方点一下", seconds: 3)
    }

    private func followCursorWithShrimp() {
        let p = mouse
        shrimpX = p.x - 13 * scale
        shrimpY = p.y - 9 * scale
        shrimpWindow.setFrame(CGRect(x: shrimpX, y: shrimpY, width: 26 * scale, height: 19 * scale), display: false)
    }

    /// Let go of the shrimp where it is; it falls to the floor and the cat goes for it.
    func dropShrimp() {
        guard shrimpHeld else { return }
        shrimpHeld = false
        shrimpWindow.ignoresMouseEvents = true
        shrimpWindow.level = levelValue
        let here = NSScreen.screens.first { $0.frame.contains(mouse) } ?? currentScreen
        let vf = here.visibleFrame
        shrimpX = min(max(shrimpX, vf.minX + 2), vf.maxX - 28 * scale)
        shrimpVY = 0
        shrimpFalling = true
        switch state { case .sleeping, .lyingDown, .loafing, .dozing: wake(); default: break }
        play([(.wide, 1.5)])
    }

    func updateShrimp(dt: CGFloat) {
        if shrimpHeld {
            followCursorWithShrimp()
            if Date().timeIntervalSince(shrimpHeldSince) > 20 { shrimpHeld = false; shrimpWindow.orderOut(nil) }   // put it away
            return
        }
        guard shrimpFalling else { return }
        // Land on the floor of whichever screen the shrimp is over.
        let here = NSScreen.screens.first { $0.frame.minX <= shrimpX && shrimpX < $0.frame.maxX } ?? currentScreen
        let floor = here.visibleFrame.minY + 1 * scale
        shrimpVY -= 2400 * dt
        shrimpY += shrimpVY * dt
        if shrimpY <= floor {
            shrimpY = floor
            if shrimpVY < -300 { shrimpVY = -shrimpVY * 0.25 } else {
                shrimpFalling = false
                shrimpOnFloor = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.goEat() }
            }
        }
        shrimpWindow.setFrameOrigin(CGPoint(x: shrimpX, y: shrimpY))
    }

    func goEat() {
        if perch != nil || isLeaping || isPeeking { whenOnFloor { [weak self] in self?.goEat() }; return }
        guard shrimpOnFloor else { return }
        switch state {
        case .held, .flying, .drinking, .eating, .landing: DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.goEat() }; return
        case .sleeping, .lyingDown, .loafing, .dozing, .wakingUp: DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.goEat() }; return
        default: break
        }
        facingRight = shrimpX > catX
        startWalking(to: eatStartCatX, then: .eat)
    }

    func finishEating() {
        shrimpOnFloor = false
        shrimpWindow.orderOut(nil)
        let shift = Self.eatEndShift * scale
        catX = eatStartCatX + (facingRight ? -shift : shift)
        state = .sittingDown(0, sitFor: TimeInterval.random(in: 60...150))
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.heartsUntil = Date().addingTimeInterval(1.6)
            let full = !self.gainAffection(.shrimp, delay: 2.4)
            self.showBubble(full ? ["好吃！今天吃饱啦～", "好吃！明天再喂我吧"].randomElement()! : "好吃！", seconds: 2)
            self.play([(.happy, 1.4), (.neutral, 0.4), (.lick, 0.16), (.neutral, 0.1), (.lick, 0.16)])
        }
    }
}

extension PetController {
    /// Right-click on the cat: quick actions right where the cat is.
    /// The pin button: keep on top of all windows, or stay down on the desktop behind them.
    func togglePin() {
        onTop.toggle()
        UserDefaults.standard.set(onTop, forKey: "onTop")
        onChange?()
        showBubble(onTop ? ["钉好啦，我就待在最前面～", "好，我在最前面陪你"].randomElement()!
                         : ["那我躲到窗口后面去咯", "我去桌面上待着～"].randomElement()!, seconds: 2.2)
    }

    func showActionBar() {
        if actionBar.isVisible { actionBar.dismiss(); return }      // right-click again to close
        bubble.orderOut(nil)
        let ui = sprites.ui
        let actions: [ActionBar.Action] = [
            .init(icon: ui["shrimp"]!, tip: "喂一只虾（点一下放下）") { [weak self] in self?.feedShrimp() },
            .init(icon: ui["toy"]!, tip: playMode ? "收起逗猫红点" : "逗猫：红点跟着鼠标") { [weak self] in self?.playMode.toggle() },
            .init(icon: ui["water"]!, tip: "我喝水了") { [weak self] in self?.refill() },
            .init(icon: (onTop ? ui["pin"] : ui["pin-off"]) ?? ui["gear"]!,
                  tip: onTop ? "钉在最前面啦（点一下躲到窗口后面）" : "把我钉到最前面") { [weak self] in self?.togglePin() },
        ]
        let f = window.frame
        // Just above the cat's head, never over it.
        let fr = currentFrame()
        let top = CGFloat(fr.height - fr.topRow) * scale
        actionBar.show(actions, close: ui["close"]!, above: CGRect(x: f.minX, y: f.minY, width: f.width, height: top + 2 * scale), level: .floating)
    }
}

// MARK: - Calendar alerts

extension PetController {
    /// An event is coming up: wake up, walk toward the middle of the screen, sit and tell you.
    func announce(_ alert: CalendarWatcher.Alert) {
        pendingAlert = alert
        switch state {
        case .held, .flying, .drinking, .eating, .landing, .peeking:
            showPendingAlert(); return
        case .sleeping, .lyingDown, .loafing, .dozing:
            wake()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.walkToAnnounce() }
        default:
            walkToAnnounce()
        }
    }

    private func walkToAnnounce() {
        if perch != nil || isLeaping || isPeeking { whenOnFloor { [weak self] in self?.walkToAnnounce() }; return }
        let vf = currentScreen.visibleFrame
        let center = vf.midX - Self.canvas * scale / 2
        if abs(center - catX) < 220 * scale { stopWalking(sitFor: 120); DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.showPendingAlert() } }
        else { startWalking(to: center, then: .announce) }
    }

    func showPendingAlert() {
        guard let a = pendingAlert else { return }
        pendingAlert = nil
        var title = a.title
        if title.count > 16 { title = String(title.prefix(15)) + "…" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let text: String
        switch a.moment {
        case .soon(let m): text = "\(m) 分钟后有日程（\(f.string(from: a.start))）\n「\(title)」"
        case .now: text = "日程开始啦\n「\(title)」"
        }
        var buttons: [BubbleWindow.Button] = []
        if let link = a.link { buttons.append(.init(title: "加入会议") { NSWorkspace.shared.open(link) }) }
        buttons.append(.init(title: "知道了") { [weak self] in self?.play([(.closed, 0.12)]) })
        play([(.wide, 3)])
        showBubble(text, seconds: 240, buttons: buttons)
    }
}

// MARK: - Window ledges: jump up onto the top edge of a window, walk and lie there, fall when it moves

extension PetController {
    var isLeaping: Bool { switch state { case .leaping, .climbing: return true; default: return false } }

    /// On-screen windows of other apps, front to back, in Cocoa screen coordinates.
    private func windowsFrontToBack() -> [(CGWindowID, CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let mainH = NSScreen.screens.first?.frame.maxY ?? 0
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [(CGWindowID, CGRect)] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
            out.append((id, CGRect(x: b.minX, y: mainH - b.maxY, width: b.width, height: b.height)))
        }
        return out
    }

    /// Top edges on this screen the cat could stand on: visible (nothing in front of the edge or just
    /// above it), with room above for the cat, and wide enough to walk a little.
    func ledges() -> [Perch] {
        let vf = currentScreen.visibleFrame
        let wins = windowsFrontToBack()
        let catH = 112 * scale, minRun = 150 * scale
        var result: [Perch] = []
        for (i, (id, r)) in wins.enumerated() {
            let top = r.maxY
            guard r.width >= 200, r.height >= 80, top > vf.minY + 110 * scale, top < vf.maxY - catH,
                  r.minX < vf.maxX, r.maxX > vf.minX else { continue }
            let front = wins[..<i].map { $0.1 }
            // Walk along the edge in 6 pt steps; keep the longest stretch that is not covered.
            var best: (CGFloat, CGFloat)? = nil
            var runStart: CGFloat?
            var x = max(r.minX, vf.minX) + 8
            let end = min(r.maxX, vf.maxX) - 8
            while x <= end {
                let p1 = CGPoint(x: x, y: top - 3), p2 = CGPoint(x: x, y: top + 30 * scale), p3 = CGPoint(x: x, y: top + catH * 0.8)
                let clear = !front.contains { $0.contains(p1) || $0.contains(p2) || $0.contains(p3) }
                if clear { if runStart == nil { runStart = x } }
                if !clear || x + 6 > end, let s = runStart {
                    let e = clear ? x : x - 6
                    if e - s >= minRun, e - s > (best.map { $0.1 - $0.0 } ?? 0) { best = (s, e) }
                    runStart = nil
                }
                x += 6
            }
            if let (s, e) = best { result.append(Perch(id: id, top: top, minX: s, maxX: e, windowFrame: r)) }
        }
        return result
    }

    /// Pick a ledge and walk to a spot below it; the jump follows on arrival. False if there is none.
    @discardableResult
    func goPerch() -> Bool {
        guard onTop, sprites.jump.count >= 6, let ledge = ledges().first(where: { $0.top - floorY < 900 * scale }) else { return false }
        let w = Self.canvas * scale
        let vf = currentScreen.visibleFrame
        let landX = CGFloat.random(in: (ledge.minX - 20 * scale)...max(ledge.minX - 20 * scale, ledge.maxX - w + 20 * scale))
        // Take off a little to the side, so the jump is an arc rather than straight up.
        let side: CGFloat = landX + w / 2 > vf.midX ? -1 : 1
        let high = ledge.top - floorY > Self.climbAbove * scale && sprites.climbUp.count >= 8 && sprites.climbLaunch.count >= 2
        let launch = high ? landX : min(max(landX + side * 70 * scale, vf.minX), vf.maxX - w)
        pendingPerch = ledge
        pendingLandX = landX
        startWalking(to: launch, then: .leap)
        return true
    }

    func leapOntoPending() {
        guard let p = pendingPerch, let fresh = ledges().first(where: { $0.id == p.id }), abs(fresh.top - p.top) < 2 else {
            pendingPerch = nil; stopWalking(sitFor: .random(in: 30...90)); return
        }
        pendingPerch = fresh
        let landX = min(max(pendingLandX, fresh.minX - 20 * scale), fresh.maxX - Self.canvas * scale + 20 * scale)
        if fresh.top - floorY > Self.climbAbove * scale && sprites.climbUp.count >= 8 && sprites.climbLaunch.count >= 2 {
            faceQueue = []; face = .neutral; lookPose = ""; bubble.orderOut(nil)
            state = .climbing(tick: 0, x: catX, top: fresh.top)
            return
        }
        facingRight = landX > catX
        startLeap(from: CGPoint(x: catX, y: floorY), to: CGPoint(x: landX, y: fresh.top - Self.perchSink * scale), up: true)
    }

    private func startLeap(from: CGPoint, to: CGPoint, up: Bool) {
        let dy = abs(to.y - from.y)
        let seconds = min(1.0, max(0.42, 0.32 + Double(dy) / 900))
        faceQueue = []; face = .neutral; lookPose = ""; bubble.orderOut(nil)
        leapPos = from
        state = .leaping(tick: 0, from: from, to: to, ticks: Int(seconds * 60), up: up)
    }

    /// 60 Hz: crouch, then a ballistic-looking arc to the target.
    func physicsLeap() {
        guard case .leaping(var tick, let from, let to, let ticks, let up) = state else { return }
        tick += 1
        let flight = tick - Self.jumpCrouchTicks
        if flight >= ticks {
            flyPos = to
            if up {
                perch = pendingPerch; pendingPerch = nil
                land(impact: 700)
            } else {
                perch = nil
                land(impact: 1300)
            }
            return
        }
        if flight > 0 {
            let u = CGFloat(flight) / CGFloat(ticks)
            let arc = (up ? 46 : 22) * scale * 4 * u * (1 - u)
            // Ease the vertical a bit: quick rise, hang near the top, drop at the end.
            let v = up ? 1 - pow(1 - u, 2) : u * u
            leapPos = CGPoint(x: from.x + (to.x - from.x) * u, y: from.y + (to.y - from.y) * v + arc)
        } else {
            leapPos = from
        }
        state = .leaping(tick: tick, from: from, to: to, ticks: ticks, up: up)
        render()
    }

    /// Jump down from the ledge to the floor, a little to the side.
    func hopDown() {
        guard let p = perch else { return }
        let vf = currentScreen.visibleFrame
        let w = Self.canvas * scale
        let dir: CGFloat = catX + w / 2 > vf.midX ? -1 : 1
        let to = CGPoint(x: min(max(catX + dir * 80 * scale, vf.minX), vf.maxX - w), y: floorY)
        facingRight = dir > 0
        _ = p
        let from = CGPoint(x: catX, y: groundY)
        perch = nil
        startLeap(from: from, to: to, up: false)
    }

    /// Run `action` once the cat is back on the floor.
    func whenOnFloor(_ action: @escaping () -> Void) {
        if isPeeking { afterLanding = action; leavePeek(); return }
        if isLeaping { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.whenOnFloor(action) }; return }
        guard perch != nil else { action(); return }
        afterLanding = action
        switch state {
        case .perchLying, .lyingDown, .loafing:
            state = .wakingUp(wakeFromLoafStart)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in self?.hopDown() }
        default: hopDown()
        }
    }

    /// What to do next while up on a window.
    func decideOnPerch() {
        if isBedtime || userIdle > 600 { whenOnFloor { [weak self] in self?.goToSleep() }; return }
        let r = Int.random(in: 0..<20)
        if r < 7 { restOnly = true; lieDown() }                          // lie on the edge, tail hanging down
        else if r < 12 { startWalking(to: nil, then: .sit) }              // stroll along the edge
        else if r < 17 { hopDown() }
        else { sit(for: .random(in: 30...90)) }
    }

    /// 10 Hz while perched: if the window moved, closed or got covered, the cat comes down.
    func checkPerch() {
        guard let p = perch else { return }
        switch state { case .held, .flying, .leaping, .landing: return; default: break }
        let wins = windowsFrontToBack()
        guard let idx = wins.firstIndex(where: { $0.0 == p.id }) else { fallFromPerch(); return }   // closed / minimised
        let r = wins[idx].1
        let mid = catX + Self.canvas * scale / 2
        if abs(r.maxY - p.top) > 1.5 || abs(r.minX - p.windowFrame.minX) > 1.5 || mid < r.minX - 10 || mid > r.maxX + 10 {
            fallFromPerch(); return                                          // the window moved away under it
        }
        // Another window came in front of where it is sitting: hop down.
        let spot = CGPoint(x: mid, y: p.top + 20 * scale)
        if wins[..<idx].contains(where: { $0.1.contains(spot) || $0.1.contains(CGPoint(x: mid, y: p.top - 3)) }) {
            whenOnFloor {}
        }
    }

    private func fallFromPerch() {
        guard perch != nil else { return }
        perch = nil
        bubble.orderOut(nil)
        flyPos = CGPoint(x: catX, y: window.frame.minY + (CGFloat(currentFrame().height) > Self.canvas ? (CGFloat(currentFrame().height) - Self.canvas) * scale : 0))
        velocity = CGVector(dx: 0, dy: 60)
        angle = 0; angularVelocity = 0
        flyLedges = onTop ? ledges() : []
        state = .flying
        if Bool.random() { showBubble("哇！", seconds: 1.2) }
    }

    // MARK: screen time is up -> it walks to the middle of the screen and lies down: have a rest

    func restInMiddle() {
        if isPeeking { askToStand(); return }
        if perch != nil || isLeaping || isPeeking { whenOnFloor { [weak self] in self?.restInMiddle() }; return }
        switch state {
        case .sleeping, .lyingDown, .loafing, .dozing:
            wake(); DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.restInMiddle() }; return
        default: break
        }
        let vf = currentScreen.visibleFrame
        let center = vf.midX - Self.canvas * scale / 2
        if abs(center - catX) < 40 * scale { restAfterSit = true; stopWalking(sitFor: 0.5) }
        else { startWalking(to: center, then: .rest) }
    }

    func askToRest() {
        let minutes = Int(Date().timeIntervalSince(activeSince) / 60)
        showBubble("已经用了 \(minutes) 分钟电脑啦\n歇一歇眼睛，起来走走吧", seconds: 300, buttons: [
            .init(title: "歇一下") { [weak self] in
                self?.resetStandTimer()
                self?.showBubble("好～我陪你歇会儿", seconds: 2.5)
            },
            .init(title: "等会儿") { [weak self] in
                guard let self else { return }
                self.standReminded = false
                self.activeSince = Date().addingTimeInterval(-(self.standInterval - 10 * 60))
                self.showBubble("好，10 分钟后再提醒你", seconds: 2.5)
                if case .loafing = self.state { self.state = .wakingUp(self.wakeFromLoafStart) }
            },
        ])
    }
}

// MARK: - Peeking from behind the screen edge (drop it at the left or right edge)

extension PetController {
    var isPeeking: Bool { if case .peeking = state { return true } else { return false } }

    func startPeek(side: CGFloat, y: CGFloat) {
        let vf = currentScreen.visibleFrame
        perch = nil
        bubble.orderOut(nil)
        facingRight = side < 0                  // the face points into the screen
        lookPose = ""; faceQueue = []; face = .neutral
        peekOut = 0.15; peekTarget = 0.15
        peekNextChange = Date().addingTimeInterval(0.6)            // a moment hidden, then out it comes
        cursorNearPeekSince = nil
        let py = min(max(y, vf.minY - 4 * scale), vf.maxY - 120 * scale)
        state = .peeking(side: side, y: py, until: .distantFuture)
        render()
    }

    /// Come out from behind the edge and drop to the floor.
    func leavePeek() {
        guard case .peeking(let side, let y, _) = state else { return }
        let vf = currentScreen.visibleFrame
        let w = Self.canvas * scale
        view.clips = false
        flyPos = CGPoint(x: side > 0 ? vf.maxX - w : vf.minX, y: y)
        velocity = CGVector(dx: -side * 160, dy: 260)
        angle = 0; angularVelocity = 0
        flyLedges = onTop ? ledges() : []
        state = .flying
    }

    /// 60 Hz: ease toward the target amount; hide when the cursor comes close, peek again when it leaves,
    /// and now and then pop back in for a second or lean a bit further out.
    func updatePeek(dt: CGFloat) {
        guard case .peeking(let side, let y, _) = state else { return }
        let vf = currentScreen.visibleFrame
        let edgeX = side > 0 ? vf.maxX : vf.minX
        let head = CGPoint(x: edgeX - side * 22 * scale, y: y + 90 * scale)
        let near = hypot(mouse.x - head.x, mouse.y - head.y) < 130 * scale
        let now = Date()
        if near {
            if cursorNearPeekSince == nil { cursorNearPeekSince = now }
            // Shy at first; if the cursor stays still nearby for a while it gets curious again.
            let still = now.timeIntervalSince(cursorMovedAt) > 1.2
            peekTarget = still && now.timeIntervalSince(cursorNearPeekSince!) > 2 ? 0.55 : (cursorOverCat ? 0.3 : 0.15)
            peekNextChange = now.addingTimeInterval(1.2)
        } else {
            cursorNearPeekSince = nil
            if now >= peekNextChange {
                let r = Int.random(in: 0..<10)
                if peekTarget < 0.5 { peekTarget = 1; play([(.wide, 0.5)]) }                       // out again
                else if r < 2 { peekTarget = 0.15; peekNextChange = now.addingTimeInterval(.random(in: 0.8...1.8)); return }  // ducks back
                else if r < 4 { peekTarget = 1.15 }                                                   // a bit further out
                else if r < 7 { peekTarget = 1; play([(.closed, 0.14)]) }                            // blink
                else { peekTarget = 0.9 }
                peekNextChange = now.addingTimeInterval(.random(in: 2.5...6))
            }
        }
        // Ducking in is quick, coming out is slow and careful.
        let k: CGFloat = peekTarget < peekOut ? 14 : 3.2
        peekOut += (peekTarget - peekOut) * min(1, dt * k)
        renderPeek(side: side, y: y)
    }

    /// Only the part of the cat past the screen edge is drawn; the head leans out a little.
    private func renderPeek(side: CGFloat, y: CGFloat) {
        let vf = currentScreen.visibleFrame
        let frame = currentFrame()
        let size = Self.canvas * scale
        let headLeft: CGFloat = 10                      // first head column in the sitting sprite
        let visible = (headLeft + 4 * peekOut) * scale  // the body stays behind the edge; the lean brings the head out
        let margin = 50 * scale                         // room for the lean
        let w = visible + margin
        let h = size + 10 * scale
        let rect = side > 0 ? CGRect(x: vf.maxX - w, y: y, width: w, height: h)
                            : CGRect(x: vf.minX, y: y, width: w, height: h)
        setWindow(rect)
        view.clips = true
        // Pivot where the body meets the edge, at the bottom; lean out by up to ~20 degrees, like peeking round a door.
        let pivotInView = CGPoint(x: side > 0 ? w : 0, y: 4 * scale)
        // Mirrored or not, the cut is `visible` points into the unflipped sprite (the head side).
        let anchor = CGPoint(x: visible / size, y: 0.03)
        let tilt = side * 0.36 * peekOut
        view.show(image: frame.image(night: isNight), size: CGSize(width: size, height: size), anchor: anchor,
                  at: pivotInView, mirrored: facingRight, rotation: tilt)
        setBowlVisible(bowlShown, animated: true)
    }
}

// MARK: - High ledges: spring up with the body stretched, hook the front paws over, scramble and pull up

extension PetController {
    /// Ledges higher than this (sprite px above the floor) are climbed rather than jumped in one arc.
    static let climbAbove: CGFloat = 260
    // Timeline in 60 Hz ticks.
    static let climbCrouch = 14, climbLaunchEnd = 34
    /// Hang and scramble, then pull up: (climbUp frame, ticks).
    static let climbSteps: [(Int, Int)] = [(0, 9), (1, 7), (0, 6), (1, 6), (2, 7), (3, 7), (4, 6), (5, 6), (6, 6), (7, 8)]
    static var climbTotal: Int { climbLaunchEnd + climbSteps.reduce(0) { $0 + $1.1 } }

    /// The frame for a tick, and which part of the climb it is (0 crouch, 1 launch, 2 on the edge).
    /// How far each climbUp frame sits lower than drawn, so the paws rest on the edge while hanging.
    static let climbSink: [CGFloat] = [13, 13, 10, 7, 4, 1, 0, 0]

    func climbFrame(_ tick: Int) -> (Frame, Int) {
        if tick < Self.climbCrouch { return (sprites.jump[tick < 7 ? 0 : 1], 0) }
        if tick < Self.climbLaunchEnd {
            let u = Double(tick - Self.climbCrouch) / Double(Self.climbLaunchEnd - Self.climbCrouch)
            return (sprites.climbLaunch[u < 0.45 ? 0 : 1], 1)
        }
        var t = tick - Self.climbLaunchEnd
        for (f, n) in Self.climbSteps { if t < n { return (sprites.climbUp[f], 2) }; t -= n }
        return (sprites.climbUp.last!, 2)
    }

    /// Bottom of the canvas on screen for a tick. `top` is the window's top edge.
    func climbOriginY(_ tick: Int, top: CGFloat) -> CGFloat {
        let feetOnEdge = top - (Self.perchSink - 6) * scale  // same spot the feet end up when standing on it
        let upOrigin = feetOnEdge - (256 - 122) * scale     // climbUp canvas: the edge is row 122
        let (_, part) = climbFrame(tick)
        switch part {
        case 0: return floorY
        case 1:
            // From standing on the floor to hanging with the paws at the edge (launch-2's paws: row 26 of 192;
            // climbUp-1's paws: row 105 of 256). Quick at first, slowing at the top.
            let hang = upOrigin + CGFloat((256 - 105) - (192 - 26) - Int(Self.climbSink[0])) * scale
            let u = CGFloat(tick - Self.climbCrouch) / CGFloat(Self.climbLaunchEnd - Self.climbCrouch)
            let e = 1 - (1 - u) * (1 - u)
            let start = floorY                              // feet 6 rows above the canvas bottom, as on the floor
            return start + (hang - start) * e
        default:
            var t = tick - Self.climbLaunchEnd, f = sprites.climbUp.count - 1
            for (i, n) in Self.climbSteps { if t < n { f = i; break }; t -= n }
            return upOrigin - Self.climbSink[min(f, Self.climbSink.count - 1)] * scale
        }
    }

    func physicsClimb() {
        guard case .climbing(var tick, let x, let top) = state else { return }
        tick += 1
        if tick >= Self.climbTotal {
            perch = pendingPerch; pendingPerch = nil
            catX = x
            sit(for: .random(in: 30...80))
            play([(.closed, 0.12), (.neutral, 0.3), (.closed, 0.12)])
            render()
            return
        }
        state = .climbing(tick: tick, x: x, top: top)
        render()
    }
}
