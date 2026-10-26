import CoreLocation
import MapKit
import os

/// 徒歩ナビ。MKDirections(.walking) で経路を取り、手順点ごとに approach / at を鳴らす。
/// 音声はサーバーの /v1/route（無ければ端末合成）。経路外れで再探索、到着で停止。
@MainActor
final class NavEngine: ObservableObject {
    nonisolated static let log = Logger(subsystem: "dev.momo.zundanavi", category: "nav")

    @Published private(set) var active = false
    @Published private(set) var destination: NavPlace?
    @Published private(set) var routeCoords: [CLLocationCoordinate2D] = []
    @Published private(set) var steps: [NavStep] = []
    @Published private(set) var currentStepIdx: Int?
    @Published private(set) var statusText = "停止中"

    /// 鳴らす: (端末合成用の文, サーバーの音声 URL)
    var speak: ((String, String?) -> Void)?
    /// 到着した
    var onArrived: ((NavPlace) -> Void)?
    var makeAPI: (() -> APIClient)?
    var autoReroute: () -> Bool = { true }

    private var tracker: StepTracker?
    private var offroute = OffRouteDetector()
    private var polyline: [Coord] = []
    private var routeAudio: RouteAudio?
    private var calculating = false
    private var pendingRecalc = false
    private var generation = 0
    private var lastLocation: CLLocation?

    func start(to place: NavPlace, from loc: CLLocation?) {
        destination = place
        active = true
        statusText = place.name + " へ経路を探索中"
        Task { await calculate(from: loc) }
    }

    func stop() {
        active = false
        generation += 1
        tracker = nil
        routeCoords = []
        steps = []
        polyline = []
        currentStepIdx = nil
        routeAudio = nil
        statusText = "停止中"
    }

    private func calculate(from loc: CLLocation?) async {
        guard active, let dest = destination else { return }
        if calculating {
            pendingRecalc = true
            return
        }
        calculating = true
        defer {
            calculating = false
            if pendingRecalc && active {
                pendingRecalc = false
                let l = lastLocation
                Task { await self.calculate(from: l) }
            }
        }
        generation += 1
        let gen = generation
        let req = MKDirections.Request()
        if let l = loc ?? lastLocation {
            req.source = MKMapItem(placemark: MKPlacemark(coordinate: l.coordinate))
        } else {
            req.source = MKMapItem.forCurrentLocation()
        }
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: dest.lat, longitude: dest.lon)))
        req.transportType = .walking
        do {
            let resp = try await MKDirections(request: req).calculate()
            guard gen == generation, active, let route = resp.routes.first else { return }
            apply(route: route, dest: dest)
            await fetchRouteAudio(gen: gen)
        } catch {
            NavEngine.log.error("directions failed: \(error.localizedDescription, privacy: .public)")
            statusText = "経路が取れないのだ（" + dest.name + "）"
        }
    }

    private func apply(route: MKRoute, dest: NavPlace) {
        routeCoords = NavEngine.coordinates(of: route.polyline)
        polyline = routeCoords.map { Coord($0.latitude, $0.longitude) }
        var list: [NavStep] = []
        for st in route.steps {
            let text = st.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let pts = NavEngine.coordinates(of: st.polyline)
            guard let first = pts.first, let last = pts.last else { continue }
            // 曲がる場所は手順の始点。到着の手順だけは終点
            let p = DirectionParser.parse(text) == .arrive ? last : first
            list.append(NavStep(idx: list.count, instruction: text, point: Coord(p.latitude, p.longitude), distanceM: st.distance))
        }
        steps = list
        tracker = StepTracker(steps: list, destination: dest.coord, arriveRadius: dest.radiusM ?? 25)
        offroute.reset()
        routeAudio = nil
        currentStepIdx = list.first?.idx
        let mins = Int((route.expectedTravelTime / 60).rounded())
        statusText = dest.name + " まで " + String(Int(route.distance.rounded())) + "m・約" + String(mins) + "分"
    }

    private func fetchRouteAudio(gen: Int) async {
        guard let api = makeAPI?(), !steps.isEmpty else { return }
        let rid = UUID().uuidString
        var items: [[String: Any]] = []
        for s in steps {
            items.append(["idx": s.idx, "instruction": s.instruction, "lat": s.point.lat, "lon": s.point.lon, "distance_m": s.distanceM])
        }
        var body: [String: Any] = ["route_id": rid, "steps": items]
        if let d = destination { body["dest_place_id"] = d.id }
        do {
            let ra = try await api.route(body: body)
            if gen == generation { routeAudio = ra }
        } catch {
            // 404 / 不通: 端末合成で続ける
            NavEngine.log.info("route audio unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(_ loc: CLLocation) {
        lastLocation = loc
        guard active, var t = tracker else { return }
        let pos = Coord(loc.coordinate.latitude, loc.coordinate.longitude)
        let acc = loc.horizontalAccuracy
        let cues = t.update(pos, accuracy: acc)
        tracker = t
        currentStepIdx = t.currentStep?.idx
        for c in cues {
            switch c {
            case .approach(let i):
                let st = steps.first { $0.idx == i }
                let a = routeAudio?.steps[i]
                speak?(a?.textApproach ?? DirectionParser.approachText(st?.instruction ?? ""), a?.audioApproach)
            case .at(let i):
                let st = steps.first { $0.idx == i }
                let a = routeAudio?.steps[i]
                speak?(a?.textAt ?? DirectionParser.atText(st?.instruction ?? ""), a?.audioAt)
            case .arrived:
                speak?(DirectionParser.arrivedText, routeAudio?.arrivedAudio)
                if let d = destination { onArrived?(d) }
                stop()
                statusText = "到着"
                return
            }
        }
        if autoReroute() && !calculating && polyline.count > 1 {
            let d = Geo.distanceToPolyline(pos, polyline)
            if offroute.update(distanceToRoute: d, accuracy: acc, time: loc.timestamp.timeIntervalSince1970) {
                NavEngine.log.info("off route \(Int(d)) m -> reroute")
                speak?(DirectionParser.offrouteText, routeAudio?.offrouteAudio)
                statusText = "再探索中"
                Task { await calculate(from: loc) }
            }
        }
    }

    static func coordinates(of line: MKPolyline) -> [CLLocationCoordinate2D] {
        let n = line.pointCount
        if n == 0 { return [] }
        var out = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: n)
        line.getCoordinates(&out, range: NSRange(location: 0, length: n))
        return out
    }
}
