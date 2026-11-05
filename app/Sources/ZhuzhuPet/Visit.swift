import AppKit

/// Friends: pairing with a code, and "dropping by". There is only one 猪猪包, so a visit never brings
/// a second cat: the visitor's pixel hand (with their name) shows up next to the host's cat and pets
/// it, drops a shrimp, or waves hello. A cat hiding at the screen edge (peeking) is resting: no visits.
final class Social {
    let pet: PetController
    let friends: Friends
    private var hands: [String: VisitorHand] = [:]
    private(set) var visiting: String?          // the friend whose place I'm at
    private let bar = ActionBar()
    private var lastVisitAct = Date()
    private var heldReplies: [String] = []      // replies that came while my cat was hiding
    private var timer: Timer?

    var onChange: (() -> Void)?

    init(pet: PetController, friends: Friends) {
        self.pet = pet
        self.friends = friends
        friends.statusProvider = { [weak pet] in pet?.netStatus ?? "awake" }
        friends.onEvent = { [weak self] in self?.handle($0) }
        friends.onChange = { [weak self] in self?.onChange?() }
        pet.extraActions = { [weak self] in self?.barActions() ?? [] }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func say(_ text: String, _ seconds: TimeInterval = 3, buttons: [BubbleWindow.Button] = []) {
        pet.showBubble(text, seconds: seconds, buttons: buttons)
    }

    // MARK: pairing

    /// 添加小咪好友: the cat gets an invite link to send; the friend just opens it (nothing to type).
    func addFriend() {
        needName { [weak self] in
            self?.say("我去准备邀请链接…", 10)
            self?.friends.requestCode()
        }
    }

    /// Opened from an invite link (zhuzhubao://add/<code>): ask, then pair.
    func openInvite(code: String, from: String?) {
        let who = (from?.isEmpty == false) ? from! : "朋友"
        say("\(who)邀请你做小咪好友！\n要加吗？", 60, buttons: [
            .init(title: "好呀") { [weak self] in
                self?.needName {
                    self?.say("我去敲敲\(who)家的门…", 10)
                    self?.friends.redeem(code)
                }
            },
            .init(title: "算了") {},
        ])
    }

    func rename() { askName(first: false) }

    private func needName(_ then: @escaping () -> Void) {
        if friends.myName.isEmpty { askName(first: true, then: then) } else { then() }
    }

    private func askName(first: Bool, then: (() -> Void)? = nil) {
        pet.ask(first ? "先告诉我你叫什么吧～\n好友那边会看到这个名字" : "好友那边叫你什么好？", initial: friends.myName, maxLength: 8) { [weak self] name in
            guard let self, let name else { return }
            self.friends.myName = name
            if let then { then() } else { self.say("好，好友那边会看到「\(name)」～") }
            self.onChange?()
        }
    }

    func unpair(_ f: Friends.Friend) {
        say("真的要和\(f.display)解除小咪好友吗？", 30, buttons: [
            .init(title: "解除") { [weak self] in
                if self?.visiting == f.id { self?.endVisit() }
                self?.friends.unpair(f.id)
                self?.say("好吧…\(f.display)再见啦")
            },
            .init(title: "算了") {},
        ])
    }

    // MARK: visiting (my hand at a friend's place)

    /// The right-click bar: one 小咪好友 button, always there. No friends yet: add one. Otherwise the
    /// cat asks whose place to drop by (online friends), with 加好友 as the last choice.
    private func barActions() -> [ActionBar.Action] {
        guard let icon = pet.sprites.ui["friends"] else { return [] }
        let tip = friends.friends.isEmpty ? "添加小咪好友" : visiting != nil ? "小咪好友：回家 / 加好友" : "小咪好友：去串门 / 加好友"
        return [.init(icon: icon, tip: tip) { [weak self] in self?.friendsButton() }]
    }

    func testFriendsButton() { friendsButton() }

    private func friendsButton() {
        let all = friends.friends
        if all.isEmpty { addFriend(); return }
        let add = BubbleWindow.Button(title: "加好友") { [weak self] in self?.addFriend() }
        if let id = visiting, let f = friends.friend(id) {
            say("在\(f.display)家玩呢～", 20, buttons: [.init(title: "回家") { [weak self] in self?.leaveVisit() }, add])
            return
        }
        let open = all.filter(\.canVisit)
        if open.isEmpty {
            let why = all.count == 1 ? (all[0].online ? "\(all[0].display)在休息中" : "\(all[0].display)现在不在线")
                                     : (all.contains(where: \.online) ? "好友们都在休息中" : "好友们现在都不在线")
            say(why + "～", 20, buttons: [add, .init(title: "好") {}])
            return
        }
        say("去谁家串门？", 20, buttons: open.prefix(3).map { f in .init(title: f.display) { [weak self] in self?.startVisit(f) } } + [add])
    }

    func startVisit(_ f: Friends.Friend) {
        if !friends.connected && f.online == false {
            say("\(f.display)现在不在线哦"); return
        }
        guard f.canVisit else {
            say(f.online ? "\(f.display)在休息中，\n下次再去吧～" : "\(f.display)现在不在线哦"); return
        }
        if let v = visiting, v != f.id { leaveVisit(quiet: true) }
        if visiting == f.id { return }
        friends.visit(f.id, act: "enter")
    }

    func leaveVisit(quiet: Bool = false) {
        guard let id = visiting else { return }
        friends.visit(id, act: "leave")
        endVisit()
        if !quiet { say(["回家啦～", "串完门回来啦～"].randomElement()!, 2) }
    }

    private func endVisit() {
        visiting = nil
        bar.dismiss()
        onChange?()
    }

    private func act(_ act: String, text: String? = nil) {
        guard let id = visiting else { return }
        lastVisitAct = Date()
        friends.visit(id, act: act, text: text)
    }

    /// Testing: what the visit bar's buttons do.
    func testAct(_ a: String, _ text: String? = nil) { act(a, text: text) }

    private func showBar(_ f: Friends.Friend) {
        let ui = pet.sprites.ui
        guard let hand = ui["hand"], let shrimp = ui["shrimp"], let hi = ui["hi"], let close = ui["close"] else { return }
        bar.show([
            .init(icon: hand, tip: "摸摸它") { [weak self] in self?.act("pet") },
            .init(icon: shrimp, tip: "喂它一只虾") { [weak self] in self?.act("shrimp") },
            .init(icon: hi, tip: "打个招呼") { [weak self] in self?.greet(f) },
        ], close: close, above: pet.window.frame, level: .floating,
           label: BubbleView.tag("在\(f.display)家"), sticky: true, onClose: { [weak self] in self?.leaveVisit() })
        placeBar()
    }

    private func placeBar() {
        guard bar.isVisible else { return }
        let f = pet.window.frame
        let s = pet.scale
        // Beside the cat (bubbles go above its head), on the roomier side of the head.
        let head = pet.headPoint.x
        let right = head < pet.screenFrame.midX
        let x = right ? max(head + 56 * s, f.maxX - 20 * s) : min(head - 56 * s, f.minX + 20 * s) - bar.frame.width
        bar.move(to: CGPoint(x: x, y: f.minY + 40 * s))
    }

    /// Greetings by the time of day, and one of your own.
    private func greetings() -> [String] {
        let h = Calendar.current.component(.hour, from: Date())
        let timely = h < 5 ? "晚安" : h < 11 ? "早安" : h < 14 ? "吃饭没？" : h < 18 ? "加油！" : h < 22 ? "下班啦" : "晚安"
        return ["嗨～", "在干嘛？", "想你啦", timely]
    }

    private func greet(_ f: Friends.Friend) {
        pickGreeting("跟\(f.display)说什么？") { [weak self] text in self?.act("hi", text: text) }
    }

    private func pickGreeting(_ prompt: String, send: @escaping (String) -> Void) {
        var buttons: [BubbleWindow.Button] = greetings().map { g in .init(title: g) { send(g) } }
        buttons.append(.init(title: "自己写…") { [weak self] in
            self?.pet.ask(prompt, maxLength: 30) { text in if let text { send(text) } }
        })
        say(prompt, 30, buttons: buttons)
    }

    // MARK: events from the relay

    private func handle(_ e: Friends.Event) {
        switch e {
        case .code(let code):
            say("邀请链接准备好啦～\n发给好友，点开就能加（24 小时内有效）", 120, buttons: [
                .init(title: "复制链接") { [weak self] in
                    let text = "来和我的猪猪包做小咪好友吧！在 Mac 上点开这个链接就能加：\nhttps://zhuzhubao.lynie.cc/add/\(code)\n（24 小时内有效）"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    self?.say("复制好啦，去发给好友吧～")
                },
                .init(title: "好") {},
            ])
        case .redeemFailed(let why):
            let lines = ["self": "这是你自己的邀请链接哦～\n要发给好友才行", "already": "我们已经是小咪好友啦～",
                         "slow": "试太多次啦，\n休息一下再来吧", "full": "好友太多啦，\n先解除几个再来吧"]
            say(lines[why] ?? "这个邀请链接用过或过期啦，\n请好友再发一个吧", 4)
        case .paired(let f):
            say(["我和\(f.display)成为小咪好友啦！", "以后可以去\(f.display)家串门啦～"].randomElement()!, 4)
            pet.cheer(2)
        case .unpaired(let id):
            if visiting == id { endVisit() }
            hands[id]?.leave(quick: true)
        case .presence(let f, _):
            if visiting == f.id && !f.canVisit {
                endVisit()
                say(f.online ? "\(f.display)去休息啦，\n我们先回来吧～" : "\(f.display)下线啦，\n我们先回来吧～", 4)
            }
            if !f.online { hands[f.id]?.leave(quick: true) }
        case .visit(let f, let act, let text):
            arrive(f, act: act, text: text)
        case .visited(let f, let act, let ok, let why):
            visited(f, act: act, ok: ok, why: why)
        case .reply(let f, let text):
            let line = "\(f.display)说：\(text)"
            if pet.isPeeking { heldReplies.append(line) } else { say(line, 20, buttons: [.init(title: "好") {}]); pet.cheer() }
        case .failed:
            say("好像连不上网…\n晚点再试试吧", 4)
        }
    }

    /// My side, after the relay passed on (or refused) what my hand did.
    private func visited(_ f: Friends.Friend, act: String, ok: Bool, why: String?) {
        guard ok else {
            switch why {
            case "offline": say("\(f.display)现在不在线哦")
            case "rest": say("\(f.display)在休息中，\n下次再去吧～")
            case "quota": say(act == "shrimp" ? "今天已经喂了好几只虾啦，\n别把它喂撑了～" : "今天去得太多次啦，\n明天再去吧～")
            default: say("我们好像还不是小咪好友…")
            }
            if visiting == f.id, why == "offline" || why == "rest" || why == "nofriend" { endVisit() }
            return
        }
        switch act {
        case "enter":
            visiting = f.id
            lastVisitAct = Date()
            showBar(f)
            say("去\(f.display)家串门啦～\n可以摸摸它、喂虾、打招呼", 4)
            onChange?()
        case "pet": say(["摸到啦～", "它在呼噜呢～"].randomElement()!, 1.6)
        case "shrimp": say("虾虾送过去啦～", 1.8)
        case "hi": say("招呼送到啦～", 1.6)
        default: break
        }
    }

    /// The host's side: a friend's hand is here.
    private func arrive(_ f: Friends.Friend, act: String, text: String?) {
        if act == "leave" { hands[f.id]?.leave(); return }
        guard !pet.isPeeking else { return }                    // resting: the relay already says no, this is a race
        let fresh = hands[f.id] == nil
        let hand = hands[f.id] ?? {
            let h = VisitorHand(pet: pet, name: f.display) { [weak self] in self?.hands[f.id] = nil }
            hands[f.id] = h
            return h
        }()
        hand.touch()
        switch act {
        case "enter":
            if fresh { hand.enter() }
            say(["\(f.display)来串门啦～", "\(f.display)来看我啦！"].randomElement()!, 3)
            pet.cheer(1.2)
        case "pet":
            if fresh { hand.enter() }
            hand.pat { [weak self] in self?.pet.friendPetted(by: f.display) }
        case "shrimp":
            if fresh { hand.enter() }
            hand.dropShrimp { [weak self] p in self?.pet.friendDroppedShrimp(at: p, by: f.display) ?? false }
        case "hi":
            if fresh { hand.enter() }
            hand.wave()
            let said = (text?.isEmpty == false ? text! : "嗨～")
            // Answering (unlike greeting someone yourself): just 好呀, or write your own.
            let send: (String) -> Void = { [weak self] reply in
                self?.friends.reply(f.id, text: reply)
                self?.say("帮你说「\(reply)」啦～", 1.8)
            }
            var buttons: [BubbleWindow.Button] = ["好呀～"].map { r in .init(title: r) { send(r) } }
            buttons.append(.init(title: "自己写…") { [weak self] in
                self?.pet.ask("回\(f.display)什么？", maxLength: 30) { text in if let text { send(text) } }
            })
            pet.friendSaidHi("\(f.display)：\(said)", buttons: buttons)
        default: break
        }
    }

    private func tick() {
        placeBar()
        if pet.isPeeking {
            for h in hands.values { h.leave(quick: true) }     // hiding = resting: everyone's hand goes home
        } else if !heldReplies.isEmpty {
            let line = heldReplies.removeFirst()
            say(line, 20, buttons: [.init(title: "好") {}])
        }
        // A visit nobody touches for a while ends by itself.
        if visiting != nil, Date().timeIntervalSince(lastVisitAct) > 5 * 60 { leaveVisit() }
    }
}

/// A friend's pixel hand, with their name on a little tag, hovering beside the cat's head.
/// Fixed moves only: come in, pat the head, drop a shrimp, wave, leave.
final class VisitorHand {
    private unowned let pet: PetController
    private let window: PetWindow
    private let handLayer = CALayer()
    private let shrimpLayer = CALayer()
    private let tagLayer = CALayer()
    private let images: [String: CGImage]
    private let onGone: () -> Void
    private var timer: Timer?
    private var pos = CGPoint.zero              // bottom-centre of the hand, screen points
    private var side: CGFloat = 1               // which side of the cat it hovers on
    private var move: Move = .hover
    private var moveStart = Date()
    private var lastTouch = Date()
    private var gone = false
    private let born = Date()

