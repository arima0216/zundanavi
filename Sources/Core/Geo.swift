import Foundation

/// 緯度経度（MapKit 非依存。テストのため Foundation だけで書く）。
struct Coord: Equatable {
    var lat: Double
    var lon: Double

    init(_ lat: Double, _ lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

enum Geo {
    static let earthRadius = 6_371_000.0

    /// 2 点間の距離 (m)。ハバーサイン。
    static func distance(_ a: Coord, _ b: Coord) -> Double {
        let p1 = a.lat * .pi / 180
        let p2 = b.lat * .pi / 180
        let dp = (b.lat - a.lat) * .pi / 180
        let dl = (b.lon - a.lon) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadius * atan2(h.squareRoot(), (1 - h).squareRoot())
    }

    /// 基準点まわりの平面座標 (m)。
    static func project(_ c: Coord, origin: Coord) -> (x: Double, y: Double) {
        let k = earthRadius * .pi / 180
        let x = (c.lon - origin.lon) * k * cos(origin.lat * .pi / 180)
        let y = (c.lat - origin.lat) * k
        return (x, y)
    }

    /// 点から折れ線までの最短距離 (m)。折れ線が空なら無限大。
    static func distanceToPolyline(_ p: Coord, _ line: [Coord]) -> Double {
        if line.isEmpty { return .infinity }
        if line.count == 1 { return distance(p, line[0]) }
        var best = Double.infinity
        for i in 0..<(line.count - 1) {
            let a = project(line[i], origin: p)
            let b = project(line[i + 1], origin: p)
            let dx = b.x - a.x
            let dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var t = 0.0
            if len2 > 0 {
                t = -(a.x * dx + a.y * dy) / len2
                t = max(0, min(1, t))
            }
            let cx = a.x + t * dx
            let cy = a.y + t * dy
            let d = (cx * cx + cy * cy).squareRoot()
            if d < best { best = d }
        }
        return best
    }

    /// a から b へ方位 (度) と距離 (m) で動かした点（テスト用の合成座標）。
    static func offset(_ a: Coord, northMeters: Double, eastMeters: Double) -> Coord {
        let k = earthRadius * .pi / 180
        let lat = a.lat + northMeters / k
        let lon = a.lon + eastMeters / (k * cos(a.lat * .pi / 180))
        return Coord(lat, lon)
    }
}
