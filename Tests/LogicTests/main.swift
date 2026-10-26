import Foundation

// Sources/Core だけを swiftc で macOS 上にビルドして走らせる最小テスト。
// 実行: swiftc -o logictests Sources/Core/*.swift Tests/LogicTests/main.swift && ./logictests

var failures = 0
var passes = 0

func check(_ cond: Bool, _ name: String) {
    if cond {
        passes += 1
    } else {
        failures += 1
        print("FAIL: " + name)
    }
}

func data(_ s: String) -> Data { return Data(s.utf8) }

// --- AskResponse ---
do {
    let r = try AskResponse.decode(data("{\"id\":\"abc\",\"transcript\":\"今どこ\",\"text_full\":\"博多駅なのだ。\",\"text_voice\":\"博多駅なのだ\",\"audio_url\":\"/v1/audio/abc\",\"elapsed_ms\":1234,\"tier\":\"card\"}"))
    check(r.id == "abc", "ask id")
    check(r.transcript == "今どこ", "ask transcript")
    check(r.textFull == "博多駅なのだ。", "ask text_full")
    check(r.textVoice == "博多駅なのだ", "ask text_voice")
    check(r.audioURL == "/v1/audio/abc", "ask audio_url")
    check(r.elapsedMs == 1234, "ask elapsed")
    check(r.tier == "card", "ask tier")
} catch {
    check(false, "ask decode threw \(error)")
}
do {
    let r = try AskResponse.decode(data("{\"id\":42,\"transcript\":null,\"text_full\":\"x\",\"text_voice\":\"y\",\"audio_url\":null,\"elapsed_ms\":null,\"tier\":null}"))
    check(r.id == "42", "ask numeric id")
    check(r.audioURL == nil, "ask null audio")
    check(r.transcript == nil, "ask null transcript")
} catch {
    check(false, "ask decode 2 threw \(error)")
}
do {
    _ = try AskResponse.decode(data("{\"detail\":\"bad\"}"))
    check(false, "ask without text should throw")
} catch {
    check(true, "ask without text throws")
}

// --- Health ---
do {
    let h = try HealthInfo.decode(data("{\"ok\":true,\"whisper\":true,\"voicevox\":false,\"brain\":\"haiku\"}"))
    check(h.ok, "health ok")
    check(h.parts.count == 3, "health parts")
    check(h.parts[1].value == "NG", "health voicevox NG")
    check(h.parts[2].value == "haiku", "health brain text")
} catch {
    check(false, "health threw \(error)")
}

// --- Card ---
do {
    let c = try CardInfo.decode(data("{\"updated\":\"2026-11-27T07:00:00+09:00\",\"where\":\"鹿児島中央駅\",\"next_action\":\"みずほに乗る\",\"next_deadline\":null,\"how_to_go\":\"\",\"departure_advice\":\"7:10 までに改札\",\"voice_url\":\"/v1/audio/card\"}"))
    check(c.rows.count == 3, "card rows only present")
    check(c.rows.first?.label == "今どこ", "card first label")
    check(c.voiceURL == "/v1/audio/card", "card voice")
    let w = WSEvent.parse(data("{\"type\":\"card\",\"card\":{\"where\":\"博多\"}}"))
    if case .some(.card(let cc)) = w {
        check(cc.rows.first?.value == "博多", "ws card nested")
    } else {
        check(false, "ws card parse")
    }
    let w2 = WSEvent.parse(data("{\"type\":\"card\",\"where\":\"天神\"}"))
    if case .some(.card(let cc)) = w2 {
        check(cc.rows.first?.value == "天神", "ws card flat")
    } else {
        check(false, "ws card flat parse")
    }
} catch {
    check(false, "card threw \(error)")
}

// --- WS events ---
do {
    let s = WSEvent.parse(data("{\"type\":\"speak\",\"seq\":3,\"audio_url\":\"/v1/audio/s3\",\"text\":\"次は右なのだ\"}"))
    check(s == .speak(seq: 3, audioURL: "/v1/audio/s3", text: "次は右なのだ"), "ws speak")
    let a = WSEvent.parse(data("{\"type\":\"alert\",\"level\":\"high\",\"text_voice\":\"急ぐのだ\",\"audio_url\":null}"))
    check(a == .alert(level: "high", textVoice: "急ぐのだ", audioURL: nil), "ws alert")
    let d = WSEvent.parse(data("{\"type\":\"deck\",\"items\":[{\"n\":1,\"title\":\"GO\",\"url\":\"x\"},{\"n\":2,\"title\":\"b\",\"url\":\"y\"}]}"))
    check(d == .deck(count: 2), "ws deck")
    check(WSEvent.parse(data("not json")) == nil, "ws garbage")
}

