import AVFoundation
import os

/// 再生キュー。
/// - filler: 何も鳴っていない時だけ。本答・speak・alert が来たら止めて捨てる。
/// - answer / speak: 到着順（speak は seq 順）。データが来るまで先頭で待つ。
/// - alert: 先頭に割り込み、鳴っている本答は頭からやり直す。
@MainActor
final class SpeechQueue: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum Kind {
        case filler, answer, speak, alert
    }

    final class Item {
        let id = UUID()
        let kind: Kind
        let seq: Int
        var data: Data?
        var failed = false

        init(kind: Kind, seq: Int = 0, data: Data? = nil) {
            self.kind = kind
            self.seq = seq
            self.data = data
        }
    }

    nonisolated static let log = Logger(subsystem: "dev.momo.zundanavi", category: "player")

    @Published private(set) var isPlaying = false
    private var items: [Item] = []
    private var current: Item?
    private var player: AVAudioPlayer?

    private var hasRealContent: Bool {
        if let c = current, c.kind != .filler { return true }
        return items.contains { $0.kind != .filler }
    }

    /// フィラーを鳴らす（本物の返事が控えていれば鳴らさない）。
    func playFiller(_ data: Data) {
        if hasRealContent { return }
        items.removeAll { $0.kind == .filler }
        items.append(Item(kind: .filler, data: data))
        pump()
    }

    /// フィラーを全部止める（文字だけの返事が来た時など）。
    func cancelFillers() {
        items.removeAll { $0.kind == .filler }
        if let c = current, c.kind == .filler {
            stopCurrent()
        }
        pump()
    }

    /// 本答。データは後から setData で入れる。
    @discardableResult
    func enqueueAnswer(data: Data? = nil) -> Item {
        let it = Item(kind: .answer, data: data)
        items.removeAll { $0.kind == .filler }
        if let c = current, c.kind == .filler { stopCurrent() }
        items.append(it)
        pump()
        return it
    }

    /// WS の speak。seq 順に並べる。
    @discardableResult
    func enqueueSpeak(seq: Int) -> Item {
        let it = Item(kind: .speak, seq: seq)
        items.removeAll { $0.kind == .filler }
        if let c = current, c.kind == .filler { stopCurrent() }
        if let idx = items.firstIndex(where: { $0.kind == .speak && $0.seq > seq }) {
            items.insert(it, at: idx)
        } else {
            items.append(it)
        }
        pump()
        return it
    }

    /// WS の alert。先頭に割り込む。
    @discardableResult
    func enqueueAlert(data: Data? = nil) -> Item {
        let it = Item(kind: .alert, data: data)
        items.removeAll { $0.kind == .filler }
        if let c = current {
            if c.kind == .answer || c.kind == .speak {
                // 割り込まれた本答は後でもう一度頭から
                items.insert(c, at: 0)
            }
            stopCurrent()
        }
        let pos = items.firstIndex(where: { $0.kind != .alert }) ?? items.count
        items.insert(it, at: pos)
        pump()
        return it
    }

    func setData(_ item: Item, _ data: Data?) {
        if let d = data {
            item.data = d
        } else {
            item.failed = true
        }
        pump()
    }

    func stopAll() {
        items.removeAll()
        stopCurrent()
    }

    /// 単発再生（履歴の聞き直し）。キューを止めて鳴らす。
    func replay(_ data: Data) {
        stopAll()
        items.append(Item(kind: .answer, data: data))
        pump()
    }

    private func stopCurrent() {
        player?.stop()
        player = nil
        current = nil
        isPlaying = false
    }

    private func pump() {
        guard current == nil else { return }
        while let head = items.first, head.failed {
            items.removeFirst()
        }
        guard let head = items.first, let data = head.data else {
            isPlaying = false
            return
        }
        items.removeFirst()
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.prepareToPlay()
            if p.play() {
                player = p
                current = head
                isPlaying = true
                return
            }
            SpeechQueue.log.error("play() returned false")
        } catch {
            SpeechQueue.log.error("player init failed: \(error.localizedDescription, privacy: .public)")
        }
        pump()
    }

    private func finished(_ p: AVAudioPlayer) {
        guard p === player else { return }
        player = nil
        current = nil
        isPlaying = false
        pump()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.finished(player)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.finished(player)
        }
    }
}
