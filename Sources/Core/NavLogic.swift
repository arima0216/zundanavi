import Foundation

// 徒歩ナビ・ジオフェンス・台本・デッキの判定ロジック（MapKit 非依存）。

/// MapKit の指示文から取る方向。
enum TurnDirection: String, Equatable {
    case right, left, straight, uturn, arrive, unknown
}

enum DirectionParser {
    private static let rules: [(TurnDirection, [String])] = [
        (.arrive, ["目的地", "到着", "arrive", "destination"]),
        (.uturn, ["uたーん", "u-turn", "u turn", "make a u"]),
        (.right, ["右", "right"]),
        (.left, ["左", "left"]),
        (.straight, ["直進", "まっすぐ", "真っ直ぐ", "道なり", "continue", "straight", "proceed", "head "]),
    ]

    static func parse(_ instruction: String) -> TurnDirection {
        let s = String(WakeWord.normalize(instruction))
        if s.isEmpty { return .unknown }
        for (dir, words) in rules {
            for w in words where s.contains(w) {
                return dir
            }
        }
        return .unknown
    }

    /// 100 m 手前の文（端末合成のフォールバック用）。
    static func approachText(_ instruction: String, meters: Int = 100) -> String {
        let m = String(meters)
        switch parse(instruction) {
        case .right: return "あと" + m + "メートルで右なのだ"
        case .left: return "あと" + m + "メートルで左なのだ"
        case .straight: return "あと" + m + "メートル、まっすぐなのだ"
        case .uturn: return "あと" + m + "メートルで引き返すのだ"
        case .arrive: return "あと" + m + "メートルで目的地なのだ"
        case .unknown: return "あと" + m + "メートルで、" + instruction
        }
    }

    /// 20 m 手前（その場）の文。
    static func atText(_ instruction: String) -> String {
        switch parse(instruction) {
        case .right: return "ここを右なのだ"
        case .left: return "ここを左なのだ"
        case .straight: return "ここはまっすぐなのだ"
        case .uturn: return "ここで引き返すのだ"
        case .arrive: return "目的地に着くのだ"
        case .unknown: return instruction
        }
    }

    static let offrouteText = "道が違うのだ、戻るのだ"
    static let arrivedText = "着いたのだ"
}

/// 経路の手順点（曲がる場所）。
struct NavStep: Equatable {
    var idx: Int
    var instruction: String
    var point: Coord
    var distanceM: Double
}

enum NavCue: Equatable {
    case approach(Int)
    case at(Int)
    case arrived
}

/// 手順点ごとに「100 m 手前で approach を 1 回」「20 m 手前で at を 1 回」、通過したら次へ。
struct StepTracker {
    static let approachM = 100.0
    static let atM = 20.0
    static let passM = 25.0
    static let maxAccuracy = 50.0

    let steps: [NavStep]
    let destination: Coord
    let arriveRadius: Double
    private(set) var current = 0
    private(set) var arrived = false
    private var approachSaid: Set<Int> = []
    private var atSaid: Set<Int> = []
    private var minDist: Double = .infinity

    init(steps: [NavStep], destination: Coord, arriveRadius: Double = 25) {
        self.steps = steps
        self.destination = destination
        self.arriveRadius = arriveRadius
    }

    var currentStep: NavStep? {
        return current < steps.count ? steps[current] : nil
    }

    mutating func update(_ pos: Coord, accuracy: Double) -> [NavCue] {
        if arrived { return [] }
        if accuracy < 0 || accuracy > StepTracker.maxAccuracy { return [] }
        var cues: [NavCue] = []
        if Geo.distance(pos, destination) <= arriveRadius {
            arrived = true
            current = steps.count
            return [.arrived]
        }
        // 1 回の測位で複数の手順点を飛ばすこともある
        var guardCount = 0
        while current < steps.count && guardCount < steps.count {
            guardCount += 1
            let st = steps[current]
            let d = Geo.distance(pos, st.point)
            if d < minDist { minDist = d }
            if d <= StepTracker.atM {
                if !atSaid.contains(st.idx) {
                    atSaid.insert(st.idx)
                    approachSaid.insert(st.idx)
                    cues.append(.at(st.idx))
                }
                break
            }
            if d <= StepTracker.approachM && !approachSaid.contains(st.idx) && !atSaid.contains(st.idx) {
                approachSaid.insert(st.idx)
                cues.append(.approach(st.idx))
            }
            // 通過: 一度 20 m 以内に入ってから 25 m 以上離れた、
            // または次の手順点の方が近くて今の点からも離れている
            var passed = false
            if atSaid.contains(st.idx) && d > StepTracker.passM {
                passed = true
            } else if current + 1 < steps.count {
                let dn = Geo.distance(pos, steps[current + 1].point)
                if dn < d && d > minDist + StepTracker.passM {
                    passed = true
                }
            }
            if passed {
                current += 1
                minDist = .infinity
                continue
            }
            break
        }
        return cues
    }
}

