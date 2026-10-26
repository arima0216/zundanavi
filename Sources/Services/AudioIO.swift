import AVFoundation
import os

/// AVAudioSession の設定（DESIGN §21: playAndRecord + allowBluetooth で HFP 張りっぱなし）。
enum AudioSessionController {
    static let log = Logger(subsystem: "dev.momo.zundanavi", category: "session")

    static func configure(mic: MicSource) throws {
        let s = AVAudioSession.sharedInstance()
        var opts: AVAudioSession.CategoryOptions = [.allowBluetooth, .duckOthers, .defaultToSpeaker]
        if mic == .builtIn {
            // 本体マイクの時は出力をイヤホンの A2DP に逃がせるようにする
            opts.insert(.allowBluetoothA2DP)
        }
        try s.setCategory(.playAndRecord, mode: .voiceChat, options: opts)
        try s.setActive(true)
        applyPreferredInput(mic)
        log.info("session active route=\(routeDescription, privacy: .public)")
    }

    static func applyPreferredInput(_ mic: MicSource) {
        let s = AVAudioSession.sharedInstance()
        guard let inputs = s.availableInputs else { return }
        switch mic {
        case .builtIn:
            if let p = inputs.first(where: { $0.portType == .builtInMic }) {
                try? s.setPreferredInput(p)
            }
        case .earphone:
            if let p = inputs.first(where: { $0.portType == .bluetoothHFP }) {
                try? s.setPreferredInput(p)
            } else {
                try? s.setPreferredInput(nil)
            }
        }
    }

    static var routeDescription: String {
        let r = AVAudioSession.sharedInstance().currentRoute
        let i = r.inputs.map { $0.portName }.joined(separator: ",")
        let o = r.outputs.map { $0.portName }.joined(separator: ",")
        return "in[" + i + "] out[" + o + "]"
    }
}

/// マイク入力を 1 本の AVAudioEngine で受け、
/// ・端末内認識（ウェイクワード）へ元の形式のまま渡す
/// ・16kHz mono に変換して直近 2 秒のリングバッファに溜める
/// ・録音中は切り出しバッファにも溜める
/// タップのコールバックは音声スレッドなので内部はロックで守る。
final class AudioCapture {
    static let log = Logger(subsystem: "dev.momo.zundanavi", category: "capture")
    static let sampleRate: Double = 16000

    /// 音声スレッドから呼ばれる（元形式のバッファ）
    var onNativeBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// 音声スレッドから呼ばれる（16kHz の RMS）
    var onLevel: ((Float) -> Void)?

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioCapture.sampleRate, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var ring: [Float] = []
    private let ringMax = Int(AudioCapture.sampleRate * 2)
    private var capturing = false
    private var captured: [Float] = []
    private var configObserver: NSObjectProtocol?

    var isRunning: Bool { return engine.isRunning }

    init() {
        observeConfigChange()
    }

    deinit {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
    }

    private func observeConfigChange() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            AudioCapture.log.info("engine configuration change -> restart")
            self?.restart()
        }
    }

    func start() throws {
        if engine.isRunning { return }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw NSError(domain: "ZundaNavi", code: 1, userInfo: [NSLocalizedDescriptionKey: "マイク入力が無いのだ"])
        }
        let conv = AVAudioConverter(from: fmt, to: targetFormat)
        conv?.downmix = true
        converter = conv
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            self?.process(buf)
        }
        engine.prepare()
        try engine.start()
        AudioCapture.log.info("engine started sr=\(fmt.sampleRate) ch=\(fmt.channelCount)")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// 経路が変わった時など。エンジンを作り直して再開する。
    func restart() {
        stop()
        engine = AVAudioEngine()
        observeConfigChange()
        do {
            try start()
        } catch {
            AudioCapture.log.error("engine restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        onNativeBuffer?(buf)
        guard let conv = converter else { return }
        let ratio = targetFormat.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buf
        }
        if status == .error { return }
        guard let ch = out.floatChannelData, out.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        let level = WavEncoder.rms(samples)
        lock.lock()
        ring.append(contentsOf: samples)
        if ring.count > ringMax { ring.removeFirst(ring.count - ringMax) }
        if capturing { captured.append(contentsOf: samples) }
        lock.unlock()
        onLevel?(level)
    }

    /// 切り出し開始。preroll 秒ぶんリングバッファから前置きを入れる。
    func beginCapture(prerollSeconds: Double) {
        lock.lock()
        let n = min(ring.count, Int(prerollSeconds * AudioCapture.sampleRate))
        captured = n > 0 ? Array(ring.suffix(n)) : []
        capturing = true
        lock.unlock()
    }

    /// 切り出し終了。16kHz mono の Float を返す。
    func endCapture() -> [Float] {
        lock.lock()
        let out = captured
        captured = []
        capturing = false
        lock.unlock()
        return out
    }

    func cancelCapture() {
        _ = endCapture()
    }

    var isCapturing: Bool {
        lock.lock()
        let c = capturing
        lock.unlock()
        return c
    }
}
