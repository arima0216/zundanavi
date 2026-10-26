import Foundation

enum ModelError: Error, Equatable {
    case notObject
    case missingField(String)
}

/// GET /v1/health の返り。
struct HealthInfo: Equatable {
    var ok: Bool
    /// whisper / voicevox / brain の状態（表示用）
    var parts: [(name: String, value: String)]

    static func == (a: HealthInfo, b: HealthInfo) -> Bool {
        return a.ok == b.ok && a.parts.map { $0.name + "=" + $0.value } == b.parts.map { $0.name + "=" + $0.value }
    }

    init(ok: Bool, parts: [(name: String, value: String)]) {
        self.ok = ok
        self.parts = parts
    }

    init(json: JSONValue) throws {
        guard json.objectValue != nil else { throw ModelError.notObject }
        ok = json["ok"]?.boolValue ?? false
        var p: [(name: String, value: String)] = []
        for key in ["whisper", "voicevox", "brain"] {
            if let v = json[key] {
                if let b = v.boolValue, v.stringValue == "true" || v.stringValue == "false" {
                    p.append((name: key, value: b ? "OK" : "NG"))
                } else {
                    p.append((name: key, value: v.displayText ?? "-"))
                }
            }
        }
        parts = p
    }

    static func decode(_ data: Data) throws -> HealthInfo {
        return try HealthInfo(json: JSONValue.parse(data))
    }

    var summary: String {
        let head = ok ? "OK" : "NG"
        if parts.isEmpty { return head }
        return head + " (" + parts.map { $0.name + ": " + $0.value }.joined(separator: ", ") + ")"
    }
}

/// POST /v1/ask と POST /v1/photo の返り。
struct AskResponse: Equatable {
    var id: String
    var transcript: String?
    var textFull: String
    var textVoice: String
    var audioURL: String?
    var elapsedMs: Double?
    var tier: String?

    init(id: String, transcript: String?, textFull: String, textVoice: String, audioURL: String?, elapsedMs: Double?, tier: String?) {
        self.id = id
        self.transcript = transcript
        self.textFull = textFull
        self.textVoice = textVoice
        self.audioURL = audioURL
        self.elapsedMs = elapsedMs
        self.tier = tier
    }

    init(json: JSONValue) throws {
        guard json.objectValue != nil else { throw ModelError.notObject }
        id = json["id"]?.stringValue ?? UUID().uuidString
        transcript = json["transcript"]?.stringValue
        let full = json["text_full"]?.stringValue
        let voice = json["text_voice"]?.stringValue
        if full == nil && voice == nil { throw ModelError.missingField("text_full") }
        textFull = full ?? voice ?? ""
        textVoice = voice ?? ""
        let a = json["audio_url"]?.stringValue
        audioURL = (a?.isEmpty ?? true) ? nil : a
        elapsedMs = json["elapsed_ms"]?.doubleValue
        tier = json["tier"]?.stringValue
    }

    static func decode(_ data: Data) throws -> AskResponse {
        return try AskResponse(json: JSONValue.parse(data))
    }
}

/// GET /v1/card の返り。あるものだけ表示する。
struct CardInfo: Equatable {
    var updated: String?
    var rows: [CardRow]
    var voiceURL: String?
    /// v1.1: 徒歩経路の目的地
    var nextPlace: NavPlace?
    /// v1.1: あればナビ画面に「タクシー」ボタン
    var taxi: TaxiLink?
    /// v1.1: 今の区間（変わったらジオフェンスを取り直す）
    var legID: String?

    struct CardRow: Equatable, Identifiable {
        var key: String
        var label: String
        var value: String
        var id: String { return key }
    }

    static let fieldLabels: [(key: String, label: String)] = [
        ("where", "今どこ"),
        ("next_action", "次の一手"),
        ("next_deadline", "次の締切"),
        ("how_to_go", "行き方"),
        ("departure_advice", "出発の目安"),
    ]

    init(updated: String?, rows: [CardRow], voiceURL: String?) {
        self.updated = updated
        self.rows = rows
        self.voiceURL = voiceURL
    }