/// 経路外れ: 経路から 40 m 超の測位が 2 回連続かつ 5 秒以上続いたら再探索（クールダウン 20 秒）。
struct OffRouteDetector {
    static let thresholdM = 40.0
    static let requiredCount = 2
    static let requiredSeconds = 5.0
    static let cooldown = 20.0
    static let maxAccuracy = 50.0

    private var count = 0
    private var firstOffAt: Double = 0
    private var lastTrigger: Double = -1e12

    mutating func update(distanceToRoute d: Double, accuracy: Double, time t: Double) -> Bool {
        if accuracy < 0 || accuracy > OffRouteDetector.maxAccuracy { return false }
        if d <= OffRouteDetector.thresholdM {
            count = 0
            return false
        }
        if count == 0 { firstOffAt = t }
        count += 1
        if count >= OffRouteDetector.requiredCount && t - firstOffAt >= OffRouteDetector.requiredSeconds && t - lastTrigger >= OffRouteDetector.cooldown {
            lastTrigger = t
            count = 0
            return true
        }
        return false
    }

    mutating func reset() {
        count = 0
    }
}

/// ジオフェンス（ソフトウェア判定）。入=radius、出=radius×1.3。同じ id の発火は 3 分抑止。
struct FenceTracker {
    struct Fence: Equatable {
        var id: String
        var center: Coord
        var radius: Double
    }

    static let exitFactor = 1.3
    static let suppressSeconds = 180.0
    static let maxAccuracy = 50.0

    private(set) var fences: [Fence] = []
    private(set) var inside: Set<String> = []
    private var lastFired: [String: Double] = [:]

    mutating func setFences(_ f: [Fence]) {
        fences = f
        let ids = Set(f.map { $0.id })
        inside = inside.intersection(ids)
    }

    /// 進入して抑止に当たらなかった id を返す。
    mutating func update(_ pos: Coord, accuracy: Double, time t: Double) -> [String] {
        if accuracy < 0 || accuracy > FenceTracker.maxAccuracy { return [] }
        var fired: [String] = []
        for f in fences {
            let d = Geo.distance(pos, f.center)
            if inside.contains(f.id) {
                if d > f.radius * FenceTracker.exitFactor {
                    inside.remove(f.id)
                }
            } else if d <= f.radius {
                inside.insert(f.id)
                if allowFire(f.id, time: t) {
                    fired.append(f.id)
                }
            }
        }
        return fired
    }

    /// OS のリージョン監視など外からの進入。抑止に当たらなければ true。
    mutating func externalEnter(_ id: String, time t: Double) -> Bool {
        inside.insert(id)
        return allowFire(id, time: t)
    }

    private mutating func allowFire(_ id: String, time t: Double) -> Bool {
        if let last = lastFired[id], t - last < FenceTracker.suppressSeconds {
            return false
        }
        lastFired[id] = t
        return true
    }
}

/// アクションデッキ（番号順のカード。開いたものは「済」、次の未済を強調）。
struct DeckItem: Equatable, Identifiable {
    var n: Int
    var title: String
    var url: String
    var id: Int { return n }
}

struct ActionDeck: Equatable {
    private(set) var items: [DeckItem]
    private(set) var done: Set<Int> = []

    init(items: [DeckItem]) {
        self.items = items.sorted { $0.n < $1.n }
    }

    var current: DeckItem? {
        return items.first { !done.contains($0.n) }
    }

    func isDone(_ n: Int) -> Bool {
        return done.contains(n)
    }

    var allDone: Bool {
        return !items.isEmpty && items.allSatisfy { done.contains($0.n) }
    }

    mutating func markDone(_ n: Int) {
        if items.contains(where: { $0.n == n }) {
            done.insert(n)
        }
    }

    static func parse(json: JSONValue) -> ActionDeck {
        let arr = json["items"]?.arrayValue ?? []
        var list: [DeckItem] = []
        for (i, v) in arr.enumerated() {
            guard let url = v["url"]?.stringValue, !url.isEmpty else { continue }
            let n = v["n"]?.intValue ?? (i + 1)
            list.append(DeckItem(n: n, title: v["title"]?.stringValue ?? url, url: url))
        }
        return ActionDeck(items: list)
    }

    static func parse(_ data: Data) -> ActionDeck? {
        guard let json = try? JSONValue.parse(data) else { return nil }
        return parse(json: json)
    }
}

/// 台本の現在位置。
struct ScriptCursor: Equatable {
    var idx: Int
    var count: Int

    mutating func apply(_ action: String) {
        switch action {
        case "next": idx = min(idx + 1, max(count - 1, 0))
        case "prev": idx = max(idx - 1, 0)
        default: break // repeat
        }
    }

    mutating func go(_ i: Int) {
        idx = max(0, min(i, max(count - 1, 0)))
    }
}
