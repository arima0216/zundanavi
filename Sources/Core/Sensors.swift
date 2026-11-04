import Foundation

// WP-11i: /v1/position に同梱する観測値と、その組み立て・選択の純粋ロジック。
// 判定（ゾーン・階・棄却）はサーバー側。ここは「観測して付けて送る」ための部品だけ。

/// 既存の `heading` フィールドを何で埋めるか。
/// 規則: speed >= 0.5 m/s かつ course_acc が 0...30 度なら course、それ以外は heading_true（無ければ nil）。
enum HeadingPick {
    static let minSpeed: Double = 0.5
    static let maxCourseAcc: Double = 30

    static func pick(speed: Double?, course: Double?, courseAcc: Double?, headingTrue: Double?) -> Double? {
        if let v = speed, v >= minSpeed,
           let c = course, c >= 0, c.isFinite,
           let a = courseAcc, a >= 0, a <= maxCourseAcc {
            return c
        }
        if let h = headingTrue, h >= 0, h.isFinite {
            return h
        }
        return nil
    }
}

/// CMMotionActivity は排他ではないので 1 つに絞る。
/// 優先: walking > running > cycling > automotive > stationary。全部 false は unknown。
enum MotionPick {
    static func pick(stationary: Bool, walking: Bool, running: Bool, automotive: Bool, cycling: Bool) -> String {
        if walking { return "walking" }
        if running { return "running" }
        if cycling { return "cycling" }
        if automotive { return "automotive" }
        if stationary { return "stationary" }
        return "unknown"
    }
}

/// CMPedometer の累計から「前回送信からの差分」を出す。
/// 累計が減った（計測をやり直した）ときは 0 から数え直す（新しい累計がそのまま差分になる）。
struct StepCounter: Equatable {
    private(set) var steps: Int = 0
    private(set) var distance: Double?
    private var sentSteps: Int = 0
    private var sentDistance: Double = 0

    /// 計測の開始（やり直し）。累計も基準も 0 に戻す。
    mutating func reset() {
        steps = 0
        distance = nil
        sentSteps = 0
        sentDistance = 0
    }

    /// startUpdates(from:) が返す累計を受ける。
    mutating func update(steps s: Int, distance d: Double?) {
        if s < steps {
            sentSteps = 0
            sentDistance = 0
        }
        steps = max(s, 0)
        if let d = d, d.isFinite, d >= 0 { distance = d }
    }

    /// 送信時に呼ぶ。前回 take からの差分を返して基準を進める。
    mutating func take() -> (steps: Int, distance: Double?) {
        let ds = max(steps - sentSteps, 0)
        var dd: Double?
        if let d = distance {
            dd = max(d - sentDistance, 0)
            sentDistance = d
        }
        sentSteps = steps
        return (ds, dd)
    }
}

/// 端末側の最小限の棄却。horizontalAccuracy < 0（座標が無効）だけ送らない。
/// 古い fix も落とさず fix_age_s を付けて送る（古さ・精度の判断はサーバー側。v0.3.1）。
enum FixGate {
    enum Verdict: Equatable {
        case send
        case dropNoAccuracy
    }

    static func check(acc: Double) -> Verdict {
        if acc < 0 || !acc.isFinite { return .dropNoAccuracy }
        return .send
    }
}

/// /v1/position の追加観測値。nil のキーは JSON に出さない。
struct PositionExtras: Equatable {
    // CLLocation
    var course: Double?
    var courseAcc: Double?
    var altM: Double?
    var vertAcc: Double?
    var floorLevel: Int?
    var fixAgeS: Double?
    // CLHeading
    var headingTrue: Double?
    var headingMag: Double?
    var headingAcc: Double?
    // Core Motion
    var motion: String?
    var motionConf: Int?
    var stepsDelta: Int?
    var distDeltaM: Double?
    var floorsAsc: Int?
    var floorsDesc: Int?
    var pressureKPa: Double?
    var relAltM: Double?
    var altBaseTs: Double?
    // 端末
    var appState: String?
    var battery: Double?

    /// 値のあるキーだけ。非有限の数（NaN/inf）も落とす（JSONSerialization が投げて本体が {} になるのを防ぐ）。
    var dictionary: [String: Any] {
        var d: [String: Any] = [:]
        func num(_ k: String, _ v: Double?) {
            if let v = v, v.isFinite { d[k] = v }
        }
        func int(_ k: String, _ v: Int?) {
            if let v = v { d[k] = v }
        }
        func str(_ k: String, _ v: String?) {
            if let v = v, !v.isEmpty { d[k] = v }
        }
        num("course", course)
        num("course_acc", courseAcc)
        num("alt_m", altM)
        num("vert_acc", vertAcc)
        int("floor_level", floorLevel)
        num("fix_age_s", fixAgeS)
        num("heading_true", headingTrue)
        num("heading_mag", headingMag)
        num("heading_acc", headingAcc)
        str("motion", motion)
        int("motion_conf", motionConf)
        int("steps_delta", stepsDelta)
        num("dist_delta_m", distDeltaM)
        int("floors_asc", floorsAsc)
        int("floors_desc", floorsDesc)
        num("pressure_kpa", pressureKPa)
        num("rel_alt_m", relAltM)
        num("alt_base_ts", altBaseTs)
        str("app_state", appState)
        num("battery", battery)
        return d
    }

    /// 0〜1 に収まる電池残量だけ返す（UIDevice は不明時 -1）。
    static func battery(level: Float) -> Double? {
        let v = Double(level)
        guard v.isFinite, v >= 0, v <= 1 else { return nil }
        return v
    }

    /// 負値は「無効」を表す CoreLocation の値を nil にする。
    static func nonNegative(_ v: Double) -> Double? {
        return (v.isFinite && v >= 0) ? v : nil
    }
}
