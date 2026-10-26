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

// ===== WP-2n: nav / fences / script / deck =====

// --- Geo ---
do {
    let a = Coord(31.58, 130.54)
    let b = Geo.offset(a, northMeters: 300, eastMeters: 0)
    check(abs(Geo.distance(a, b) - 300) < 0.5, "geo distance 300m")
    let p = Geo.offset(a, northMeters: 150, eastMeters: 50)
    check(abs(Geo.distanceToPolyline(p, [a, b]) - 50) < 0.5, "geo polyline 50m")
    let q = Geo.offset(a, northMeters: -30, eastMeters: 40)
    check(abs(Geo.distanceToPolyline(q, [a, b]) - 50) < 0.5, "geo polyline endpoint")
    check(Geo.distanceToPolyline(p, []) == .infinity, "geo empty line")
}

// --- StepTracker: 100m -> 20m -> pass, inaccurate fixes ignored ---
do {
    let o = Coord(31.58, 130.54)
    let s0 = NavStep(idx: 0, instruction: "右折", point: Geo.offset(o, northMeters: 300, eastMeters: 0), distanceM: 300)
    let s1 = NavStep(idx: 1, instruction: "左折", point: Geo.offset(o, northMeters: 300, eastMeters: 200), distanceM: 200)
    let dest = Geo.offset(o, northMeters: 300, eastMeters: 400)
    var t = StepTracker(steps: [s0, s1], destination: dest)
    var cues: [NavCue] = []
    check(t.update(s0.point, accuracy: 80).isEmpty, "tracker ignores acc>50")
    check(t.current == 0, "tracker still step0 after bad fix")
    var n = 0.0
    while n <= 300 {
        cues += t.update(Geo.offset(o, northMeters: n, eastMeters: 0), accuracy: 5)
        n += 10
    }
    check(cues == [.approach(0), .at(0)], "tracker step0 approach then at")
    var e = 10.0
    while e <= 400 && !t.arrived {
        cues += t.update(Geo.offset(o, northMeters: 300, eastMeters: e), accuracy: 5)
        e += 10
    }
    check(cues == [.approach(0), .at(0), .approach(1), .at(1), .arrived], "tracker full sequence")
    check(t.arrived, "tracker arrived")
    check(t.update(dest, accuracy: 5).isEmpty, "tracker silent after arrival")
}
do {
    // 20 m 以内から始まる手順点は approach を飛ばして at だけ
    let o = Coord(33.59, 130.42)
    let s0 = NavStep(idx: 0, instruction: "Turn right", point: Geo.offset(o, northMeters: 15, eastMeters: 0), distanceM: 15)
    var t = StepTracker(steps: [s0], destination: Geo.offset(o, northMeters: 15, eastMeters: 300))
    check(t.update(o, accuracy: 10) == [.at(0)], "tracker near start gives at only")
}

// --- OffRouteDetector ---
do {
    var d = OffRouteDetector()
    check(d.update(distanceToRoute: 50, accuracy: 5, time: 0) == false, "offroute 1st")
    check(d.update(distanceToRoute: 50, accuracy: 5, time: 3) == false, "offroute 2nd but <5s")
    check(d.update(distanceToRoute: 50, accuracy: 5, time: 6) == true, "offroute trigger")
    check(d.update(distanceToRoute: 50, accuracy: 5, time: 10) == false, "offroute count reset")
    check(d.update(distanceToRoute: 50, accuracy: 5, time: 16) == false, "offroute cooldown")
    check(d.update(distanceToRoute: 50, accuracy: 5, time: 30) == true, "offroute after cooldown")
    var d2 = OffRouteDetector()
    _ = d2.update(distanceToRoute: 50, accuracy: 5, time: 0)
    _ = d2.update(distanceToRoute: 10, accuracy: 5, time: 3)
    check(d2.update(distanceToRoute: 50, accuracy: 5, time: 6) == false, "offroute back on route resets")
    check(d2.update(distanceToRoute: 90, accuracy: 80, time: 9) == false, "offroute ignores acc>50")
    check(d2.update(distanceToRoute: 50, accuracy: 5, time: 12) == true, "offroute bad fix not counted as reset")
}

// --- FenceTracker: hysteresis + 3 min suppression ---
do {
    let c = Coord(33.59, 130.40)
    var f = FenceTracker()
    f.setFences([FenceTracker.Fence(id: "hotel", center: c, radius: 30)])
    func at(_ m: Double) -> Coord { return Geo.offset(c, northMeters: m, eastMeters: 0) }
    check(f.update(at(40), accuracy: 5, time: 0).isEmpty, "fence outside")
    check(f.update(at(25), accuracy: 5, time: 10) == ["hotel"], "fence enter")
    check(f.update(at(35), accuracy: 5, time: 20).isEmpty, "fence hysteresis keeps inside")
    check(f.inside.contains("hotel"), "fence still inside at 35m")
    _ = f.update(at(45), accuracy: 5, time: 30)
    check(!f.inside.contains("hotel"), "fence exit beyond 1.3x")
    check(f.update(at(25), accuracy: 5, time: 70).isEmpty, "fence re-enter suppressed")
    _ = f.update(at(45), accuracy: 5, time: 80)
    check(f.update(at(25), accuracy: 5, time: 200) == ["hotel"], "fence fires after 3 min")
    check(f.externalEnter("hotel", time: 250) == false, "fence external suppressed")
    check(f.externalEnter("gate", time: 250) == true, "fence external new id")
    check(f.update(at(0), accuracy: 99, time: 1000).isEmpty, "fence ignores acc>50")
}

