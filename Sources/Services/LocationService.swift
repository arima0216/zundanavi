import CoreLocation
import os

/// GPS「常に」。まず WhenInUse を求め、許可されたら Always へ昇格を求める。
@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    nonisolated static let log = Logger(subsystem: "dev.momo.zundanavi", category: "location")

    @Published private(set) var last: CLLocation?
    @Published private(set) var status: CLAuthorizationStatus = .notDetermined
    /// WP-11i: 位置更新を動かしているか（MotionService の開始/停止をこれに合わせる）
    @Published private(set) var updating = false
    /// WP-11i: 最新の CLHeading（端末の向き）。位置更新と同時なので trueHeading も有効。
    private(set) var lastHeading: CLHeading?

    /// 位置が更新されるたびに呼ぶ
    var onUpdate: ((CLLocation) -> Void)?
    /// OS のリージョン監視で進入した（保険。主判定はソフトウェア）
    var onRegionEnter: ((String) -> Void)?

    private let manager = CLLocationManager()
    private var askedAlways = false
    private var started = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .fitness
        status = manager.authorizationStatus
    }

    func start() {
        started = true
        status = manager.authorizationStatus
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            askAlwaysIfNeeded()
            beginUpdates()
        case .authorizedAlways:
            beginUpdates()
        default:
            LocationService.log.info("location not authorized")
        }
    }

    private func askAlwaysIfNeeded() {
        if !askedAlways {
            askedAlways = true
            manager.requestAlwaysAuthorization()
        }
    }

    private func beginUpdates() {
        // Info.plist の UIBackgroundModes に location があるので true にできる
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.headingFilter = 5
            manager.startUpdatingHeading()
        }
        updating = true
    }

    var fix: GPSFix? {
        guard let l = last else { return nil }
        return LocationService.fix(from: l, heading: lastHeading)
    }

    /// 既存の 6 キー。heading は HeadingPick の規則（歩行中で course が確かなら course、他は trueHeading）。
    static func fix(from l: CLLocation, heading h: CLHeading?) -> GPSFix {
        let speed = PositionExtras.nonNegative(l.speed)
        let course = PositionExtras.nonNegative(l.course)
        let courseAcc = PositionExtras.nonNegative(l.courseAccuracy)
        let trueH = headingTrue(h)
        return GPSFix(
            lat: l.coordinate.latitude,
            lon: l.coordinate.longitude,
            acc: l.horizontalAccuracy,
            heading: HeadingPick.pick(speed: speed, course: course, courseAcc: courseAcc, headingTrue: trueH),
            speed: speed,
            ts: l.timestamp.timeIntervalSince1970
        )
    }

    /// headingAccuracy が負なら向きは無効。
    private static func headingValid(_ h: CLHeading?) -> CLHeading? {
        guard let h = h, h.headingAccuracy >= 0 else { return nil }
        return h
    }

    private static func headingTrue(_ h: CLHeading?) -> Double? {
        guard let h = headingValid(h) else { return nil }
        return PositionExtras.nonNegative(h.trueHeading)
    }

    /// WP-11i: CLLocation / CLHeading 由来の追加観測値（Core Motion と端末状態は呼び出し側で足す）。
    static func extras(from l: CLLocation, heading h: CLHeading?, now: Date) -> PositionExtras {
        var x = PositionExtras()
        x.course = PositionExtras.nonNegative(l.course)
        x.courseAcc = PositionExtras.nonNegative(l.courseAccuracy)
        x.altM = l.verticalAccuracy >= 0 ? l.altitude : nil
        x.vertAcc = PositionExtras.nonNegative(l.verticalAccuracy)
        x.floorLevel = l.floor?.level
        x.fixAgeS = max(now.timeIntervalSince(l.timestamp), 0)
        if let hv = headingValid(h) {
            x.headingTrue = PositionExtras.nonNegative(hv.trueHeading)
            x.headingMag = PositionExtras.nonNegative(hv.magneticHeading)
            x.headingAcc = hv.headingAccuracy
        }
        return x
    }

    var accuracyText: String {
        guard let l = last, l.horizontalAccuracy >= 0 else { return "GPS --" }
        return "GPS ±" + String(Int(l.horizontalAccuracy.rounded())) + "m"
    }

    private func handleAuthChange(_ st: CLAuthorizationStatus) {
        status = st
        guard started else { return }
        switch st {
        case .authorizedWhenInUse:
            askAlwaysIfNeeded()
            beginUpdates()
        case .authorizedAlways:
            beginUpdates()
        default:
            break
        }
    }

    private func handle(_ l: CLLocation) {
        last = l
        onUpdate?(l)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let st = manager.authorizationStatus
        Task { @MainActor in
            self.handleAuthChange(st)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        Task { @MainActor in
            self.handle(l)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in
            self.lastHeading = newHeading
        }
    }

    /// 案内中に方位の校正画面を出さない（調査 §2）
    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        return false
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        LocationService.log.error("location error: \(error.localizedDescription, privacy: .public)")
    }
    /// ジオフェンスの保険: CLCircularRegion を最大 20 個監視する（先頭=現在区間を優先）。
    func monitor(fences: [FenceInfo]) {
        for r in manager.monitoredRegions {
            manager.stopMonitoring(for: r)
        }
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        for f in fences.prefix(20) {
            let radius = min(max(f.radiusM, 1), manager.maximumRegionMonitoringDistance)
            let r = CLCircularRegion(center: CLLocationCoordinate2D(latitude: f.lat, longitude: f.lon), radius: radius, identifier: f.id)
            r.notifyOnEntry = true
            r.notifyOnExit = false
            manager.startMonitoring(for: r)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in
            self.onRegionEnter?(id)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        LocationService.log.info("region monitoring failed: \(error.localizedDescription, privacy: .public)")
    }
}