// --- History ---
do {
    let h = try ServerHistoryItem.decodeList(data("[{\"ts\":1764195840,\"role\":\"user\",\"text\":\"今どこ\"},{\"ts\":\"2026-11-27T07:24:00+09:00\",\"role\":\"assistant\",\"text\":\"博多なのだ\"}]"))
    check(h.count == 2, "history count")
    check(h[0].ts != nil, "history epoch ts")
    check(h[1].ts != nil, "history iso ts")
    check(h[1].role == "assistant", "history role")
} catch {
    check(false, "history threw \(error)")
}

// --- GPS JSON ---
do {
    let g = GPSFix(lat: 33.59, lon: 130.42, acc: 8, heading: nil, speed: 1.2, ts: 1764195840)
    let obj = try JSONSerialization.jsonObject(with: g.jsonData()) as? [String: Any]
    check(obj?["lat"] as? Double == 33.59, "gps lat")
    check(obj?["heading"] is NSNull, "gps heading null")
    check(obj?.count == 6, "gps keys")
} catch {
    check(false, "gps threw \(error)")
}

// --- Endpoint ---
check(Endpoint.url(base: "http://100.98.48.27:47400/", path: "/v1/audio/x")?.absoluteString == "http://100.98.48.27:47400/v1/audio/x", "endpoint relative")
check(Endpoint.url(base: "http://h:1", path: "v1/health")?.absoluteString == "http://h:1/v1/health", "endpoint no slash")
check(Endpoint.url(base: "http://h:1", path: "https://cdn/x.wav")?.absoluteString == "https://cdn/x.wav", "endpoint absolute")
check(Endpoint.websocketURL(base: "http://h:1", path: "/v1/events")?.absoluteString == "ws://h:1/v1/events", "ws url")
check(Endpoint.websocketURL(base: "https://h", path: "/v1/events")?.absoluteString == "wss://h/v1/events", "wss url")
check(Endpoint.url(base: "", path: "/v1/health") == nil, "endpoint empty base")

// --- Multipart ---
do {
    var m = MultipartForm(boundary: "BB")
    m.addField("text", "今どこ")
    m.addFile("audio", filename: "a.wav", mimeType: "audio/wav", data: Data([1, 2, 3]))
    let body = m.finalized()
    let s = String(decoding: body, as: UTF8.self)
    check(s.hasPrefix("--BB\r\nContent-Disposition: form-data; name=\"text\""), "multipart head")
    check(s.contains("filename=\"a.wav\""), "multipart filename")
    check(s.hasSuffix("--BB--\r\n"), "multipart tail")
    check(m.contentType == "multipart/form-data; boundary=BB", "multipart content type")
}

// --- WAV ---
do {
    let w = WavEncoder.encode(samples: [0, 1, -1, 32767], sampleRate: 16000)
    check(w.count == 44 + 8, "wav size")
    check(String(decoding: w.prefix(4), as: UTF8.self) == "RIFF", "wav riff")
    check(w[24] == 0x80 && w[25] == 0x3E, "wav rate 16000 LE")
    check(WavEncoder.beep().count > 44, "beep")
    check(WavEncoder.rms([0.5, -0.5]) == 0.5, "rms")
}

// --- Wake word ---
do {
    let m1 = WakeWord.match(in: "ふぇーぶる、今どこ？")
    check(m1?.after == "今どこ", "wake hiragana")
    let m2 = WakeWord.match(in: "えーとフェーブル ナビを開始して")
    check(m2?.after == "ナビを開始して", "wake katakana")
    check(m2?.start == 3, "wake start index")
    check(WakeWord.match(in: "フェイブル次どうする")?.after == "次どうする", "wake feiburu")
    check(WakeWord.match(in: "フェーブ。バス何番")?.after == "バス何番", "wake feebu")
    check(WakeWord.match(in: "Fable, what time")?.after == "what time", "wake ascii")
    check(WakeWord.match(in: "ＦＡＢＬＥ今どこ")?.after == "今どこ", "wake fullwidth")
    check(WakeWord.match(in: "今日はいい天気") == nil, "no wake")
    check(WakeWord.match(in: "") == nil, "empty wake")
}

// --- Command router ---
check(CommandRouter.route("ナビを開始して") == .startNav, "cmd start")
check(CommandRouter.route("ナビを終了して") == .endNav, "cmd end")
check(CommandRouter.route("静かにして") == .quiet(minutes: 10), "cmd quiet")
check(CommandRouter.route("30分静かにして") == .quiet(minutes: 30), "cmd quiet 30")
check(CommandRouter.route("３０分しずかにして") == .quiet(minutes: 30), "cmd quiet fullwidth")
check(CommandRouter.route("今どこ") == .plain, "cmd none")
check(CommandRouter.route("") == .plain, "cmd empty")

print("logic tests: \(passes) passed, \(failures) failed")
if failures > 0 { exit(1) }
