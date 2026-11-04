import Foundation

/// Long-term affection (好感). Points come from drinking water, petting and shrimp, each capped per
/// day so it grows with steady care rather than grinding. It never goes down. Shown only as hearts.
final class Affection {
    /// Total points needed for each step (5 steps, shown as 1...5 filled hearts).
    static let thresholds = [0, 20, 60, 150, 300]
    enum Source: String, CaseIterable { case water, pet, shrimp }
    /// Points per time and how many times a day count.
    /// water: 2 a cup, 6 cups (12); petting: 1 a time, 3 times (3); shrimp: 2 each, 2 shrimp (4). At most 19 a day.
    private static let rules: [Source: (each: Int, perDay: Int)] = [.water: (2, 6), .pet: (1, 3), .shrimp: (2, 2)]

    private let d: UserDefaults
    private(set) var points: Int

    init() {
        // Testing: ZHUZHU_AFFECTION=<points> starts from that score and saves nothing (a scratch store).
        if let s = ProcessInfo.processInfo.environment["ZHUZHU_AFFECTION"], let v = Int(s) {
            d = UserDefaults(suiteName: "zhuzhubao.affection-test") ?? .standard
            d.removePersistentDomain(forName: "zhuzhubao.affection-test")
            points = v
        } else {
            d = .standard
            points = d.integer(forKey: "affection")
        }
    }

    /// 0...4
    var level: Int { Self.thresholds.lastIndex(where: { points >= $0 }) ?? 0 }
    var hearts: String {
        let n = level + 1
        return String(repeating: "♥", count: n) + String(repeating: "♡", count: Self.thresholds.count - n)
    }

    /// Petting spells within 5 minutes before it has had enough and walks off.
    var walkOffLimit: Int { [3, 4, 5, 7, Int.max][level] }
    /// Percent chance that petting a sitting cat makes it lie down and knead or roll over.
    var cuddleChance: Int { [10, 30, 50, 70, 90][level] }
    /// Petting a lying cat: percent chances that it starts kneading / rolls onto its back (otherwise it just purrs).
    var kneadWhenLyingChance: Int { [35, 40, 45, 50, 50][level] }
    var bellyWhenLyingChance: Int { [5, 15, 25, 35, 45][level] }

    struct Gain { let counted: Bool; let levelUp: Int? }

    /// Counts one drink / petting / shrimp. `counted` is false once today's cap is reached.
    func add(_ source: Source) -> Gain {
        let today = Self.dayString(Date())
        if d.string(forKey: "affDay") != today {
            d.set(today, forKey: "affDay")
            for s in Source.allCases { d.set(0, forKey: "aff-\(s.rawValue)") }
        }
        let rule = Self.rules[source]!
        let used = d.integer(forKey: "aff-\(source.rawValue)")
        guard used < rule.perDay else { return Gain(counted: false, levelUp: nil) }
        d.set(used + 1, forKey: "aff-\(source.rawValue)")
        let before = level
        points += rule.each
        d.set(points, forKey: "affection")
        return Gain(counted: true, levelUp: level > before ? level : nil)
    }

    /// Records today's visit; returns how many whole days since the last one (0 on the first run).
    func checkIn() -> Int {
        defer { d.set(Date(), forKey: "affLastSeen") }
        guard let last = d.object(forKey: "affLastSeen") as? Date else { return 0 }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: last),
                                               to: Calendar.current.startOfDay(for: Date())).day ?? 0
    }

    private static func dayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year!)-\(c.month!)-\(c.day!)"
    }
}