    init(json: JSONValue) throws {
        guard json.objectValue != nil else { throw ModelError.notObject }
        // WS の {type:"card", card:{...}} 形式にも対応する
        var src = json
        if let inner = json["card"], inner.objectValue != nil { src = inner }
        updated = src["updated"]?.displayText
        var r: [CardRow] = []
        for f in CardInfo.fieldLabels {
            if let v = src[f.key].flatMap({ CardInfo.format(key: f.key, $0) }), !v.isEmpty {
                r.append(CardRow(key: f.key, label: f.label, value: v))
            }
        }
        rows = r
        let v = src["voice_url"]?.stringValue
        voiceURL = (v?.isEmpty ?? true) ? nil : v
        nextPlace = src["next_place"].flatMap { NavPlace(json: $0) }
        taxi = src["taxi"].flatMap { TaxiLink(json: $0) }
        let leg = src["leg_id"]?.stringValue ?? src["leg"]?.stringValue
        legID = (leg?.isEmpty ?? true) ? nil : leg
    }

    static func decode(_ data: Data) throws -> CardInfo {
        return try CardInfo(json: JSONValue.parse(data))
    }

    /// v1.1: next_deadline / departure_advice はオブジェクトで来るので文にする
    static func format(key: String, _ v: JSONValue) -> String? {
        guard v.objectValue != nil else { return v.displayText }
        switch key {
        case "next_deadline": return formatDeadline(v) ?? v.displayText
        case "departure_advice": return formatDeparture(v) ?? v.displayText
        default: return v.displayText
        }
    }

    /// {id, label, time, remaining_min, place_id} -> "17:30 ファミマ集合・あと 57 分"
    static func formatDeadline(_ v: JSONValue) -> String? {
        let time = v["time"].flatMap { clockText($0) } ?? ""
        let label = v["label"]?.stringValue ?? ""
        var s = [time, label].filter { !$0.isEmpty }.joined(separator: " ")
        if s.isEmpty { return nil }
        if let r = v["remaining_min"]?.doubleValue {
            if r < 0 {
                s += "・過ぎている"
            } else {
                s += "・あと " + String(Int(r.rounded())) + " 分"
            }
        }
        return s
    }

    /// {leave_at, reason, eta_min} -> "17:10 に出発（徒歩 4 分）。<reason>"
    static func formatDeparture(_ v: JSONValue) -> String? {
        guard let leave = v["leave_at"].flatMap({ clockText($0) }), !leave.isEmpty else {
            let r = v["reason"]?.stringValue ?? ""
            return r.isEmpty ? nil : r
        }
        var s = leave + " に出発"
        if let eta = v["eta_min"]?.doubleValue {
            s += "（徒歩 " + String(Int(eta.rounded())) + " 分）"
        }
        s += "。"
        let reason = (v["reason"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        s += reason
        return s
    }

    /// "17:30" はそのまま、ISO8601 やエポック秒は端末時刻の HH:mm
    static func clockText(_ v: JSONValue) -> String? {
        if case .string(let s) = v {
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.count <= 5, t.contains(":") { return t }
        }
        guard let d = TimeParse.date(from: v) else { return v.stringValue }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "H:mm"
        return f.string(from: d)
    }

    var isEmpty: Bool { return rows.isEmpty }
}

/// GET /v1/history の 1 行。
struct ServerHistoryItem: Equatable {
    var ts: Date?
    var tsText: String?
    var role: String
    var text: String

    init(ts: Date?, tsText: String?, role: String, text: String) {
        self.ts = ts
        self.tsText = tsText
        self.role = role
        self.text = text
    }

    static func decodeList(_ data: Data) throws -> [ServerHistoryItem] {
        let json = try JSONValue.parse(data)
        var list: [JSONValue] = []
        if let a = json.arrayValue {
            list = a
        } else if let a = json["items"]?.arrayValue {
            list = a
        } else if let a = json["history"]?.arrayValue {
            list = a
        } else {
            throw ModelError.notObject
        }
        return list.compactMap { item -> ServerHistoryItem? in
            guard let text = item["text"]?.stringValue else { return nil }
            let role = item["role"]?.stringValue ?? "assistant"
            let tsv = item["ts"]
            return ServerHistoryItem(ts: tsv.flatMap { TimeParse.date(from: $0) }, tsText: tsv?.displayText, role: role, text: text)
        }
    }
}

enum TimeParse {
    /// エポック秒（ミリ秒も可）か ISO8601 を Date にする。
    static func date(from v: JSONValue) -> Date? {
        if let d = v.doubleValue {
            let sec = d > 1e12 ? d / 1000.0 : d
            return Date(timeIntervalSince1970: sec)
        }
        guard let s = v.stringValue else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: s) { return d }
        // タイムゾーン無しの "2026-11-27T07:24:00" は端末のローカル時刻とみなす
        let f3 = DateFormatter()
        f3.locale = Locale(identifier: "en_US_POSIX")
        f3.timeZone = TimeZone.current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            f3.dateFormat = fmt
            if let d = f3.date(from: s) { return d }
        }
        return nil
    }
}

