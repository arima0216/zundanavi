import Foundation

/// WP-2p: 文字ファースト UI の純粋関数（チップ・送信履歴・Fable 呼びかけ）。
enum TextFirst {
    /// 定型チップ（タップで即送信）
    static let presets = ["今どこ", "次は？", "あと何分", "静かにして", "タクシー"]
    /// 「Fable に聞く」ON のとき先頭に付ける呼びかけ
    static let fablePrefix = "ふぇーぶる、"

    /// 送信文に呼びかけを付ける（既に付いていれば二重にしない）
    static func applyFable(_ text: String, on: Bool) -> String {
        guard on else { return text }
        if text.hasPrefix("ふぇーぶる") || text.hasPrefix("フェーブル") { return text }
        return fablePrefix + text
    }

    /// 呼びかけを外した本文（履歴チップの表示と重複判定用）
    static func stripFable(_ text: String) -> String {
        for p in [fablePrefix, "ふぇーぶる,", "ふぇーぶる ", "ふぇーぶる"] where text.hasPrefix(p) {
            return String(text.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// 送信履歴チップ: 古い→新しい順の送信文から、新しい順に重複なしで limit 件。
    /// 定型と同じ文・写真・空は除く。
    static func recentSends(_ textsOldestFirst: [String], limit: Int = 5) -> [String] {
        var out: [String] = []
        for raw in textsOldestFirst.reversed() {
            let t = stripFable(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            if t.isEmpty || t.hasPrefix("[写真]") || presets.contains(t) || out.contains(t) { continue }
            out.append(t)
            if out.count >= limit { break }
        }
        return out
    }

    /// チップ用に短くする（12 字＋…）
    static func short(_ text: String, max: Int = 12) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ")
        if one.count <= max { return one }
        return String(one.prefix(max)) + "…"
    }
}