    private enum Move { case enter(from: CGPoint), hover, pat, shrimp(release: (CGPoint) -> Bool, done: Bool), wave, leave(from: CGPoint, quick: Bool) }
    private static let art = CGSize(width: 24, height: 30)
    /// Same pixel size as the cat, so the hand looks drawn in the same style.
    private static let handScale: CGFloat = 1

    init(pet: PetController, name: String, onGone: @escaping () -> Void) {
        self.pet = pet
        self.onGone = onGone
        var imgs: [String: CGImage] = [:]
        for n in ["open", "pat", "wave-l", "wave-r"] { imgs[n] = SpriteSet.tryLoad("hand/\(n)")?.image }
        images = imgs
        let s = pet.scale
        let hs = s * Self.handScale
        let tag = BubbleView.tag(name, fill: (1, 0.97, 0.9))
        let tagW = CGFloat(tag?.width ?? 0), tagH = CGFloat(tag?.height ?? 0)
        let w = max(Self.art.width * hs, tagW * s)
        let h = Self.art.height * hs + (tagH + 2) * s
        window = PetWindow(size: CGSize(width: w, height: h))
        window.ignoresMouseEvents = true
        let root = NSView(frame: CGRect(x: 0, y: 0, width: w, height: h))
        root.wantsLayer = true
        for l in [handLayer, shrimpLayer, tagLayer] { l.magnificationFilter = .nearest; root.layer?.addSublayer(l) }
        handLayer.frame = CGRect(x: (w - Self.art.width * hs) / 2, y: (tagH + 2) * s, width: Self.art.width * hs, height: Self.art.height * hs)
        tagLayer.contents = tag
        tagLayer.frame = CGRect(x: (w - tagW * s) / 2, y: 0, width: tagW * s, height: tagH * s)
        shrimpLayer.contents = pet.sprites.shrimp.image
        shrimpLayer.frame = CGRect(x: (w - 26 * s) / 2, y: (tagH + 2) * s + 6 * hs, width: 26 * s, height: 19 * s)   // held in front of the palm
        shrimpLayer.isHidden = true
        window.contentView = root
        window.level = pet.windowLevel
        tagOffset = (tagH + 2) * s
        setImage("open")
    }

