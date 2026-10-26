import AVFoundation
import Combine
import CoreLocation
import SwiftUI
import UIKit
import os

/// アプリ全体の司令塔。録音・ウェイクワード・送信・再生・GPS・WS をつなぐ。
@MainActor
final class AppModel: ObservableObject {
    nonisolated static let log = Logger(subsystem: "dev.momo.zundanavi", category: "app")

    static let fillerNames = ["thinking", "offline", "heard"]
    static let sampleRate = 16000
    static let loudThreshold: Float = 0.012
    static let tapThreshold: TimeInterval = 0.35

    enum ListenState {
        case idle, recording, wakeCapture
    }

    let settings: AppSettings
    let history: HistoryStore
    let location = LocationService()
    let events = EventsClient()
    let speech = SpeechQueue()
    let battery = BatteryLogger()
    private let capture = AudioCapture()
    private let wake = WakeWordListener()
    // WP-2n: 徒歩ナビ・ジオフェンス・台本・デッキ（処理は AppModel+Nav.swift）
    let nav = NavEngine()
    let script = ScriptPlayer()
    let localTTS = LocalTTS()
    var fenceTracker = FenceTracker()
    @Published var fences: [FenceInfo] = []
    @Published var deck: ActionDeck?
    @Published var activeSheet: ActiveSheet?
    @Published var navActive = false
    var lastLegID: String?
    /// 最近ローカルで鳴らした音声 URL（サーバー push との二重再生を防ぐ）
    var recentAudio = PlayedURLs(window: 180)

    @Published private(set) var listenState: ListenState = .idle
    @Published private(set) var busyCount = 0
    @Published private(set) var serverOK: Bool?
    @Published private(set) var serverDetail = ""
    @Published var offlineBanner: String?
    @Published var card: CardInfo?
    /// 返事エリア（考え中・返事・失敗）。履歴は HistoryStore 側に残る
    @Published private(set) var reply = ReplyPane()
    var lastReply: String { return reply.text }
    /// WP-2q: 直前に送った文（返事の上に吹き出しで出す）
    @Published private(set) var lastAsked = ""
    @Published var toast: String?
    @Published private(set) var wsConnected = false
    @Published private(set) var gpsText = "GPS --"
    @Published private(set) var micReady = false
    @Published private(set) var wakeActive = false
    @Published private(set) var testResult = ""
    @Published private(set) var isToggleRecording = false
    /// WP-2o: 入力レベル（RMS）の見える化。10 回/秒まで
    @Published private(set) var inputLevel: Float = 0
    private var levelPublishedAt = Date.distantPast

    private var fillers: [String: Data] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var bootstrapped = false

    // 押して話す
    private enum RecMode { case off, hold, toggle }
    private var recMode: RecMode = .off
    private var pressStartedAt = Date()
    private var ignoreNextRelease = false
    private var recordStartedAt = Date()
    private var speechSeenInRecording = false

    // ウェイクワード後の切り出し
    private var wakeStartedAt = Date()
    private var wakeLastPartialAt = Date()
    private var wakeLastPartialText = ""
    private var wakeAfterText = ""

    private var lastLoudAt = Date.distantPast
    private var endTimer: Timer?
    private var positionTimer: Timer?
    private var healthTimer: Timer?
    private var lastPositionSentAt = Date.distantPast
    private var lastPositionSent: CLLocation?
    /// request_id ごとに鳴らした text_voice（文字先行→音声後追いの二重再生を防ぐ）
    private var spokenReplies: [String: [String]] = [:]

    init() {
        settings = AppSettings()
        history = HistoryStore()
        loadFillersFromDisk()
    }

    var api: APIClient {
        return APIClient(baseURL: settings.serverURL, token: settings.token)
    }

    // MARK: - 起動

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        events.makeRequest = { [weak self] in
            return self?.api.eventsRequest()
        }
        events.onEvent = { [weak self] ev, raw in
            self?.handleEvent(ev, raw: raw)
        }
        events.$connected
            .receive(on: RunLoop.main)
            .sink { [weak self] v in self?.wsConnected = v }
            .store(in: &cancellables)
        location.$last
            .receive(on: RunLoop.main)
            .sink { [weak self] l in
                if let l = l, l.horizontalAccuracy >= 0 {
                    self?.gpsText = "GPS ±" + String(Int(l.horizontalAccuracy.rounded())) + "m"
                } else {
                    self?.gpsText = "GPS --"
                }
            }
            .store(in: &cancellables)
        location.onUpdate = { [weak self] l in
            self?.locationUpdated(l)
            self?.navLocationUpdated(l)
        }
        setUpNav()
        wake.onPartial = { [weak self] text in
            self?.wakePartial(text)
        }
        AppModel.wireAudio(capture: capture, wake: wake, model: self)
        observeSession()

