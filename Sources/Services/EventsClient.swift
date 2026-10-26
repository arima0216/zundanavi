import Foundation
import os

/// WS /v1/events。切れたら指数バックオフ（最大 30 秒）で再接続する。
@MainActor
final class EventsClient: ObservableObject {
    nonisolated static let log = Logger(subsystem: "dev.momo.zundanavi", category: "ws")

    @Published private(set) var connected = false

    var onEvent: ((WSEvent) -> Void)?
    /// 接続のたびに設定から要求を作る
    var makeRequest: (() -> URLRequest?)?

    private var task: URLSessionWebSocketTask?
    private var backoff: TimeInterval = 1
    private var wantRunning = false
    private var generation = 0
    private var pingTimer: Timer?

    func start() {
        wantRunning = true
        if task == nil { connect() }
    }

    func stop() {
        wantRunning = false
        generation += 1
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
    }

    func restart() {
        stop()
        backoff = 1
        start()
    }

    private func connect() {
        guard wantRunning else { return }
        guard let req = makeRequest?() else {
            EventsClient.log.info("ws: no request (bad url)")
            return
        }
        generation += 1
        let gen = generation
        let t = URLSession.shared.webSocketTask(with: req)
        task = t
        t.resume()
        receive(t, gen)
        t.sendPing { [weak self] err in
            Task { @MainActor in
                guard let self = self, gen == self.generation else { return }
                if err == nil {
                    self.markConnected()
                }
            }
        }
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.ping(gen)
            }
        }
    }

    private func ping(_ gen: Int) {
        guard gen == generation, let t = task else { return }
        t.sendPing { [weak self] err in
            if err != nil {
                Task { @MainActor in
                    self?.failed(gen)
                }
            }
        }
    }

    private func markConnected() {
        if !connected { EventsClient.log.info("ws connected") }
        connected = true
        backoff = 1
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) {
        t.receive { [weak self] result in
            Task { @MainActor in
                self?.handle(result, t, gen)
            }
        }
    }

    private func handle(_ result: Result<URLSessionWebSocketTask.Message, Error>, _ t: URLSessionWebSocketTask, _ gen: Int) {
        guard gen == generation else { return }
        switch result {
        case .success(let msg):
            markConnected()
            var data: Data?
            switch msg {
            case .string(let s): data = Data(s.utf8)
            case .data(let d): data = d
            @unknown default: data = nil
            }
            if let d = data, let ev = WSEvent.parse(d) {
                onEvent?(ev)
            }
            receive(t, gen)
        case .failure(let err):
            EventsClient.log.info("ws receive failed: \(err.localizedDescription, privacy: .public)")
            failed(gen)
        }
    }

    private func failed(_ gen: Int) {
        guard gen == generation else { return }
        generation += 1
        connected = false
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        guard wantRunning else { return }
        let delay = backoff
        backoff = min(backoff * 2, 30)
        let next = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self = self, self.wantRunning, self.task == nil, next == self.generation else { return }
            self.connect()
        }
    }
}