/// WS /v1/events で来るイベント。
enum WSEvent: Equatable {
    case speak(seq: Int, audioURL: String?, text: String)
    case alert(level: String, textVoice: String, audioURL: String?)
    case card(CardInfo)
    case deck(count: Int)
    case script(id: String, stepIdx: Int?, action: String?)
    case unknown(String)

    static func parse(_ data: Data) -> WSEvent? {
        guard let json = try? JSONValue.parse(data), json.objectValue != nil else { return nil }
        return parse(json: json)
    }

    static func parse(json: JSONValue) -> WSEvent? {
        guard let type = json["type"]?.stringValue else { return nil }
        let audio: String? = {
            let a = json["audio_url"]?.stringValue
            return (a?.isEmpty ?? true) ? nil : a
        }()
        switch type {
        case "speak":
            return .speak(seq: json["seq"]?.intValue ?? 0, audioURL: audio, text: json["text"]?.stringValue ?? "")
        case "alert":
            let tv = json["text_voice"]?.stringValue ?? json["text"]?.stringValue ?? ""
            return .alert(level: json["level"]?.stringValue ?? "info", textVoice: tv, audioURL: audio)
        case "card":
            if let c = try? CardInfo(json: json) { return .card(c) }
            return nil
        case "deck":
            return .deck(count: json["items"]?.arrayValue?.count ?? 0)
        case "script":
            guard let sid = json["script_id"]?.stringValue else { return nil }
            return .script(id: sid, stepIdx: json["step_idx"]?.intValue, action: json["action"]?.stringValue)
        default:
            return .unknown(type)
        }
    }
}

/// /v1/ask などに添付する現在地。ts はエポック秒。
struct GPSFix: Equatable {
    var lat: Double
    var lon: Double
    var acc: Double
    var heading: Double?
    var speed: Double?
    var ts: Double

    var dictionary: [String: Any] {
        var d: [String: Any] = ["lat": lat, "lon": lon, "acc": acc, "ts": ts]
        if let h = heading { d["heading"] = h } else { d["heading"] = NSNull() }
        if let v = speed { d["speed"] = v } else { d["speed"] = NSNull() }
        return d
    }

    func jsonData() -> Data {
        let opts: JSONSerialization.WritingOptions = [.sortedKeys]
        return (try? JSONSerialization.data(withJSONObject: dictionary, options: opts)) ?? Data("{}".utf8)
    }

    func jsonString() -> String {
        return String(data: jsonData(), encoding: .utf8) ?? "{}"
    }
}

/// サーバーの URL 組み立て。audio_url は相対でも絶対でも受ける。
enum Endpoint {
    static func normalizeBase(_ base: String) -> String {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }

    static func url(base: String, path: String) -> URL? {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = p.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: p)
        }
        let b = normalizeBase(base)
        guard !b.isEmpty else { return nil }
        let rel = p.hasPrefix("/") ? p : "/" + p
        return URL(string: b + rel)
    }

    /// http(s):// を ws(s):// に変える。
    static func websocketURL(base: String, path: String) -> URL? {
        guard let u = url(base: base, path: path), var comps = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
        if comps.scheme == "https" { comps.scheme = "wss" } else { comps.scheme = "ws" }
        return comps.url
    }
}

// MARK: - API v1.1

/// 徒歩経路の目的地（card.next_place）。
struct NavPlace: Equatable {
    var id: String
    var name: String
    var lat: Double
    var lon: Double
    var radiusM: Double?

    init(id: String, name: String, lat: Double, lon: Double, radiusM: Double? = nil) {
        self.id = id
        self.name = name
        self.lat = lat
        self.lon = lon
        self.radiusM = radiusM
    }

