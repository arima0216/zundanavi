import CoreMotion
import Foundation
import os

/// WP-11i: 歩行・歩数・階・気圧を観測して /v1/position に添える。判定はサーバー側。
/// 位置更新を送っている間だけ動かす（start/stop は AppModel が LocationService に合わせて呼ぶ）。
/// 使えないセンサーは無言で nil のまま。権限ダイアログ（モーションと フィットネス）は OS が初回だけ出す。
@MainActor
final class MotionService: ObservableObject {
    nonisolated static let log = Logger(subsystem: "dev.momo.zundanavi", category: "motion")

    struct Availability: Equatable {
        var motion = false
        var pedometer = false
        var floors = false
        var altimeter = false
    }

    @Published private(set) var availability = Availability()
    @Published private(set) var running = false
    @Published private(set) var denied = false

    // 最新値（画面表示と送信用）
    @Published private(set) var activity: String?
    @Published private(set) var activityConfidence: Int?
    @Published private(set) var stepsTotal: Int?
    @Published private(set) var floorsAscended: Int?
    @Published private(set) var floorsDescended: Int?
    @Published private(set) var pressureKPa: Double?
    @Published private(set) var relativeAltitudeM: Double?
    private(set) var altitudeBaseTs: Double?

    private let activityManager = CMMotionActivityManager()
    private let pedometer = CMPedometer()
    private let altimeter = CMAltimeter()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "dev.momo.zundanavi.motion"
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private var steps = StepCounter()

    init() {
        availability = MotionService.probe()
    }

    static func probe() -> Availability {
        return Availability(motion: CMMotionActivityManager.isActivityAvailable(),
                            pedometer: CMPedometer.isStepCountingAvailable(),
                            floors: CMPedometer.isFloorCountingAvailable(),
                            altimeter: CMAltimeter.isRelativeAltitudeAvailable())
    }

    func start() {
        guard !running else { return }
        availability = MotionService.probe()
        running = true
        steps.reset()
        stepsTotal = nil
        floorsAscended = nil
        floorsDescended = nil
        pressureKPa = nil
        relativeAltitudeM = nil
        altitudeBaseTs = nil

        if availability.motion {
            activityManager.startActivityUpdates(to: queue, withHandler: MotionService.activityHandler(self))
        }
        if availability.pedometer {
            pedometer.startUpdates(from: Date(), withHandler: MotionService.pedometerHandler(self))
        }
        if availability.altimeter {
            altimeter.startRelativeAltitudeUpdates(to: queue, withHandler: MotionService.altimeterHandler(self))
        }
        MotionService.log.info("motion start motion=\(self.availability.motion) ped=\(self.availability.pedometer) floors=\(self.availability.floors) alt=\(self.availability.altimeter)")
    }

    // Core Motion のハンドラは別キューで呼ばれるので、アクター外で作って MainActor へ戻す（AppModel.wireAudio と同じ流儀）。
    nonisolated private static func activityHandler(_ owner: MotionService) -> CMMotionActivityHandler {
        return { [weak owner] a in
            guard let a = a else { return }
            let name = MotionPick.pick(stationary: a.stationary, walking: a.walking, running: a.running,
                                       automotive: a.automotive, cycling: a.cycling)
            let conf = a.confidence.rawValue
            Task { @MainActor in
                owner?.activityUpdated(name: name, confidence: conf)
            }
        }
    }

    nonisolated private static func pedometerHandler(_ owner: MotionService) -> CMPedometerHandler {
        return { [weak owner] data, error in
            if let error = error {
                let denied = MotionService.isAuthError(error)
                MotionService.log.info("pedometer error: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor in
                    if denied { owner?.markDenied() }
                }
                return
            }
            guard let data = data else { return }
            let s = data.numberOfSteps.intValue
            let d = data.distance?.doubleValue
            let up = data.floorsAscended?.intValue
            let down = data.floorsDescended?.intValue
            Task { @MainActor in
                owner?.pedometerUpdated(steps: s, distance: d, up: up, down: down)
            }
        }
    }

    nonisolated private static func altimeterHandler(_ owner: MotionService) -> CMAltitudeHandler {
        return { [weak owner] data, error in
            if let error = error {
                let denied = MotionService.isAuthError(error)
                MotionService.log.info("altimeter error: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor in
                    if denied { owner?.markDenied() }
                }
                return
            }
            guard let data = data else { return }
            let rel = data.relativeAltitude.doubleValue
            let kpa = data.pressure.doubleValue
            let now = Date().timeIntervalSince1970
            Task { @MainActor in
                owner?.altitudeUpdated(rel: rel, kpa: kpa, now: now)
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        activityManager.stopActivityUpdates()
        pedometer.stopUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        MotionService.log.info("motion stop")
    }

    private func activityUpdated(name: String, confidence: Int) {
        guard running else { return }
        activity = name
        activityConfidence = confidence
    }

    private func markDenied() {
        denied = true
    }

    private func pedometerUpdated(steps s: Int, distance d: Double?, up: Int?, down: Int?) {
        guard running else { return }
        steps.update(steps: s, distance: d)
        stepsTotal = steps.steps
        if availability.floors {
            floorsAscended = up
            floorsDescended = down
        }
    }

    private func altitudeUpdated(rel: Double, kpa: Double, now: Double) {
        guard running else { return }
        if altitudeBaseTs == nil {
            // 相対高度は最初のイベントが基準（0 m）
            altitudeBaseTs = now
        }
        relativeAltitudeM = rel
        pressureKPa = kpa
    }

    /// 送信時に呼ぶ。歩数・距離は前回 take からの差分を返して基準を進める。
    func takeSnapshot(into x: inout PositionExtras) {
        guard running else { return }
        x.motion = activity
        x.motionConf = activityConfidence
        if stepsTotal != nil {
            let dlt = steps.take()
            x.stepsDelta = dlt.steps
            x.distDeltaM = dlt.distance
        }
        x.floorsAsc = floorsAscended
        x.floorsDesc = floorsDescended
        x.pressureKPa = pressureKPa
        x.relAltM = relativeAltitudeM
        x.altBaseTs = pressureKPa != nil ? altitudeBaseTs : nil
    }

    nonisolated static func isAuthError(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == CMErrorDomain && e.code == Int(CMErrorMotionActivityNotAuthorized.rawValue)
    }

    /// 設定画面の 1 行目: 「センサー: 気圧 ○ 歩数 ○ 階 × モーション ○」
    var availabilityText: String {
        func m(_ b: Bool) -> String { return b ? "○" : "×" }
        let a = availability
        var s = "センサー: 気圧 " + m(a.altimeter) + " 歩数 " + m(a.pedometer) + " 階 " + m(a.floors) + " モーション " + m(a.motion)
        if denied { s += "（許可なし）" }
        return s
    }

    /// 設定画面の 2 行目: 現在値
    var valuesText: String {
        var parts: [String] = []
        parts.append("気圧 " + (pressureKPa.map { String(format: "%.3f kPa", $0) } ?? "--"))
        parts.append("相対高度 " + (relativeAltitudeM.map { String(format: "%+.1f m", $0) } ?? "--"))
        var act = activity ?? "--"
        if let c = activityConfidence { act += "(" + String(c) + ")" }
        parts.append("動き " + act)
        parts.append("歩数 " + (stepsTotal.map { String($0) } ?? "--"))
        if availability.floors {
            parts.append("階 +" + String(floorsAscended ?? 0) + "/-" + String(floorsDescended ?? 0))
        }
        if !running { parts.append("停止中") }
        return parts.joined(separator: "  ")
    }
}
