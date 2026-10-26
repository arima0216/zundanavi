import Foundation
import UIKit
import os

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var ts: Date
    /// "user" / "assistant" / "push"
    var role: String
    var text: String
    var audioURL: String?
    /// "local" / "server"
    var source: String

    init(id: UUID = UUID(), ts: Date = Date(), role: String, text: String, audioURL: String? = nil, source: String = "local") {
        self.id = id
        self.ts = ts
        self.role = role
        self.text = text
        self.audioURL = audioURL
        self.source = source
    }
}

/// 会話の往復をローカル（Documents/history.json）に保存し、/v1/history で補完する。
@MainActor
final class HistoryStore: ObservableObject {
    nonisolated static let log = Logger(subsystem: "dev.momo.zundanavi", category: "history")
    static let maxEntries = 500

    @Published private(set) var entries: [HistoryEntry] = []

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("history.json")
    }

    init() {
        load()
    }

    func add(_ e: HistoryEntry) {
        entries.append(e)
        trimAndSave()
    }

    func merge(server items: [ServerHistoryItem]) {
        var changed = false
        for it in items {
            let exists = entries.contains { $0.role == it.role && $0.text == it.text }
            if !exists {
                entries.append(HistoryEntry(ts: it.ts ?? Date(), role: it.role, text: it.text, source: "server"))
                changed = true
            }
        }
        if changed {
            entries.sort { $0.ts < $1.ts }
            trimAndSave()
        }
    }

    func clear() {
        entries = []
        save()
    }

    private func trimAndSave() {
        if entries.count > HistoryStore.maxEntries {
            entries.removeFirst(entries.count - HistoryStore.maxEntries)
        }
        save()
    }

    private func load() {
        guard let d = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        if let e = try? dec.decode([HistoryEntry].self, from: d) {
            entries = e
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        do {
            let d = try enc.encode(entries)
            try d.write(to: fileURL, options: .atomic)
        } catch {
            HistoryStore.log.error("history save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// 電池ログ（5 分ごとに Documents/battery.csv へ追記）。
@MainActor
final class BatteryLogger: ObservableObject {
    static let interval: TimeInterval = 300
    @Published private(set) var lineCount = 0
    private var timer: Timer?

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("battery.csv")
    }

    var fileExists: Bool {
        return FileManager.default.fileExists(atPath: BatteryLogger.fileURL.path)
    }

    func setEnabled(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        logNow()
        timer = Timer.scheduledTimer(withTimeInterval: BatteryLogger.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.logNow()
            }
        }
    }

    func logNow() {
        let dev = UIDevice.current
        let level = dev.batteryLevel
        let state: String
        switch dev.batteryState {
        case .charging: state = "charging"
        case .full: state = "full"
        case .unplugged: state = "unplugged"
        default: state = "unknown"
        }
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone.current
        let pct = level < 0 ? "" : String(Int((level * 100).rounded()))
        let line = f.string(from: Date()) + "," + pct + "," + state + "\n"
        let url = BatteryLogger.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data("time,level_pct,state\n".utf8).write(to: url)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            h.closeFile()
        }
        lineCount += 1
    }
}