        Task {
            await startUp()
        }
    }

    /// 音声スレッドで呼ばれるクロージャはアクター外で作る。
    nonisolated private static func wireAudio(capture: AudioCapture, wake: WakeWordListener, model: AppModel) {
        capture.onNativeBuffer = { [weak wake] buf in
            wake?.append(buf)
        }
        capture.onLevel = { [weak model] level in
            Task { @MainActor in
                model?.levelUpdated(level)
            }
        }
    }

    private func startUp() async {
        // 権限の順: マイク → 音声認識 → 位置（WhenInUse → Always）
        let micOK = await AVAudioApplication.requestRecordPermission()
        do {
            try AudioSessionController.configure(mic: settings.micSource)
        } catch {
            AppModel.log.error("session configure failed: \(error.localizedDescription, privacy: .public)")
        }
        if micOK {
            do {
                try capture.start()
                micReady = true
            } catch {
                AppModel.log.error("capture start failed: \(error.localizedDescription, privacy: .public)")
                showToast("マイクを開けないのだ")
            }
        } else {
            showToast("マイクが許可されていないのだ（設定アプリで許可して）")
        }
        if settings.wakeWordEnabled {
            let ok = await WakeWordListener.requestAuthorization()
            if ok { startWakeIfPossible() }
        }
        location.start()
        startTimers()
        battery.setEnabled(settings.batteryLogEnabled)
        await refreshAll(announceOffline: true)
    }

    func becameActive() {
        guard bootstrapped else { return }
        Task {
            await checkHealth(announce: false)
            await refreshCard()
        }
        events.start()
        if micReady && !capture.isRunning {
            capture.restart()
        }
    }

    private func startTimers() {
        positionTimer?.invalidate()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.positionTick()
            }
        }
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                _ = await self?.checkHealth(announce: false)
            }
        }
    }

    func refreshAll(announceOffline: Bool) async {
        let ok = await checkHealth(announce: announceOffline)
        if ok {
            await loadFillers()
            await refreshCard()
        }
        events.restart()
    }

    // MARK: - サーバー状態

    @discardableResult
    func checkHealth(announce: Bool) async -> Bool {
        let wasOK = serverOK
        do {
            let h = try await api.health()
            serverOK = h.ok
            serverDetail = h.summary
            offlineBanner = h.ok ? nil : "サーバーが不調なのだ: " + h.summary
            return h.ok
        } catch {
            serverOK = false
            serverDetail = error.localizedDescription
            if let e = error as? APIError, case .unauthorized = e {
                offlineBanner = "トークンが違うのだ（設定を確認）"
            } else {
                offlineBanner = "サーバーにつながらないのだ"
            }
            if announce || wasOK == true {
                playFiller("offline")
            }
            return false
        }
    }

    func testConnection() {
        testResult = "確認中..."
        Task {
            do {
                let h = try await api.health()
                testResult = "OK: " + h.summary
            } catch {
                testResult = "NG: " + error.localizedDescription
            }
            await refreshAll(announceOffline: false)
        }
    }

    func applyServerSettings() {
        Task {
            await refreshAll(announceOffline: false)
        }
    }

    func refreshCard() async {
        do {
            setCard(try await api.card())
        } catch {
            AppModel.log.info("card fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshHistory() async {
        do {
            let items = try await api.history(limit: 20)
            history.merge(server: items)
        } catch {
            AppModel.log.info("history fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - フィラー

    private var fillerDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("fillers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadFillersFromDisk() {
        for n in AppModel.fillerNames {
            if let d = try? Data(contentsOf: fillerDir.appendingPathComponent(n + ".wav")) {
                fillers[n] = d
            }
        }
    }

    private func loadFillers() async {
        let api = self.api
        for n in AppModel.fillerNames {
            do {
                let d = try await api.filler(n)
                fillers[n] = d
                try? d.write(to: fillerDir.appendingPathComponent(n + ".wav"), options: .atomic)
            } catch {
                AppModel.log.info("filler \(n, privacy: .public) unavailable")
            }
        }
    }

    func playFiller(_ name: String) {
        let data: Data
        if let d = fillers[name] {
            data = d
        } else {
            switch name {
            case "offline": data = WavEncoder.beep(frequency: 440, duration: 0.3)
            case "heard": data = WavEncoder.beep(frequency: 1320, duration: 0.08)
            default: data = WavEncoder.beep()
            }
        }
        speech.playFiller(data)
    }

    // MARK: - 状態表示

    var isRecordingAny: Bool {
        return listenState == .recording || listenState == .wakeCapture
    }

    var listenText: String {
        switch listenState {
        case .recording: return "聞き取り中"
        case .wakeCapture: return "聞き取り中(ふぇーぶる)"
        case .idle:
            if busyCount > 0 { return "考え中" }
            if speech.isPlaying { return "再生中" }
            return wakeActive ? "待受中(ふぇーぶる)" : "待受中"
        }
    }

    var routeText: String {
        return AudioSessionController.routeDescription
    }

    func showToast(_ text: String) {
        toast = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if self?.toast == text { self?.toast = nil }
        }
    }

    // MARK: - 押して話す（押している間だけ録音／1 回タップ=開始→無音 1.2 秒で自動終了）

    var pttLabel: String {
        if listenState == .recording {
            return recMode == .toggle ? "話して\n(無音で送信)" : "離すと送信"
        }
        return "押して話す"
    }

    func pttDown() {
        guard micReady else {
            showToast("マイクが使えないのだ")
            return
        }
        if recMode == .toggle {
            ignoreNextRelease = true
            finishRecording()
            return
        }
        guard recMode == .off else { return }
        if listenState == .wakeCapture {
            endWakeCapture(send: false)
        }
        recMode = .hold
        pressStartedAt = Date()
        recordStartedAt = Date()
        speechSeenInRecording = false
        capture.beginCapture(prerollSeconds: 0.2)
        listenState = .recording
        startEndTimer()
    }

    func pttUp() {
        if ignoreNextRelease {
            ignoreNextRelease = false
            return
        }
        guard recMode == .hold else { return }
        if Date().timeIntervalSince(pressStartedAt) < AppModel.tapThreshold {
            recMode = .toggle
            isToggleRecording = true
            return
        }
        finishRecording()
    }

    private func finishRecording() {
        let samples = capture.endCapture()
        recMode = .off
        isToggleRecording = false
        listenState = .idle
        guard samples.count > AppModel.sampleRate * 3 / 10 else { return }
        playFiller("heard")
        let wav = WavEncoder.encode(floats: samples, sampleRate: AppModel.sampleRate)
        let rid = UUID().uuidString
        Task {
            await performAsk(text: nil, wav: wav, mode: "voice", requestID: rid, primary: true)
        }
    }

    private func cancelRecording() {
        capture.cancelCapture()
        recMode = .off
        isToggleRecording = false
        listenState = .idle
    }

    private func levelUpdated(_ level: Float) {
        let t = Date()
        if t.timeIntervalSince(levelPublishedAt) >= 0.1 {
            levelPublishedAt = t
            inputLevel = level
        }
        if level >= AppModel.loudThreshold {
            lastLoudAt = Date()
            if listenState == .recording { speechSeenInRecording = true }
        }
    }

    private func startEndTimer() {
        endTimer?.invalidate()
        endTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.endTick()
            }
        }
    }

    private func stopEndTimer() {
        endTimer?.invalidate()
        endTimer = nil
    }

    private func endTick() {
        let now = Date()
        switch listenState {
        case .recording:
            let elapsed = now.timeIntervalSince(recordStartedAt)
            if recMode == .toggle {
                let silentFor = now.timeIntervalSince(max(lastLoudAt, recordStartedAt))
                if Endpointing.tapShouldEnd(speechSeen: speechSeenInRecording, silentFor: silentFor, endSilence: settings.endSilenceSec) {
                    finishRecording()
                } else if !speechSeenInRecording && elapsed > 6 {
                    cancelRecording()
                    showToast("声が聞こえなかったのだ")
                } else if elapsed > 60 {
                    finishRecording()
                }
            } else if recMode == .hold && elapsed > 120 {
                finishRecording()
            }
        case .wakeCapture:
            let elapsed = now.timeIntervalSince(wakeStartedAt)
            let partialIdle = now.timeIntervalSince(wakeLastPartialAt)
            let silentFor = now.timeIntervalSince(max(lastLoudAt, wakeStartedAt))
            let quiet = Endpointing.wakeQuiet(silentFor: silentFor, partialIdle: partialIdle, endSilence: settings.endSilenceSec)
            if wakeAfterText.isEmpty {
                // ウェイク語だけでまだ本文が無い: 少し長めに待つ
                if (elapsed >= 4.0 && quiet) || elapsed > 8 {
                    endWakeCapture(send: true)
                }
            } else if elapsed >= 1.5 && quiet {
                endWakeCapture(send: true)
            } else if elapsed > 30 {
                endWakeCapture(send: true)
            }
        case .idle:
            stopEndTimer()
        }
    }

    // MARK: - ウェイクワード

    func setWakeEnabled(_ on: Bool) {
        if on {
            Task {
                let ok = await WakeWordListener.requestAuthorization()
                if ok {
                    startWakeIfPossible()
                } else {
                    showToast("音声認識が許可されていないのだ")
                }
            }
        } else {
            wake.stop()
            wakeActive = false
            if listenState == .wakeCapture { endWakeCapture(send: false) }
        }
    }

    private func startWakeIfPossible() {
        guard micReady else { return }
        wake.start()
        wakeActive = wake.running
        if !wakeActive {
            showToast("端末内の日本語音声認識が使えないのだ（ウェイクワード無効）")
        }
    }

    private func wakePartial(_ text: String) {
        guard settings.wakeWordEnabled else { return }
        switch listenState {
        case .wakeCapture:
            if text != wakeLastPartialText {
                wakeLastPartialText = text
                wakeLastPartialAt = Date()
                if let m = WakeWord.match(in: text) {
                    wakeAfterText = m.after
                }
            }
        case .idle:
            guard let m = WakeWord.match(in: text) else { return }
            // ウェイク検出の 1 秒前から切り出す（リングバッファは直近 2 秒）
            capture.beginCapture(prerollSeconds: 1.0)
            listenState = .wakeCapture
            wakeStartedAt = Date()
            wakeLastPartialAt = Date()
            wakeLastPartialText = text
            wakeAfterText = m.after
            AppModel.log.info("wake word detected")
            // 聞き始めの合図（短いビープ）。「heard」は切り出し終了後に鳴らす
            speech.playFiller(WavEncoder.beep(frequency: 1320, duration: 0.08))
            startEndTimer()
        case .recording:
            break
        }
    }

    private func endWakeCapture(send: Bool) {
        let samples = capture.endCapture()
        listenState = .idle
        let text = wakeAfterText.trimmingCharacters(in: .whitespacesAndNewlines)
        wakeAfterText = ""
        wakeLastPartialText = ""
        // 認識の全文をリセットする
        wake.restart()
        guard send else { return }

        switch CommandRouter.route(text) {
        case .quiet(let minutes):
            quiet(minutes: minutes)
        case .startNav:
            startNavLocal()
        case .endNav:
            stopNavLocal()
        case .plain:
            break
        }

        playFiller("heard")
        let rid = UUID().uuidString
        let wav: Data? = samples.count > AppModel.sampleRate * 3 / 10 ? WavEncoder.encode(floats: samples, sampleRate: AppModel.sampleRate) : nil
        if !text.isEmpty {
            history.add(HistoryEntry(role: "user", text: text))
            lastAsked = text
            reply.asked(requestID: rid)
            // ①端末内の認識文を即時に送る ②同じ request_id で録音を後追い
            Task {
                await performAsk(text: text, wav: nil, mode: "voice", requestID: rid, primary: true)
            }
            if let w = wav {
                Task {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    await performAsk(text: nil, wav: w, mode: "voice", requestID: rid, primary: false)
                }
            }
        } else if let w = wav {
            reply.asked(requestID: rid)
            Task {
                await performAsk(text: nil, wav: w, mode: "voice", requestID: rid, primary: true)
            }
        }
    }

    // MARK: - 送信と返事

    func askText(_ raw: String, mode: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        history.add(HistoryEntry(role: "user", text: t))
        lastAsked = TextFirst.stripFable(t)
        let rid = UUID().uuidString
        reply.asked(requestID: rid)
        Task {
            await performAsk(text: t, wav: nil, mode: mode, requestID: rid, primary: true)
        }
    }

    func quiet(minutes: Int) {
        let api = self.api
        Task {
            do {
                try await api.quiet(minutes: minutes)
                showToast(String(minutes) + "分 静かにするのだ")
            } catch {
                reportFailure(error)
            }
        }
    }

    private func performAsk(text: String?, wav: Data?, mode: String, requestID: String, primary: Bool) async {
        busyCount += 1
        if primary { playFiller("thinking") }
        let api = self.api
        let gps = gpsForAsk
        do {
            let r = try await api.ask(text: text, audioWav: wav, gps: gps, mode: mode, requestID: requestID)
            busyCount -= 1
            serverOK = true
            offlineBanner = nil
            handleReply(r, requestID: requestID, userText: text)
        } catch {
            busyCount -= 1
            AppModel.log.error("ask failed: \(error.localizedDescription, privacy: .public)")
            if primary {
                speech.cancelFillers()
                reportFailure(error)
                reply.failed(requestID: requestID, message: AppModel.failureText(error))
            }
        }
    }

    private func handleReply(_ r: AskResponse, requestID: String, userText: String?) {
        let voice = r.textVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        var played = spokenReplies[requestID] ?? []
        if userText == nil, played.isEmpty, let tr = r.transcript, !tr.isEmpty {
            history.add(HistoryEntry(role: "user", text: tr))
            lastAsked = tr
        }
        // 後追いの返事が同じ内容（または空）なら鳴らさない
        if !played.isEmpty && (voice.isEmpty || played.contains(voice)) {
            return
        }
        played.append(voice)
        spokenReplies[requestID] = played
        if spokenReplies.count > 50 { spokenReplies = [requestID: played] }

        reply.replied(r.textFull)
        history.add(HistoryEntry(role: "assistant", text: r.textFull, audioURL: r.audioURL))
        let url = r.audioURL
        let recent = url.map { recentlyPlayed($0) } ?? false
        if ReplyAudio.shouldPlayHTTP(streamed: r.streamed, url: url, recentlyPlayed: recent), let u = url {
            markPlayed(u)
            let item = speech.enqueueAnswer()
            fetchAudio(u, into: item)
        } else {
            // WS speak で流し済み（streamed>0）か同じ URL を鳴らした後
            if url != nil { AppModel.log.info("http audio skipped streamed=\(r.streamed) recent=\(recent)") }
            speech.cancelFillers()
        }
    }

    func fetchAudio(_ url: String, into item: SpeechQueue.Item) {
        let api = self.api
        Task {
            var data: Data?
            do {
                data = try await api.fetchAudio(url)
            } catch {
                AppModel.log.error("audio fetch failed: \(error.localizedDescription, privacy: .public)")
            }
            speech.setData(item, data)
        }
    }

    static func failureText(_ error: Error) -> String {
        var timedOut = false
        if let u = error as? URLError, u.code == .timedOut { timedOut = true }
        var auth = false
        if let e = error as? APIError, case .unauthorized = e { auth = true }
        return ReplyPane.failureMessage(timedOut: timedOut, unauthorized: auth)
    }

    private func reportFailure(_ error: Error) {
        serverOK = false
        if let e = error as? APIError, case .unauthorized = e {
            offlineBanner = "トークンが違うのだ（設定を確認）"
        } else {
            offlineBanner = "サーバーにつながらないのだ"
        }
        playFiller("offline")
    }

    func replay(_ e: HistoryEntry) {
        guard let url = e.audioURL else {
            showToast("この行には音声が無いのだ")
            return
        }
        let api = self.api
        Task {
            do {
                let d = try await api.fetchAudio(url)
                speech.replay(d)
            } catch {
                showToast("音声が取れないのだ")
            }
        }
    }

    // MARK: - 写真

    func sendPhoto(_ image: UIImage, note: String?) {
        guard let jpeg = AppModel.jpeg(image, maxSide: 1600) else {
            showToast("写真を変換できないのだ")
            return
        }
        let n = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        history.add(HistoryEntry(role: "user", text: "[写真] " + (n ?? "")))
        let api = self.api
        let gps = gpsForAsk
        let rid = UUID().uuidString
        lastAsked = "[写真] " + (n ?? "")
        reply.asked(requestID: rid)
        Task {
            busyCount += 1
            playFiller("thinking")
            do {
                let r = try await api.photo(jpeg: jpeg, note: n, gps: gps)
                busyCount -= 1
                handleReply(r, requestID: rid, userText: "[写真]")
            } catch {
                busyCount -= 1
                speech.cancelFillers()
                reportFailure(error)
                reply.failed(requestID: rid, message: AppModel.failureText(error))
            }
        }
    }

    static func jpeg(_ img: UIImage, maxSide: CGFloat) -> Data? {
        let size = img.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let newSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: fmt)
        let out = renderer.image { _ in
            img.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return out.jpegData(compressionQuality: 0.8)
    }

    // MARK: - GPS

    private var gpsForAsk: GPSFix? {
        return settings.gpsSendEnabled ? location.fix : nil
    }

    private func locationUpdated(_ l: CLLocation) {
        guard settings.gpsSendEnabled else { return }
        if let prev = lastPositionSent {
            if l.distance(from: prev) >= 15 { sendPosition(l) }
        } else {
            sendPosition(l)
        }
    }

    private func positionTick() {
        guard settings.gpsSendEnabled, let l = location.last else { return }
        if Date().timeIntervalSince(lastPositionSentAt) >= 10 {
            sendPosition(l)
        }
    }

    private func sendPosition(_ l: CLLocation) {
        lastPositionSentAt = Date()
        lastPositionSent = l
        let fix = LocationService.fix(from: l)
        let api = self.api
        Task {
            do {
                try await api.position(fix)
            } catch {
                // 404（サーバーに未実装）などは無視して続ける
            }
        }
    }

    // MARK: - WS イベント

    private func handleEvent(_ ev: WSEvent, raw: Data) {
        switch ev {
        case .speak(let seq, let url, let text):
            if !text.isEmpty {
                reply.replied(text)
                history.add(HistoryEntry(role: "push", text: text, audioURL: url))
            }
            if let u = url, !recentlyPlayed(u) {
                markPlayed(u)
                let item = speech.enqueueSpeak(seq: seq)
                fetchAudio(u, into: item)
            }
        case .alert(let level, let textVoice, let url):
            showToast(textVoice)
            history.add(HistoryEntry(role: "push", text: "[" + level + "] " + textVoice, audioURL: url))
            if let u = url {
                let item = speech.enqueueAlert()
                fetchAudio(u, into: item)
            }
        case .card(let c):
            setCard(c)
        case .deck(let count):
            AppModel.log.info("deck event items=\(count)")
            if let d = ActionDeck.parse(raw) {
                receiveDeck(d)
            }
        case .script(let id, let stepIdx, let action):
            scriptEvent(id: id, stepIdx: stepIdx, action: action)
        case .unknown(let t):
            AppModel.log.info("unknown ws event \(t, privacy: .public)")
        }
    }

    // MARK: - 音声セッションの復旧（片耳の入れ替え・割り込み）

    func setMic(_ m: MicSource) {
        do {
            try AudioSessionController.configure(mic: m)
        } catch {
            AppModel.log.error("mic switch failed: \(error.localizedDescription, privacy: .public)")
        }
        if micReady { capture.restart() }
        if wakeActive { wake.restart() }
    }

    private func observeSession() {
        let nc = NotificationCenter.default
        nc.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] n in
                guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .ended {
                    self?.recoverAudio(full: true)
                }
            }
            .store(in: &cancellables)
        nc.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] n in
                guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
                if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable {
                    self?.recoverAudio(full: false)
                }
            }
            .store(in: &cancellables)
        nc.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.recoverAudio(full: true)
            }
            .store(in: &cancellables)
    }

    private func recoverAudio(full: Bool) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self = self else { return }
            if full {
                do {
                    try AudioSessionController.configure(mic: self.settings.micSource)
                } catch {
                    AppModel.log.error("session reactivate failed: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                try? AVAudioSession.sharedInstance().setActive(true)
                AudioSessionController.applyPreferredInput(self.settings.micSource)
            }
            if self.micReady && (full || !self.capture.isRunning) {
                self.capture.restart()
            }
            if self.wakeActive { self.wake.restart() }
            AppModel.log.info("audio recovered route=\(AudioSessionController.routeDescription, privacy: .public)")
        }
    }
}
