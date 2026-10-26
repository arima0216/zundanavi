import Foundation

/// WP-2q 続き: 返事エリアの状態。送った瞬間に前の返事を消して「考え中」、
/// 新しい返事（HTTP か WS の text）で差し替え、失敗・時間切れはその旨を出す。
struct ReplyPane: Equatable {
    enum Phase: Equatable {
        case idle
        case waiting
        case failed(String)
    }

    static let waitingText = "……考え中なのだ"

    private(set) var phase: Phase = .idle
    private(set) var text = ""
    /// 待っている送信の request_id（古い送信の失敗で上書きしないため）
    private(set) var pendingID: String?

    mutating func asked(requestID: String) {
        text = ""
        phase = .waiting
        pendingID = requestID
    }

    /// 返事が来た（HTTP か WS text）。空文は無視
    mutating func replied(_ t: String) {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        text = t
        phase = .idle
        pendingID = nil
    }

    /// 送信が失敗した。今待っている送信のものだけ反映
    mutating func failed(requestID: String, message: String) {
        guard phase == .waiting, pendingID == requestID else { return }
        phase = .failed(message)
        pendingID = nil
    }

    static func failureMessage(timedOut: Bool, unauthorized: Bool) -> String {
        if timedOut { return "返事が来なかったのだ（時間切れ）。もう一回送ってほしいのだ" }
        if unauthorized { return "送れなかったのだ（トークンが違う）" }
        return "送れなかったのだ（サーバーにつながらない）"
    }
}
