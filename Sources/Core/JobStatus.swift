import Foundation

/// WP-2r: ロングラン作業（job）のバナー用の状態。純粋ロジック。
struct JobStatus: Equatable {
    enum State: String, Equatable {
        case running, done, failed, cancelled
    }

    var id: String
    var title: String
    var state: State = .running
    var startedAt: Date
    /// 経過の一覧（started と progress の文）
    var lines: [String] = []
    /// done の全文
    var result: String?
    /// 最新の状況（バナーに出す）
    var latestText: String = ""
    /// 終わった時の経過秒（終わってからは時計を止める）
    var finishedElapsed: Double?

    init(id: String, title: String, startedAt: Date) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
    }

    var isActive: Bool { return state == .running }

    /// イベントを反映。他の id、終わった後のイベント、知らない state は無視して false。
    mutating func apply(_ ev: JobEvent, now: Date) -> Bool {
        guard ev.jobID == id, isActive else { return false }
        let text = ev.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch ev.state {
        case "started":
            if let t = ev.title, !t.isEmpty { title = t }
            if let s = ev.started, s > 0 { startedAt = Date(timeIntervalSince1970: s) }
            if !text.isEmpty {
                if lines.last != text { lines.append(text) }
                latestText = text
            }
            return true
        case "progress":
            guard !text.isEmpty else { return false }
            lines.append(text)
            latestText = text
            return true
        case "done":
            state = .done
            result = ev.textFull ?? (text.isEmpty ? nil : text)
            if !text.isEmpty { latestText = text }
            finishedElapsed = ev.elapsedSec ?? now.timeIntervalSince(startedAt)
            return true
        case "failed", "cancelled":
            state = ev.state == "failed" ? .failed : .cancelled
            if !text.isEmpty { latestText = text }
            finishedElapsed = ev.elapsedSec ?? now.timeIntervalSince(startedAt)
            return true
        default:
            return false
        }
    }

    /// 今のバナーにイベントを当てた結果（新しい job ならバナーを作り直す）。
    /// accepted が false のイベントは鳴らさない・履歴に入れない。
    static func reduce(_ current: JobStatus?, _ ev: JobEvent, now: Date) -> (job: JobStatus?, accepted: Bool) {
        if var j = current, j.id == ev.jobID {
            let ok = j.apply(ev, now: now)
            return (j, ok)
        }
        // 別の job: 走っている job を別 id の途中経過で上書きしない（started か、今のが終わっている時だけ）
        if let j = current, j.isActive, ev.state != "started" {
            return (current, false)
        }
        var n = JobStatus(id: ev.jobID, title: ev.title ?? "", startedAt: now)
        if let s = ev.started, s > 0 { n.startedAt = Date(timeIntervalSince1970: s) }
        let ok = n.apply(ev, now: now)
        if ok { return (n, true) }
        return (current, false)
    }

    /// /v1/ask の応答が job なら先にバナーを立てる（WS より先に来る）
    static func fromAsk(_ r: AskResponse, now: Date) -> JobStatus? {
        guard r.tier == "job", let jid = r.jobID, !jid.isEmpty else { return nil }
        var j = JobStatus(id: jid, title: JobStatus.quotedTitle(r.textVoice) ?? "", startedAt: now)
        let v = r.textVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty {
            j.latestText = v
            j.lines = [v]
        }
        return j
    }

    /// 「ロングラン作業に入るのだ。「〇〇」を考えるのだ。」から 〇〇 を取る
    static func quotedTitle(_ s: String) -> String? {
        guard let a = s.firstIndex(of: "「"), let b = s[a...].firstIndex(of: "」"), a < b else { return nil }
        let t = String(s[s.index(after: a)..<b])
        return t.isEmpty ? nil : t
    }

    func elapsedSeconds(now: Date) -> Double {
        return max(0, finishedElapsed ?? now.timeIntervalSince(startedAt))
    }

    /// 「3 分 12 秒」「48 秒」
    func elapsedText(now: Date) -> String {
        return JobStatus.durationText(elapsedSeconds(now: now))
    }

    static func durationText(_ sec: Double) -> String {
        let s = Int(max(0, sec))
        if s < 60 { return String(s) + " 秒" }
        return String(s / 60) + " 分 " + String(s % 60) + " 秒"
    }
}
