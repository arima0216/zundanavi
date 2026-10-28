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

    // MARK: - WP-7: 聞き取り切れ対策

    /// 本文が途中っぽい間に足す無音（秒）
    static let unfinishedExtraSilence: Double = 1.5
    /// 本文が途中っぽい間の上限（秒）。これを過ぎたら認識が止まっていれば送る
    static let unfinishedMaxWait: Double = 10.0

    /// 言い淀み・フィラー（正規化と「ー」除去の後の形）。「あー」「えー」「うーん」「えーと」も含む
    static let fillers: [String] = ["えっと", "えと", "ちょっと", "うん", "あの", "その", "いや", "はい", "あ", "え", "ん", "っ"]
    /// 文がまだ続きそうな末尾（助詞・接続）。v0.2.10: 「て」「の」「から」「けど」は命令・疑問の言い切りにも多いので外す
    static let unfinishedTails: [String] = ["って", "と", "で", "は", "が", "を", "に", "し"]
    /// 疑問詞で終わる倒置の質問（「10時19分に出るって何が」）は言い切りとみなす
    static let questionTails: [String] = ["なにが", "何が", "だれが", "誰が", "どこが", "どれが", "いつが", "なんで", "何で"]
    /// 言い切りの印
    static let sentenceEnds: Set<Character> = ["。", ".", "!", "！", "?", "？"]

    /// 正規化（全角→半角、カタカナ→ひらがな）して空白を除く
    static func compact(_ text: String) -> [Character] {
        return WakeWord.normalize(text).filter { !$0.isWhitespace }
    }

    /// フィラー・言い淀みだけ（その組み合わせを含む）。空文字は false（録音側に任せる）
    static func isFillerOnly(_ text: String) -> Bool {
        let body = compact(text).filter { !WakeWord.punct.contains($0) && !sentenceEnds.contains($0) }
        if body.isEmpty { return false }
        let toks = fillers.map { Array($0) }
        // reach[i] = 先頭 i 文字がフィラーの並びで覆える
        var reach = [Bool](repeating: false, count: body.count + 1)
        reach[0] = true
        for i in 0..<body.count where reach[i] {
            for t in toks {
                if i + t.count <= body.count && Array(body[i..<(i + t.count)]) == t {
                    reach[i + t.count] = true
                }
            }
        }
        return reach[body.count]
    }

    /// ウェイク語の後ろの本文が、まだ言い終わっていなさそうか。
    /// (a) 2 文字以下 (b) フィラーだけ (c) 末尾が助詞・接続・読点 なら true
    static func wakeTextLooksUnfinished(_ text: String) -> Bool {
        var chars = compact(text)
        var ended = false
        while let l = chars.last, sentenceEnds.contains(l) {
            chars.removeLast()
            ended = true
        }
        if !ended, let l = chars.last, l == "、" || l == "," { return true }
        let body = chars.filter { !WakeWord.punct.contains($0) }
        // v0.2.11: 3 文字（「今どこ」「教えて」）は言い切りが多いので 2 文字以下だけ
        if body.count <= 2 { return true }
        let s = String(body)
        if isFillerOnly(s) { return true }
        if ended { return false }
        for q in questionTails where s.hasSuffix(q) { return false }
        for t in unfinishedTails where s.hasSuffix(t) { return true }
        return false
    }

    /// wake モードで切り出しを終えて送るか（AppModel.endTick から呼ぶ）
    static func wakeShouldSend(text: String, elapsed: Double, silentFor: Double, partialIdle: Double, endSilence: Double) -> Bool {
        if text.isEmpty {
            // ウェイク語だけでまだ本文が無い: 少し長めに待つ
            return (elapsed >= 4.0 && wakeQuiet(silentFor: silentFor, partialIdle: partialIdle, endSilence: endSilence)) || elapsed > 8
        }
        if wakeTextLooksUnfinished(text) {
            let longSilence = endSilence + unfinishedExtraSilence
            if elapsed >= 1.5 && wakeQuiet(silentFor: silentFor, partialIdle: partialIdle, endSilence: longSilence) { return true }
            // 上限: 雑音で無音にならなくても、認識が止まっていれば送る（話し続けている間は切らない）
            if elapsed > unfinishedMaxWait && partialIdle >= longSilence { return true }
            return elapsed > 30
        }
        return (elapsed >= 1.5 && wakeQuiet(silentFor: silentFor, partialIdle: partialIdle, endSilence: endSilence)) || elapsed > 30
    }
}
