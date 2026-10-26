import CoreLocation
import os

/// GPS「常に」。まず WhenInUse を求め、許可されたら Always へ昇格を求める。
@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    nonisolated static let log = Logger(subsystem: "dev.momo.zundanavi", category: "location")

    @Published private(set) var last: CLLocation?
    @Published private(set) var status: CLAuthorizationStatus = .notDetermined

    /// 位置が更新されるたびに呼ぶ
    var onUpdate: ((CLLocation) -> Void)?

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
    }

    var fix: GPSFix? {
        guard let l = last else { return nil }
        return LocationService.fix(from: l)
    }

    static func fix(from l: CLLocation) -> GPSFix {
        return GPSFix(
            lat: l.coordinate.latitude,
            lon: l.coordinate.longitude,
            acc: l.horizontalAccuracy,
            heading: l.course >= 0 ? l.course : nil,
            speed: l.speed >= 0 ? l.speed : nil,
            ts: l.timestamp.timeIntervalSince1970
        )
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

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        LocationService.log.error("location error: \(error.localizedDescription, privacy: .public)")
    }
}