    private let tagOffset: CGFloat

    func touch() { lastTouch = Date() }

    private var hoverPoint: CGPoint {
        let head = pet.headPoint, s = pet.scale
        let vf = pet.screenFrame
        let bob = sin(Date().timeIntervalSince(born) * 2.2) * 2 * s
        // While the cat is on the move, stay put (rising clear of it) instead of chasing its head.
        if pet.isMoving, pos != .zero {
            let f = pet.window.frame
            let clear = abs(pos.x - head.x) > 70 * s || pos.y > head.y + 20 * s
            return CGPoint(x: pos.x, y: clear ? pos.y : max(pos.y, f.minY + 150 * s))
        }
        // In front of its face, so it looks at the hand (the other side if there's no room).
        side = pet.facing
        if (side > 0 && head.x + 110 * s > vf.maxX) || (side < 0 && head.x - 110 * s < vf.minX) { side = -side }
        // Beside the cheek, below where speech bubbles go.
        return CGPoint(x: head.x + side * 66 * s, y: head.y - 30 * s + bob)
    }

    func enter() {
        let vf = pet.screenFrame
        let target = hoverPoint
        let from = CGPoint(x: side > 0 ? vf.maxX + 40 : vf.minX - 40, y: target.y + 30 * pet.scale)
        pos = from
        start(.enter(from: from))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.step() }
        place()
        window.orderFrontRegardless()
    }

