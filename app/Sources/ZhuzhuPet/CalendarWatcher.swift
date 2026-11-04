import AppKit
import EventKit

/// Reads the Mac calendars and calls back shortly before an event starts and when it starts.
final class CalendarWatcher {
    enum Moment { case soon(minutes: Int), now }
    struct Alert { let title: String; let start: Date; let moment: Moment; let link: URL? }

    private let store = EKEventStore()
    private var timer: Timer?
    private var announced: Set<String> = []
    var onAlert: ((Alert) -> Void)?
    var onAccessChange: (() -> Void)?

    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "calendarEnabled"); enabled ? start() : stop() }
    }
    /// Minutes before the start for the first heads-up.
    var lead: Int { didSet { UserDefaults.standard.set(lead, forKey: "calendarLead") } }

    init() {
        enabled = UserDefaults.standard.object(forKey: "calendarEnabled") as? Bool ?? false
        lead = UserDefaults.standard.object(forKey: "calendarLead") as? Int ?? 10
        if enabled { start() }
    }

    var accessGranted: Bool {
        let s = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) { return s == .fullAccess }
        return s == .authorized
    }
    var accessDenied: Bool {
        let s = EKEventStore.authorizationStatus(for: .event)
        return s == .denied || s == .restricted
    }

    private func start() {
        requestAccess { [weak self] ok in
            guard let self, ok else { return }
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.check() }
            self.check()
        }
    }

    private func stop() { timer?.invalidate(); timer = nil }

    private func requestAccess(_ done: @escaping (Bool) -> Void) {
        if accessGranted { done(true); return }
        let finish: (Bool, Error?) -> Void = { [weak self] ok, _ in
            DispatchQueue.main.async { self?.onAccessChange?(); done(ok) }
        }
        if #available(macOS 14.0, *) { store.requestFullAccessToEvents(completion: finish) }
        else { store.requestAccess(to: .event, completion: finish) }
    }

    /// Look at the next hour; announce each event once at `lead` minutes and once at its start.
    func check() {
        guard enabled, accessGranted else { return }
        let now = Date()
        let events = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-120),
                                                                        end: now.addingTimeInterval(3600), calendars: nil))
        for e in events where !e.isAllDay {
            guard let start = e.startDate, e.status != .canceled else { continue }
            let key = (e.eventIdentifier ?? e.title ?? "") + "\(start.timeIntervalSince1970)"
            let until = start.timeIntervalSince(now)
            let title = (e.title?.isEmpty == false ? e.title! : "日程")
            if until <= 60, until > -120, !announced.contains(key + "now") {
                announced.insert(key + "now"); announced.insert(key + "soon")
                onAlert?(Alert(title: title, start: start, moment: .now, link: Self.meetingLink(e)))
            } else if until <= Double(lead * 60), until > 60, !announced.contains(key + "soon") {
                announced.insert(key + "soon")
                onAlert?(Alert(title: title, start: start, moment: .soon(minutes: max(1, Int((until / 60).rounded()))), link: Self.meetingLink(e)))
            }
        }
    }

    /// A video-call link from the event's URL, location or notes, if any.
    static func meetingLink(_ e: EKEvent) -> URL? {
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "meeting.tencent.com",
                     "voovmeeting.com", "feishu.cn", "larksuite.com", "webex.com", "dingtalk.com"]
        var texts: [String] = []
        if let u = e.url?.absoluteString { texts.append(u) }
        if let l = e.location { texts.append(l) }
        if let n = e.notes { texts.append(n) }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for t in texts {
            for m in detector?.matches(in: t, range: NSRange(t.startIndex..., in: t)) ?? [] {
                if let url = m.url, let host = url.host?.lowercased(), hosts.contains(where: { host.hasSuffix($0) }) { return url }
            }
        }
        return nil
    }
}
