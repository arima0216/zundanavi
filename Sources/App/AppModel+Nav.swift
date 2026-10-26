import CoreLocation
import Foundation
import UIKit
import os

/// 下から出すシートの種類（同時に 1 枚）。
enum ActiveSheet: String, Identifiable {
    case deck, script
    var id: String { return rawValue }
}

/// 台本プレイヤーの表示状態。
@MainActor
final class ScriptPlayer: ObservableObject {
    @Published var info: ScriptInfo?
    @Published var cursor = ScriptCursor(idx: 0, count: 0)

    var currentStep: ScriptInfo.Step? {
        guard let i = info, cursor.idx >= 0, cursor.idx < i.steps.count else { return nil }
        return i.steps[cursor.idx]
    }

    /// step の idx 値から配列位置へ
    func go(stepIdx: Int) {
        guard let i = info else { return }
        if let pos = i.steps.firstIndex(where: { $0.idx == stepIdx }) {
            cursor.go(pos)
        } else {
            cursor.go(stepIdx)
        }
    }
}

/// WP-2n: 徒歩ナビ・ジオフェンス・台本・アクションデッキ。
extension AppModel {
    nonisolated static let navLog = Logger(subsystem: "dev.momo.zundanavi", category: "navflow")
    nonisolated static let suppressSeconds: TimeInterval = 180

    func setUpNav() {
        nav.makeAPI = { [weak self] in
            return self?.api ?? APIClient(baseURL: "", token: "")
        }
        nav.speak = { [weak self] text, url in
            self?.speakNav(text: text, audioURL: url)
        }
        nav.onArrived = { [weak self] place in
            self?.navArrived(place)
        }
        nav.autoReroute = { [weak self] in
            return self?.settings.autoReroute ?? true
        }
        location.onRegionEnter = { [weak self] id in
            self?.regionEntered(id)
        }
    }

    // MARK: 開始・終了

    /// 「ナビ開始」ボタン: 既存の送信に加えて card → fences → NavEngine
    func startNavButton() {
        askText("ナビを開始して", mode: "voice")
        startNavLocal()
    }

    func stopNavButton() {
        askText("ナビを終了して", mode: "voice")
        stopNavLocal()
    }

    func startNavLocal() {
        navActive = true
        Task {
            await refreshCard()
            await loadFences()
            startWalkIfPossible(force: false)
            // サーバーが予定を読み込み終わるのを少し待ってもう一度
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if navActive {
                await refreshCard()
                startWalkIfPossible(force: false)
            }
        }
    }

    func stopNavLocal() {
        navActive = false
        nav.stop()
        fences = []
        fenceTracker.setFences([])
        location.monitor(fences: [])
        lastLegID = nil
    }

    /// ナビ画面の「案内開始」: 今の next_place へ探索し直す
    func guideButton() {
        navActive = true
        Task {
            if card?.nextPlace == nil { await refreshCard() }
            startWalkIfPossible(force: true)
            if fences.isEmpty { await loadFences() }
        }
    }

    func startWalkIfPossible(force: Bool) {
        guard let place = card?.nextPlace else {
            if force { showToast("目的地（next_place）がまだ無いのだ") }
            return
        }
        if !force && nav.active && nav.destination == place { return }
        nav.start(to: place, from: location.last)
    }

    /// カード更新（GET /v1/card と WS card の両方）
    func setCard(_ c: CardInfo?) {
        let oldPlace = card?.nextPlace
        let oldLeg = card?.legID
        card = c
        guard navActive else { return }
        if let p = c?.nextPlace, p != oldPlace {
            startWalkIfPossible(force: false)
        }
        if let leg = c?.legID, leg != oldLeg, leg != lastLegID {
            Task { await loadFences() }
        }
    }

    private func navArrived(_ place: NavPlace) {
        showToast(place.name + " に着いたのだ")
        if fences.contains(where: { $0.id == place.id }) {
            _ = fenceTracker.externalEnter(place.id, time: Date().timeIntervalSince1970)
            postFenceEnter(place.id)
        }
    }

    // MARK: ジオフェンス

