import Foundation

/// WP-2p 2b: 同じ返事を 2 回しゃべらないための判定（純粋関数）。
enum ReplyAudio {
    /// HTTP の返事の audio_url を鳴らすか。
    /// streamed > 0 = サーバーが WS speak で文ごとに流し済み → 鳴らさない。
    /// 同じ URL を最近鳴らしていても鳴らさない。
    static func shouldPlayHTTP(streamed: Int, url: String?, recentlyPlayed: Bool) -> Bool {
        guard let u = url, !u.isEmpty else { return false }
        return streamed <= 0 && !recentlyPlayed
    }
}

/// 鳴らした音声 URL の記録（window 秒以内の再生を「最近」とみなす）。
struct PlayedURLs {
    var window: TimeInterval
    private(set) var times: [String: TimeInterval] = [:]

    init(window: TimeInterval) {
        self.window = window
    }

    mutating func mark(_ url: String, now: TimeInterval) {
        times[url] = now
        if times.count > 200 {
            times = times.filter { now - $0.value < window }
        }
    }

    func recently(_ url: String, now: TimeInterval) -> Bool {
        if let t = times[url], now - t < window { return true }
        return false
    }

    /// 最近鳴らしていなければ記録して true（＝鳴らしてよい）
    mutating func claim(_ url: String, now: TimeInterval) -> Bool {
        if recently(url, now: now) { return false }
        mark(url, now: now)
        return true
    }
}
