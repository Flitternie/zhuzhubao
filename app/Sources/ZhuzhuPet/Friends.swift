import AppKit

/// Paired friends, through the small relay at zhuzhubao.lynie.cc (server/ in the repo).
/// Each install has a random id and key (made on first use, kept in the app's defaults); nothing is
/// sent until the user starts pairing, and afterwards only while they have at least one friend.
/// The relay passes on: online / status, pairing codes, and visits (a friend's pixel hand drops by
/// to pet the cat, give a shrimp or say hi). Visits are live only: nothing is stored or queued.
final class Friends: NSObject, URLSessionWebSocketDelegate {
    struct Friend: Equatable {
        let id: String
        var name: String
        var online: Bool
        var status: String?          // awake, sleep, lie, drink, eat, peek (hiding at the screen edge = resting)
        var display: String { name.isEmpty ? "好友" : name }
        var resting: Bool { status == "peek" }
        var canVisit: Bool { online && !resting }
        var statusText: String {
            guard online else { return "不在线" }
            switch status { case "peek": return "休息中"; case "sleep": return "在睡觉"; default: return "在线" }
        }
    }

    enum Event {
        case code(String)
        case redeemFailed(String)                       // bad, self, already, slow, full
        case paired(Friend)
        case unpaired(String)
        case presence(Friend, was: Friend?)
        case visit(Friend, act: String, text: String?)  // someone's hand is here
        case visited(Friend, act: String, ok: Bool, why: String?)
        case reply(Friend, text: String)
        case failed                                     // could not reach the relay for a request
    }

    var onEvent: ((Event) -> Void)?
    var onChange: (() -> Void)?
    /// The cat's current status, polled every few seconds and sent when it changes.
    var statusProvider: (() -> String)?

    private(set) var friends: [Friend] = []
    private(set) var connected = false
    var myName: String {
        get { d.string(forKey: k("name")) ?? "" }
        set { d.set(newValue, forKey: k("name")); send(["t": "name", "name": newValue]) }
    }

