import Foundation

/// ウェイクワード「ふぇーぶる」の検出と、続く発話の切り出し（文字の上で）。
enum WakeWord {
    /// 正規化後（カタカナ→ひらがな、英字は小文字、全角英数→半角）の候補。長いものから順に試す。
    static let patterns: [String] = ["ふぇーぶる", "ふぇいぶる", "ふぇーぶ", "fable"]

    struct Match: Equatable {
        /// 元の文字列での開始位置（Character 単位）
        var start: Int
        /// ウェイク語の長さ（Character 単位）
        var length: Int
        /// ウェイク語の後ろの文（前後の句読点・空白は除く）
        var after: String
    }

    static func normalize(_ c: Character) -> Character {
        var s = String(c)
        // 全角英数記号 (U+FF01..U+FF5E) を半角へ
        if let u = s.unicodeScalars.first, s.unicodeScalars.count == 1, u.value >= 0xFF01 && u.value <= 0xFF5E,
           let h = Unicode.Scalar(u.value - 0xFEE0) {
            s = String(Character(h))
        }
        if let h = s.applyingTransform(.hiraganaToKatakana, reverse: true) {
            s = h
        }
        s = s.lowercased()
        if s.count == 1, let f = s.first { return f }
        return c
    }

    static func normalize(_ text: String) -> [Character] {
        return text.map { normalize($0) }
    }

    /// 最初に出たウェイク語を探す。
    static func match(in text: String) -> Match? {
        let orig = Array(text)
        let norm = orig.map { normalize($0) }
        let pats = patterns.map { Array($0) }
        if norm.isEmpty { return nil }
        for i in 0..<norm.count {
            for p in pats {
                if i + p.count <= norm.count && Array(norm[i..<(i + p.count)]) == p {
                    let rest = String(orig[(i + p.count)...])
                    return Match(start: i, length: p.count, after: trimPunct(rest))
                }
            }
        }
        return nil
    }

    static func contains(_ text: String) -> Bool {
        return match(in: text) != nil
    }

    static let punct: Set<Character> = [" ", "\u{3000}", "、", "。", ",", ".", "!", "！", "?", "？", "「", "」", "・", "ー", "〜", "~"]

    static func trimPunct(_ s: String) -> String {
        var chars = Array(s)
        while let f = chars.first, punct.contains(f) || f.isWhitespace { chars.removeFirst() }
        while let l = chars.last, (punct.contains(l) && l != "ー") || l.isWhitespace { chars.removeLast() }
        return String(chars)
    }
}

/// ウェイク語の後ろや UI ボタンから来る定型コマンド。
enum VoiceCommand: Equatable {
    case startNav
    case endNav
    case quiet(minutes: Int)
    case plain
}

enum CommandRouter {
    static let startPatterns = ["なびを開始", "なび開始", "なびをすたーと", "なびすたーと", "案内を開始", "案内開始", "なびを始め", "なびをはじめ"]
    static let endPatterns = ["なびを終了", "なび終了", "なびを止め", "なびをとめ", "なびをやめ", "案内を終了", "案内終了"]
    static let quietPatterns = ["静かにして", "しずかにして", "静かに", "しずかに"]
    static let defaultQuietMinutes = 10

    static func route(_ text: String) -> VoiceCommand {
        let n = String(WakeWord.normalize(text)).replacingOccurrences(of: " ", with: "")
        if n.isEmpty { return .plain }
        for p in endPatterns where n.contains(p) { return .endNav }
        for p in startPatterns where n.contains(p) { return .startNav }
        for p in quietPatterns where n.contains(p) {
            return .quiet(minutes: minutes(in: n) ?? defaultQuietMinutes)
        }
        return .plain
    }

    /// 「30分」などの数字（半角化済み）を拾う。
    static func minutes(in normalized: String) -> Int? {
        let chars = Array(normalized)
        guard let idx = chars.firstIndex(of: "分") else { return nil }
        var j = idx - 1
        var digits: [Character] = []
        while j >= 0, chars[j].isASCII, chars[j].isNumber {
            digits.insert(chars[j], at: 0)
            j -= 1
        }
        guard !digits.isEmpty, let v = Int(String(digits)), v > 0 else { return nil }
        return min(v, 600)
    }
}