    func loadFences() async {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let date = f.string(from: Date())
        let leg = card?.legID
        lastLegID = leg
        do {
            let list = try await api.fences(date: date, leg: leg)
            fences = list
            fenceTracker.setFences(list.map { FenceTracker.Fence(id: $0.id, center: $0.coord, radius: $0.radiusM) })
            location.monitor(fences: list)
            AppModel.navLog.info("fences loaded \(list.count)")
        } catch {
            AppModel.navLog.info("fences unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    func navLocationUpdated(_ l: CLLocation) {
        if nav.active { nav.update(l) }
        guard navActive, !fences.isEmpty else { return }
        let ids = fenceTracker.update(Coord(l.coordinate.latitude, l.coordinate.longitude),
                                      accuracy: l.horizontalAccuracy,
                                      time: l.timestamp.timeIntervalSince1970)
        for id in ids { fenceEntered(id) }
    }

    private func regionEntered(_ id: String) {
        guard navActive, fences.contains(where: { $0.id == id }) else { return }
        if fenceTracker.externalEnter(id, time: Date().timeIntervalSince1970) {
            fenceEntered(id)
        }
    }

    private func fenceEntered(_ id: String) {
        guard let f = fences.first(where: { $0.id == id }) else { return }
        AppModel.navLog.info("fence enter \(id, privacy: .public)")
        postFenceEnter(id)
        if let say = f.say, !say.isEmpty { showToast(say) }
        if let a = f.sayAudio {
            markPlayed(a)
            let item = speech.enqueueAlert()
            fetchAudioOrTTS(a, fallbackText: f.say ?? "", into: item)
        }
        if let sid = f.scriptID {
            openScript(id: sid, stepIdx: nil, play: f.sayAudio == nil)
        }
    }

    private func postFenceEnter(_ id: String) {
        let api = self.api
        Task {
            do {
                try await api.fenceEnter(id: id, ts: Date().timeIntervalSince1970)
            } catch {
                // 404 / 不通は無視
            }
        }
    }

    // MARK: 音声

    func markPlayed(_ url: String) {
        recentAudio.mark(url, now: Date().timeIntervalSince1970)
    }

    func recentlyPlayed(_ url: String) -> Bool {
        return recentAudio.recently(url, now: Date().timeIntervalSince1970)
    }

    /// 徒歩ナビの声（既存キューに alert 相当で割り込み）
    func speakNav(text: String, audioURL: String?) {
        guard settings.walkVoiceEnabled else { return }
        if let u = audioURL {
            markPlayed(u)
            let item = speech.enqueueAlert()
            fetchAudioOrTTS(u, fallbackText: text, into: item)
        } else if settings.localTTSFallback {
            let item = speech.enqueueAlert()
            Task {
                let d = await localTTS.synthesize(text)
                speech.setData(item, d)
            }
        }
    }

    /// サーバー音声を取り、取れなければ端末合成。
    func fetchAudioOrTTS(_ url: String, fallbackText: String, into item: SpeechQueue.Item) {
        let api = self.api
        let fallback = settings.localTTSFallback
        Task {
            var d: Data?
            do {
                d = try await api.fetchAudio(url)
            } catch {
                AppModel.navLog.info("audio fetch failed, fallback=\(fallback)")
            }
            if d == nil && fallback && !fallbackText.isEmpty {
                d = await localTTS.synthesize(fallbackText)
            }
            speech.setData(item, d)
        }
    }

    // MARK: 台本

    func openScript(id: String, stepIdx: Int?, play: Bool) {
        let api = self.api
        Task {
            do {
                let info = try await api.script(id: id)
                script.info = info
                script.cursor = ScriptCursor(idx: 0, count: info.steps.count)
                if let i = stepIdx { script.go(stepIdx: i) }
                activeSheet = .script
                if play { playScriptStep(interrupt: false) }
            } catch {
                showToast("台本が取れないのだ")
            }
        }
    }

    /// ボタン（sync=true でサーバーへ同期）／WS（sync=false）
    func scriptAction(_ action: String, sync: Bool) {
        guard let info = script.info else { return }
        script.cursor.apply(action)
        playScriptStep(interrupt: sync)
        if sync {
            let api = self.api
            let sid = info.id
            Task {
                do {
                    try await api.scriptStep(id: sid, action: action)
                } catch {
                    // 404 / 不通でもローカルで進める
                }
            }
        }
    }

    func scriptEvent(id: String, stepIdx: Int?, action: String?) {
        if script.info?.id == id {
            if let i = stepIdx {
                script.go(stepIdx: i)
                playScriptStep(interrupt: true)
            } else if let a = action {
                scriptAction(a, sync: false)
            }
            activeSheet = .script
        } else {
            openScript(id: id, stepIdx: stepIdx, play: true)
        }
    }

    func playScriptStep(interrupt: Bool) {
        guard let st = script.currentStep else { return }
        if interrupt { speech.stopAll() }
        if let u = st.audioURL {
            markPlayed(u)
            let item = speech.enqueueAnswer()
            fetchAudioOrTTS(u, fallbackText: st.text, into: item)
        } else if settings.localTTSFallback {
            let item = speech.enqueueAnswer()
            let text = st.text
            Task {
                let d = await localTTS.synthesize(text)
                speech.setData(item, d)
            }
        }
    }

    func closeScript() {
        script.info = nil
        if activeSheet == .script { activeSheet = nil }
    }

    // MARK: アクションデッキ

    func receiveDeck(_ d: ActionDeck) {
        guard !d.items.isEmpty else { return }
        deck = d
        activeSheet = .deck
        showToast("アクションデッキが届いたのだ")
        speech.playFiller(WavEncoder.beep(frequency: 990, duration: 0.12))
    }

    func openDeckItem(_ item: DeckItem) {
        openURL(item.url)
        deck?.markDone(item.n)
    }

    func closeDeck() {
        deck = nil
        if activeSheet == .deck { activeSheet = nil }
    }

    func openURL(_ s: String) {
        guard let u = URL(string: s) else {
            showToast("URL が開けないのだ")
            return
        }
        UIApplication.shared.open(u, options: [:]) { [weak self] ok in
            if !ok {
                Task { @MainActor in
                    self?.showToast("アプリが開けないのだ")
                }
            }
        }
    }
}