    private var petCallback: (() -> Void)?
    func pat(_ reacted: @escaping () -> Void) { petCallback = reacted; start(.pat) }
    func dropShrimp(_ release: @escaping (CGPoint) -> Bool) { shrimpLayer.isHidden = false; start(.shrimp(release: release, done: false)) }
    func wave() { start(.wave) }
    func leave(quick: Bool = false) {
        guard !gone else { return }
        if case .leave = move { return }
        start(.leave(from: pos, quick: quick))
    }

    private func start(_ m: Move) {
        if case .leave = move, !gone { if case .leave = m {} else { return } }   // already on its way out
        move = m
        moveStart = Date()
    }

    private func setImage(_ n: String) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        handLayer.contents = images[n]
        // Thumb toward the cat.
        handLayer.setAffineTransform(side < 0 ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        CATransaction.commit()
    }

    private func ease(_ t: Double) -> CGFloat { let c = min(max(t, 0), 1); return CGFloat(c * c * (3 - 2 * c)) }
    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }

    private func step() {
        let t = Date().timeIntervalSince(moveStart)
        let s = pet.scale
        window.level = pet.windowLevel
        switch move {
        case .enter(let from):
            pos = lerp(from, hoverPoint, ease(t / 0.9))
            setImage(Int(t / 0.2) % 2 == 0 ? "wave-l" : "wave-r")
            if t > 0.9 { move = .hover }
        case .hover:
            pos = lerp(pos, hoverPoint, 0.15)
            setImage("open")
            if Date().timeIntervalSince(lastTouch) > 6 * 60 { leave() }   // forgotten: goes home
        case .pat:
            // Over the head, then three strokes, curling the fingers on each.
            let head = pet.headPoint
            let over = CGPoint(x: head.x, y: head.y - 12 * s)
            tagLayer.isHidden = true                     // the name tag would cover the face
            if t < 0.4 { pos = lerp(pos, over, 0.25); setImage("open") }
            else if t < 2.2 {
                if let cb = petCallback { petCallback = nil; cb() }
                let k = (t - 0.4) / 0.6
                pos = CGPoint(x: head.x + CGFloat(sin(k * 2 * .pi)) * 9 * s, y: over.y + CGFloat(abs(cos(k * 2 * .pi))) * 2 * s)
                setImage(Int(t / 0.15) % 2 == 0 ? "pat" : "open")
            } else { move = .hover; moveStart = Date(); tagLayer.isHidden = false }
        case .shrimp(let release, let done):
            // Carry it out in front of the cat, a bit above the floor, and let go.
            let f = pet.window.frame
            let target = CGPoint(x: f.midX + side * 120 * s, y: pet.screenFrame.minY + 90 * s)
            tagLayer.isHidden = !done
            if t < 0.8 { pos = lerp(pos, target, 0.18); setImage("pat") }
            else if !done {
                let p = CGPoint(x: window.frame.midX - 13 * s, y: window.frame.minY + shrimpLayer.frame.minY)
                if !release(p) { pet.showBubble("等我吃完这只～", seconds: 1.8) }
                shrimpLayer.isHidden = true
                move = .shrimp(release: release, done: true)
                setImage("open")
            } else if t > 1.4 { move = .hover; moveStart = Date() }
        case .wave:
            pos = lerp(pos, hoverPoint, 0.2)
            setImage(Int(t / 0.18) % 2 == 0 ? "wave-l" : "wave-r")
            if t > 1.8 { move = .hover }
        case .leave(let from, let quick):
            let vf = pet.screenFrame
            let waveTime = quick ? 0 : 1.0
            if t < waveTime { setImage(Int(t / 0.18) % 2 == 0 ? "wave-l" : "wave-r") }
            else {
                let away = CGPoint(x: side > 0 ? vf.maxX + 60 : vf.minX - 60 - window.frame.width, y: from.y + 40 * s)
                pos = lerp(from, away, ease((t - waveTime) / 0.8))
                setImage("open")
                if t > waveTime + 0.8 { finish(); return }
            }
        }
        place()
    }

    private func place() {
        let f = window.frame
        window.setFrameOrigin(CGPoint(x: pos.x - f.width / 2, y: pos.y - tagOffset))
    }

    private func finish() {
        gone = true
        timer?.invalidate()
        timer = nil
        window.orderOut(nil)
        onGone()
    }
}
