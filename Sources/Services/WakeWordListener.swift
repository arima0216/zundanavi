import AVFoundation
import Speech
import os

/// 端末内の SFSpeechRecognizer（ja-JP、on-device 必須）で常時聞き、部分結果を流す。
/// iOS の制限で 1 分前後で切れるので 50 秒ごとに作り直す。
final class WakeWordListener {
    static let log = Logger(subsystem: "dev.momo.zundanavi", category: "wake")
    static let rotateSeconds: TimeInterval = 50

    /// メインスレッドで呼ばれる（今のタスクで認識された全文）
    var onPartial: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var rotateTimer: Timer?
    private var generation = 0
    private(set) var running = false

    /// 端末内認識が使えるか（使えなければウェイクワードは無効にする。音声を Apple に送らない）
    var onDeviceAvailable: Bool {
        guard let r = recognizer else { return false }
        return r.supportsOnDeviceRecognition && r.isAvailable
    }

    static func requestAuthorization() async -> Bool {
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// メインスレッドから呼ぶ
    func start() {
        guard !running else { return }
        guard onDeviceAvailable else {
            WakeWordListener.log.error("on-device recognition unavailable")
            return
        }
        running = true
        beginTask()
    }

    /// メインスレッドから呼ぶ
    func stop() {
        running = false
        rotateTimer?.invalidate()
        rotateTimer = nil
        endTask()
    }

    /// 今のタスクを捨てて新しく始める（ウェイク処理の後で全文をリセットする時も使う）
    func restart() {
        guard running else { return }
        endTask()
        beginTask()
    }

    /// 音声スレッドから呼ばれる
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let r = request
        lock.unlock()
        r?.append(buffer)
    }

    private func beginTask() {
        guard let recognizer = recognizer else { return }
        generation += 1
        let gen = generation
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        req.taskHint = .search
        lock.lock()
        request = req
        lock.unlock()
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            // recognizer.queue は既定でメインキュー
            guard let self = self else { return }
            guard gen == self.generation else { return }
            if let r = result {
                self.onPartial?(r.bestTranscription.formattedString)
                if r.isFinal { self.scheduleRestart(gen, delay: 0.1) }
            }
            if error != nil {
                // 無音が続いた時のエラー等。少し待って作り直す
                self.scheduleRestart(gen, delay: 1.0)
            }
        }
        rotateTimer?.invalidate()
        rotateTimer = Timer.scheduledTimer(withTimeInterval: WakeWordListener.rotateSeconds, repeats: false) { [weak self] _ in
            guard let self = self, gen == self.generation else { return }
            self.restart()
        }
    }

    private func scheduleRestart(_ gen: Int, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.running, gen == self.generation else { return }
            self.restart()
        }
    }

    private func endTask() {
        lock.lock()
        let req = request
        request = nil
        lock.unlock()
        req?.endAudio()
        task?.cancel()
        task = nil
        generation += 1
    }
}