    private let d = UserDefaults.standard
    /// Testing: ZHUZHU_NET_PROFILE=b runs a second identity on the same Mac; ZHUZHU_RELAY a local relay.
    private let profile = ProcessInfo.processInfo.environment["ZHUZHU_NET_PROFILE"].map { "-" + $0 } ?? ""
    private let relay = URL(string: ProcessInfo.processInfo.environment["ZHUZHU_RELAY"] ?? "wss://zhuzhubao.lynie.cc/ws")!
    private func k(_ s: String) -> String { "net.\(s)\(profile)" }
    private let netLog = ProcessInfo.processInfo.environment["ZHUZHU_NETLOG"] != nil
    private func log(_ s: @autoclosure () -> String) { if netLog { print("[net]", s()); fflush(stdout) } }

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var wanted = false                  // keep a connection open
    private var backoff: TimeInterval = 2
    private var lastHeard = Date()
    private var outbox: [[String: Any]] = []    // sent before the socket opened
    private var sentStatus: String?
    private var timers: [Timer] = []
    private var requestTimer: Timer?
    private var connectingSince = Date()
    private var retryAt = Date.distantPast

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        // Back from sleep the old socket is usually dead without saying so: start a fresh one.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.wanted || !self.friends.isEmpty else { return }
            self.log("woke up: reconnect")
            self.backoff = 2
            self.task?.cancel()
            self.task = nil
            self.setConnected(false)
            self.connect()
        }
        // Friends known from last time, so the menu can show them before the connection is up.
        if let saved = d.array(forKey: k("friends")) as? [[String: String]] {
            friends = saved.compactMap { f in f["id"].map { Friend(id: $0, name: f["name"] ?? "", online: false, status: nil) } }
        }
    }

    private var identity: (id: String, key: String) {
        if let id = d.string(forKey: k("id")), let key = d.string(forKey: k("key")) { return (id, key) }
        let id = UUID().uuidString.lowercased()
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let key = bytes.map { String(format: "%02x", $0) }.joined()
        d.set(id, forKey: k("id")); d.set(key, forKey: k("key"))
        return (id, key)
    }

    func start() {
        log("start, friends \(friends.count)")
        if !friends.isEmpty { connect() }
        timers.append(Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() })
    }

    func friend(_ id: String) -> Friend? { friends.first { $0.id == id } }

    // MARK: requests

    func requestCode() { request(["t": "code"]) }
    func redeem(_ code: String) { request(["t": "redeem", "code": code]) }
    func unpair(_ id: String) { send(["t": "unpair", "id": id]) }
    func visit(_ id: String, act: String, text: String? = nil) {
        var m: [String: Any] = ["t": "visit", "to": id, "act": act]
        if let text { m["text"] = text }
        send(m)
    }
    func reply(_ id: String, text: String) { send(["t": "reply", "to": id, "text": text]) }

    /// A request that needs an answer: connect if needed and give up after a while.
    private func request(_ m: [String: Any]) {
        connect()
        send(m)
        requestTimer?.invalidate()
        requestTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.requestTimer = nil
            self.outbox.removeAll()
            self.onEvent?(.failed)
            if self.friends.isEmpty && !self.connected { self.disconnect() }
        }
    }

    private func answered() { requestTimer?.invalidate(); requestTimer = nil }

    // MARK: connection

    private func connect() {
        wanted = true
        guard task == nil else { return }
        let me = identity
        var req = URLRequest(url: relay)
        req.setValue(me.id, forHTTPHeaderField: "X-Pet-Id")
        req.setValue(me.key, forHTTPHeaderField: "X-Pet-Key")
        req.timeoutInterval = 15
        let t = session.webSocketTask(with: req)
        log("connect \(relay)")
        task = t
        lastHeard = Date()
        connectingSince = Date()
        t.resume()
        receive(t)
    }

    private func disconnect() {
        wanted = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setConnected(false)
    }

    private func setConnected(_ on: Bool) {
        guard connected != on else { return }
        connected = on
        if !on { for i in friends.indices { friends[i].online = false; friends[i].status = nil } }
        onChange?()
    }

    private func dropped() {
        log("dropped, retry in \(backoff)s, wanted \(wanted)")
        task = nil
        sentStatus = nil
        setConnected(false)
        guard wanted else { return }
        retryAt = Date().addingTimeInterval(backoff)      // tick() reconnects then
        backoff = min(backoff * 2, 60)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        log("open")
        backoff = 2
        lastHeard = Date()
        setConnected(true)
        if !myName.isEmpty { raw(["t": "name", "name": myName]) }
        let queued = outbox
        outbox.removeAll()
        for m in queued { raw(m) }
        tick()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if webSocketTask === task { dropped() }
    }

    func urlSession(_ session: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        log("complete \(String(describing: error)) \((t.response as? HTTPURLResponse)?.statusCode ?? 0)")
        if t === task { dropped() }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, t === self.task else { return }
            switch result {
            case .success(let msg):
                self.lastHeard = Date()
                if case .string(let s) = msg, s != "pong",
                   let data = s.data(using: .utf8),
                   let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { self.handle(m) }
                self.receive(t)
            case .failure:
                self.dropped()
            }
        }
    }

    /// Every 3 s: keep the connection alive, and notice when it is gone or stuck.
    private func tick() {
        if !friends.isEmpty { wanted = true }
        guard let t = task else {
            if wanted && Date() >= retryAt { connect() }
            return
        }
        if !connected && Date().timeIntervalSince(connectingSince) > 20 {     // a handshake that never finished
            log("connect stuck: retry")
            t.cancel(); dropped(); return
        }
        if connected {
            if Date().timeIntervalSince(lastHeard) > 75 { t.cancel(); dropped(); return }   // gone quiet: reconnect
            t.send(.string("ping")) { _ in }
            if let s = statusProvider?(), s != sentStatus { sentStatus = s; raw(["t": "status", "s": s]) }
        }
    }

    private func send(_ m: [String: Any]) {
        if connected { raw(m) } else { outbox.append(m); if wanted || !friends.isEmpty { connect() } }
    }

    private func raw(_ m: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: m), let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    // MARK: messages

    private func parse(_ any: Any?) -> Friend? {
        guard let f = any as? [String: Any], let id = f["id"] as? String else { return nil }
        return Friend(id: id, name: f["name"] as? String ?? "", online: f["online"] as? Bool ?? false, status: f["status"] as? String)
    }

    private func save() {
        d.set(friends.map { ["id": $0.id, "name": $0.name] }, forKey: k("friends"))
        if friends.isEmpty && requestTimer == nil { DispatchQueue.main.async { [weak self] in if self?.friends.isEmpty == true { self?.disconnect() } } }
        onChange?()
    }

    private func handle(_ m: [String: Any]) {
        log("<- \(m["t"] ?? "?")")
        switch m["t"] as? String {
        case "hello":
            friends = (m["friends"] as? [Any] ?? []).compactMap(parse)
            if let name = m["name"] as? String, !name.isEmpty, myName.isEmpty { d.set(name, forKey: k("name")) }
            save()
        case "code":
            answered()
            if let code = m["code"] as? String { onEvent?(.code(code)) }
        case "redeem":
            answered()
            if m["ok"] as? Bool != true { onEvent?(.redeemFailed(m["why"] as? String ?? "bad")) }
        case "paired":
            answered()
            guard let f = parse(m["friend"]) else { return }
            friends.removeAll { $0.id == f.id }
            friends.append(f)
            save()
            onEvent?(.paired(f))
        case "unpaired":
            guard let id = m["id"] as? String else { return }
            friends.removeAll { $0.id == id }
            save()
            onEvent?(.unpaired(id))
        case "presence":
            guard let id = m["id"] as? String, let i = friends.firstIndex(where: { $0.id == id }) else { return }
            let was = friends[i]
            friends[i].online = m["online"] as? Bool ?? false
            friends[i].status = friends[i].online ? (m["status"] as? String ?? "awake") : nil
            onChange?()
            onEvent?(.presence(friends[i], was: was))
        case "name":
            guard let id = m["id"] as? String, let name = m["name"] as? String else { return }
            if m["self"] as? Bool == true { d.set(name, forKey: k("name")) }
            if let i = friends.firstIndex(where: { $0.id == id }) { friends[i].name = name; save() }
        case "visit":
            guard let f = (m["from"] as? String).flatMap(friend), let act = m["act"] as? String else { return }
            onEvent?(.visit(f, act: act, text: m["text"] as? String))
        case "visited":
            guard let f = (m["to"] as? String).flatMap(friend), let act = m["act"] as? String else { return }
            onEvent?(.visited(f, act: act, ok: m["ok"] as? Bool ?? false, why: m["why"] as? String))
        case "reply":
            guard let f = (m["from"] as? String).flatMap(friend), let text = m["text"] as? String else { return }
            onEvent?(.reply(f, text: text))
        default: break
        }
    }
}
