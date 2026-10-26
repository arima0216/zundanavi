import Foundation

/// 話し終わり判定（WP-2o）。UI から切り離した純粋関数。
enum Endpointing {
    /// 設定「話し終わりの間」の選択肢（秒）
    static let choices: [Double] = [1.5, 2.0, 2.5, 3.0]
    static let defaultEndSilence: Double = 2.0
    /// wake モードで「部分認識も止まっている」とみなす最小時間
    static let partialIdleMin: Double = 0.6

    /// 保存値の検査（範囲外や壊れた値は既定値）
    static func normalize(_ v: Double) -> Double {
        if v.isNaN || v < 1.0 || v > 5.0 { return defaultEndSilence }
        return v
    }

    /// tap（短押し→自動終了）: 声を聞いたあと、音量の無音が endSilence 続いたら終わり
    static func tapShouldEnd(speechSeen: Bool, silentFor: Double, endSilence: Double) -> Bool {
        return speechSeen && silentFor >= endSilence
    }

    /// wake モードの「静か」: 音量の無音が必須。部分認識の停止だけでは終わらせない
    static func wakeQuiet(silentFor: Double, partialIdle: Double, endSilence: Double) -> Bool {
        return silentFor >= endSilence && partialIdle >= partialIdleMin
    }
}
