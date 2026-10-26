import AVFoundation
import os

/// 端末合成（AVSpeechSynthesizer, ja-JP 既定の声）を WAV にして、既存の再生キューに載せる。
/// サーバー不通や 404 の時のフォールバック。
@MainActor
final class LocalTTS {
    nonisolated static let log = Logger(subsystem: "dev.momo.zundanavi", category: "tts")

    private var synths: [AVSpeechSynthesizer] = []

    func synthesize(_ text: String) async -> Data? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        let synth = AVSpeechSynthesizer()
        synth.usesApplicationAudioSession = true
        synths.append(synth)
        let utt = AVSpeechUtterance(string: t)
        utt.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        utt.rate = AVSpeechUtteranceDefaultSpeechRate
        let collector = PCMCollector()
        let data: Data? = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            collector.onFinish = { d in cont.resume(returning: d) }
            synth.write(utt) { buffer in
                collector.add(buffer)
            }
            // 終わりの合図（空バッファ）が来ない時の保険
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                collector.finish()
            }
        }
        synths.removeAll { $0 === synth }
        return data
    }
}

/// write(_:toBufferCallback:) のバッファを集める（コールバックは任意スレッド）。
final class PCMCollector: @unchecked Sendable {
    var onFinish: ((Data?) -> Void)?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 22050
    private var done = false

    func add(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 {
            finish()
            return
        }
        let n = Int(pcm.frameLength)
        var chunk: [Float] = []
        chunk.reserveCapacity(n)
        if let f = pcm.floatChannelData {
            for i in 0..<n { chunk.append(f[0][i]) }
        } else if let s = pcm.int16ChannelData {
            for i in 0..<n { chunk.append(Float(s[0][i]) / 32768.0) }
        } else if let s = pcm.int32ChannelData {
            for i in 0..<n { chunk.append(Float(s[0][i]) / 2147483648.0) }
        }
        lock.lock()
        sampleRate = pcm.format.sampleRate
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        let s = samples
        let rate = sampleRate
        let cb = onFinish
        onFinish = nil
        lock.unlock()
        if s.isEmpty {
            cb?(nil)
        } else {
            cb?(WavEncoder.encode(floats: s, sampleRate: Int(rate)))
        }
    }
}
