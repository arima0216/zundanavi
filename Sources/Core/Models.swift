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
            if let v = src[f.key]?.displayText, !v.isEmpty {
                r.append(CardRow(key: f.key, label: f.label, value: v))
            }
        }
        rows = r
        let v = src["voice_url"]?.stringValue
        voiceURL = (v?.isEmpty ?? true) ? nil : v
    }

    static func decode(_ data: Data) throws -> CardInfo {
        return try CardInfo(json: JSONValue.parse(data))
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
