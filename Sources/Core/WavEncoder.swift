import Foundation

/// 16bit PCM の WAV を作る・音量を測る小道具。
enum WavEncoder {
    static func encode(samples: [Int16], sampleRate: Int, channels: Int = 1) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        var d = Data(capacity: 44 + dataSize)
        d.append(Data("RIFF".utf8))
        appendLE32(&d, UInt32(36 + dataSize))
        d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8))
        appendLE32(&d, 16)
        appendLE16(&d, 1) // PCM
        appendLE16(&d, UInt16(channels))
        appendLE32(&d, UInt32(sampleRate))
        appendLE32(&d, UInt32(sampleRate * channels * bytesPerSample))
        appendLE16(&d, UInt16(channels * bytesPerSample))
        appendLE16(&d, 16)
        d.append(Data("data".utf8))
        appendLE32(&d, UInt32(dataSize))
        for s in samples {
            appendLE16(&d, UInt16(bitPattern: s))
        }
        return d
    }

    static func encode(floats: [Float], sampleRate: Int) -> Data {
        return encode(samples: floatToInt16(floats), sampleRate: sampleRate)
    }

    static func floatToInt16(_ f: [Float]) -> [Int16] {
        return f.map { v -> Int16 in
            let c = max(-1.0, min(1.0, v))
            return Int16(c * 32767.0)
        }
    }

    static func rms(_ f: [Float]) -> Float {
        if f.isEmpty { return 0 }
        var sum: Float = 0
        for v in f { sum += v * v }
        return (sum / Float(f.count)).squareRoot()
    }

    /// 内蔵の短いビープ（フィラーが取れない時の代替）。
    static func beep(frequency: Double = 880, duration: Double = 0.15, sampleRate: Int = 16000, volume: Double = 0.3) -> Data {
        let n = Int(duration * Double(sampleRate))
        var s = [Int16](repeating: 0, count: n)
        let fade = max(1, Int(0.01 * Double(sampleRate)))
        for i in 0..<n {
            var env = 1.0
            if i < fade { env = Double(i) / Double(fade) }
            if i > n - fade { env = Double(n - i) / Double(fade) }
            let v = sin(2.0 * Double.pi * frequency * Double(i) / Double(sampleRate)) * volume * env
            s[i] = Int16(v * 32767.0)
        }
        return encode(samples: s, sampleRate: sampleRate)
    }

    private static func appendLE32(_ d: inout Data, _ v: UInt32) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
    }

    private static func appendLE16(_ d: inout Data, _ v: UInt16) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
    }
}