    init?(json: JSONValue) {
        guard json.objectValue != nil, let lat = json["lat"]?.doubleValue, let lon = json["lon"]?.doubleValue else { return nil }
        self.lat = lat
        self.lon = lon
        id = json["id"]?.stringValue ?? (String(lat) + "," + String(lon))
        name = json["name"]?.stringValue ?? "目的地"
        radiusM = json["radius_m"]?.doubleValue
    }

    var coord: Coord { return Coord(lat, lon) }
}

struct TaxiLink: Equatable {
    var label: String
    var url: String

    init?(json: JSONValue) {
        guard let u = json["url"]?.stringValue, !u.isEmpty else { return nil }
        url = u
        label = json["label"]?.stringValue ?? "タクシー"
    }
}

/// GET /v1/fences の 1 件。
struct FenceInfo: Equatable, Identifiable {
    var id: String
    var lat: Double
    var lon: Double
    var radiusM: Double
    var say: String?
    var scriptID: String?
    var markArrivedLeg: String?
    var sayAudio: String?

    var coord: Coord { return Coord(lat, lon) }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, let lat = json["lat"]?.doubleValue, let lon = json["lon"]?.doubleValue else { return nil }
        self.id = id
        self.lat = lat
        self.lon = lon
        radiusM = json["radius_m"]?.doubleValue ?? 30
        let enter = json["on_enter"]
        say = enter?["say"]?.stringValue
        scriptID = enter?["script_id"]?.stringValue
        markArrivedLeg = enter?["mark_arrived_leg"]?.stringValue
        let a = json["say_audio"]?.stringValue
        sayAudio = (a?.isEmpty ?? true) ? nil : a
    }

    static func decodeList(_ data: Data) throws -> [FenceInfo] {
        let json = try JSONValue.parse(data)
        let arr = json["fences"]?.arrayValue ?? json.arrayValue ?? []
        return Array(arr.compactMap { FenceInfo(json: $0) }.prefix(20))
    }
}

/// GET /v1/script/{id}
struct ScriptInfo: Equatable {
    struct Step: Equatable, Identifiable {
        var idx: Int
        var text: String
        var audioURL: String?
        var fenceID: String?
        var landmark: String?
        var id: Int { return idx }
    }

    var id: String
    var title: String
    var steps: [Step]

    static func decode(_ data: Data) throws -> ScriptInfo {
        let json = try JSONValue.parse(data)
        guard json.objectValue != nil, let id = json["id"]?.stringValue else { throw ModelError.missingField("id") }
        let arr = json["steps"]?.arrayValue ?? []
        var steps: [Step] = []
        for (i, v) in arr.enumerated() {
            let a = v["audio_url"]?.stringValue
            steps.append(Step(idx: v["idx"]?.intValue ?? i,
                              text: v["text"]?.stringValue ?? "",
                              audioURL: (a?.isEmpty ?? true) ? nil : a,
                              fenceID: v["fence_id"]?.stringValue,
                              landmark: v["landmark"]?.stringValue))
        }
        steps.sort { $0.idx < $1.idx }
        return ScriptInfo(id: id, title: json["title"]?.stringValue ?? id, steps: steps)
    }
}

/// POST /v1/route の返り。
struct RouteAudio: Equatable {
    struct Step: Equatable {
        var idx: Int
        var textApproach: String?
        var audioApproach: String?
        var textAt: String?
        var audioAt: String?
    }

    var routeID: String
    var steps: [Int: Step]
    var offrouteAudio: String?
    var arrivedAudio: String?

    static func decode(_ data: Data) throws -> RouteAudio {
        let json = try JSONValue.parse(data)
        guard json.objectValue != nil else { throw ModelError.notObject }
        func s(_ v: JSONValue?) -> String? {
            let x = v?.stringValue
            return (x?.isEmpty ?? true) ? nil : x
        }
        var map: [Int: Step] = [:]
        for v in json["steps"]?.arrayValue ?? [] {
            guard let idx = v["idx"]?.intValue else { continue }
            map[idx] = Step(idx: idx, textApproach: s(v["text_approach"]), audioApproach: s(v["audio_approach"]),
                            textAt: s(v["text_at"]), audioAt: s(v["audio_at"]))
        }
        return RouteAudio(routeID: json["route_id"]?.stringValue ?? "", steps: map,
                          offrouteAudio: s(json["offroute_audio"]), arrivedAudio: s(json["arrived_audio"]))
    }
}