// --- DirectionParser ---
check(DirectionParser.parse("右折してください") == .right, "dir ja right")
check(DirectionParser.parse("左に曲がります") == .left, "dir ja left")
check(DirectionParser.parse("直進します") == .straight, "dir ja straight")
check(DirectionParser.parse("目的地は右側です") == .arrive, "dir ja arrive")
check(DirectionParser.parse("Uターンします") == .uturn, "dir ja uturn")
check(DirectionParser.parse("Turn left onto Main St") == .left, "dir en left")
check(DirectionParser.parse("Slight right") == .right, "dir en right")
check(DirectionParser.parse("Continue onto Route 3") == .straight, "dir en straight")
check(DirectionParser.parse("The destination is on your right") == .arrive, "dir en arrive")
check(DirectionParser.parse("国道3号線に入ります") == .unknown, "dir unknown")
check(DirectionParser.approachText("右折") == "あと100メートルで右なのだ", "dir approach text")
check(DirectionParser.atText("Turn left") == "ここを左なのだ", "dir at text")
check(DirectionParser.atText("国道3号線に入ります") == "国道3号線に入ります", "dir at text raw")

// --- ActionDeck ---
do {
    let deck = ActionDeck.parse(data("{\"type\":\"deck\",\"items\":[{\"n\":2,\"title\":\"GO を開く\",\"url\":\"go://\"},{\"n\":1,\"title\":\"地図\",\"url\":\"https://maps.apple.com/?q=x\"},{\"n\":3,\"title\":\"Uber\",\"url\":\"uber://\"}]}"))
    check(deck?.items.map { $0.n } == [1, 2, 3], "deck sorted by n")
    var d = deck ?? ActionDeck(items: [])
    check(d.current?.n == 1, "deck current first")
    d.markDone(1)
    check(d.current?.n == 2 && d.isDone(1), "deck next after done")
    d.markDone(3)
    check(d.current?.n == 2, "deck skips done out of order")
    d.markDone(9)
    check(d.done.count == 2, "deck ignores unknown n")
    d.markDone(2)
    check(d.current == nil && d.allDone, "deck all done")
}

// --- ScriptCursor ---
do {
    var c = ScriptCursor(idx: 0, count: 3)
    c.apply("next")
    c.apply("next")
    c.apply("next")
    check(c.idx == 2, "script next clamps")
    c.apply("repeat")
    check(c.idx == 2, "script repeat stays")
    c.apply("prev")
    c.apply("prev")
    c.apply("prev")
    check(c.idx == 0, "script prev clamps")
    c.go(7)
    check(c.idx == 2, "script go clamps")
}

// --- v1.1 models ---
do {
    let c = try CardInfo.decode(data("{\"where\":\"博多駅\",\"leg_id\":\"L2\",\"next_place\":{\"id\":\"hotel\",\"name\":\"ホテル\",\"lat\":33.59,\"lon\":130.40},\"taxi\":{\"label\":\"GO\",\"url\":\"go://\"}}"))
    check(c.nextPlace?.id == "hotel" && c.nextPlace?.lat == 33.59, "card next_place")
    check(c.taxi?.url == "go://", "card taxi")
    check(c.legID == "L2", "card leg")
    check(c.rows.count == 1, "card rows unaffected")
    let c2 = try CardInfo.decode(data("{\"where\":\"x\",\"next_place\":null,\"taxi\":null}"))
    check(c2.nextPlace == nil && c2.taxi == nil, "card null v1.1 fields")
    let fs = try FenceInfo.decodeList(data("{\"fences\":[{\"id\":\"f1\",\"lat\":33.5,\"lon\":130.4,\"radius_m\":40,\"on_enter\":{\"say\":\"着いた\",\"script_id\":\"s1\"},\"say_audio\":\"/v1/audio/f1\"},{\"id\":\"bad\"}]}"))
    check(fs.count == 1 && fs[0].scriptID == "s1" && fs[0].radiusM == 40 && fs[0].sayAudio == "/v1/audio/f1", "fences decode")
    let sc = try ScriptInfo.decode(data("{\"id\":\"s1\",\"title\":\"博多駅 筑紫口\",\"steps\":[{\"idx\":1,\"text\":\"右の改札\",\"audio_url\":\"/v1/audio/b\"},{\"idx\":0,\"text\":\"降りたら左\",\"audio_url\":null,\"landmark\":\"時計\"}]}"))
    check(sc.steps.map { $0.idx } == [0, 1] && sc.steps[0].audioURL == nil && sc.steps[0].landmark == "時計", "script decode")
    let ra = try RouteAudio.decode(data("{\"route_id\":\"r1\",\"steps\":[{\"idx\":0,\"text_approach\":\"あと100\",\"audio_approach\":\"/v1/audio/a0\",\"text_at\":\"ここ\",\"audio_at\":\"/v1/audio/t0\"}],\"offroute_audio\":\"/v1/audio/off\",\"arrived_audio\":null}"))
    check(ra.steps[0]?.audioAt == "/v1/audio/t0" && ra.offrouteAudio == "/v1/audio/off" && ra.arrivedAudio == nil, "route audio decode")
    let ev = WSEvent.parse(data("{\"type\":\"script\",\"script_id\":\"s1\",\"action\":\"next\"}"))
    check(ev == .script(id: "s1", stepIdx: nil, action: "next"), "ws script")
} catch {
    check(false, "v1.1 models threw \(error)")
}

print("logic tests: \(passes) passed, \(failures) failed")
if failures > 0 { exit(1) }
