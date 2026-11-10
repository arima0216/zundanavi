import Foundation

/// WP-15i: WS /v1/events の取り直し用カーソル。
/// サーバーは全イベントに通し番号 eid（起動ごとに 1 から）を付け、接続直後に hello {boot, eid} を送る。
/// 再接続時に ?since=<lastEid>&boot=<boot> を付けると、切れていた間のイベントが hello の直後に再送される。
/// アプリのプロセスが生きている間だけ持つ（永続化しない）。
struct EventCursor: Equatable {
    private(set) var boot: String?
    private(set) var lastEid: Int = 0

    init(boot: String? = nil, lastEid: Int = 0) {
        self.boot = boot
        self.lastEid = lastEid
    }

    /// 接続 URL に足すクエリ。boot と lastEid(>0) が両方ある時だけ since / boot を返す。
    func query() -> [URLQueryItem] {
        guard let b = boot, !b.isEmpty, lastEid > 0 else { return [] }
        return [URLQueryItem(name: "since", value: String(lastEid)),
                URLQueryItem(name: "boot", value: b)]
    }

    /// 接続直後の hello。boot が変わった（または初回）→ 入れ替えて lastEid = hello の eid（今より後だけ受ける）。
    /// boot が同じ → lastEid は変えない（この後に再送が来る）。
    mutating func onHello(boot newBoot: String, eid: Int) {
        let b: String? = newBoot.isEmpty ? nil : newBoot
        if b != boot {
            boot = b
            lastEid = max(0, eid)
        }
    }

    /// 受けたイベントを通すか。eid 無し（pong など）は通す。eid <= lastEid は重複なので捨てる。
    /// hello をまだ一度も受けていない（boot 不明）間は、番号が巻き戻っても捨てないよう常に通す。
    mutating func accept(eid: Int?) -> Bool {
        guard let e = eid else { return true }
        if boot == nil {
            lastEid = max(lastEid, e)
            return true
        }
        if e <= lastEid { return false }
        lastEid = e
        return true
    }

    /// WP-15i: speak（guide）の期限。イベントの ts があれば ts + ttl。
    /// ただし端末とサーバーの時計差が大きい（|now - ts| > maxSkew）時は従来どおり now + ttl。
    static let maxClockSkew: TimeInterval = 300

    static func guideExpiry(now: Date, ts: Double?, ttl: TimeInterval) -> Date {
        if let t = ts, t.isFinite, abs(now.timeIntervalSince1970 - t) <= maxClockSkew {
            return Date(timeIntervalSince1970: t + ttl)
        }
        return now.addingTimeInterval(ttl)
    }
}

/// WP-15i: WS イベントの共通フィールド（eid / ts）。生 JSON から読む。
struct WSEnvelope: Equatable {
    var eid: Int?
    var ts: Double?

    init(eid: Int? = nil, ts: Double? = nil) {
        self.eid = eid
        self.ts = ts
    }

    init(json: JSONValue) {
        if let e = json["eid"]?.intValue, e > 0 { eid = e } else { eid = nil }
        if let t = json["ts"]?.doubleValue, t.isFinite { ts = t } else { ts = nil }
    }

    static func parse(_ data: Data) -> WSEnvelope {
        guard let json = try? JSONValue.parse(data), json.objectValue != nil else { return WSEnvelope() }
        return WSEnvelope(json: json)
    }
}
