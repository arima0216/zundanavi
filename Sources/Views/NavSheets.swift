import MapKit
import SwiftUI

/// アクションデッキ（番号付きカード。タップで開く→「済」、次を強調）
struct DeckSheet: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if let d = model.deck {
                    ForEach(d.items) { item in
                        let done = d.isDone(item.n)
                        let isCurrent = d.current?.n == item.n
                        Button {
                            model.openDeckItem(item)
                        } label: {
                            HStack(spacing: 12) {
                                Text(String(item.n))
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(width: 32, height: 32)
                                    .background(Circle().fill(done ? Color.gray : (isCurrent ? Color.orange : Color.blue)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(isCurrent ? .headline : .body)
                                        .foregroundColor(done ? .secondary : .primary)
                                    Text(item.url)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if done {
                                    Text("済")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(isCurrent ? Color.orange.opacity(0.12) : Color.clear)
                    }
                } else {
                    Text("デッキは空なのだ")
                }
            }
            .navigationTitle("アクションデッキ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { model.closeDeck() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 台本プレイヤー（手順リスト、現在手順を強調、次/もう一回/前）
struct ScriptSheet: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var script: ScriptPlayer

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    if let info = script.info {
                        ForEach(Array(info.steps.enumerated()), id: \.offset) { pos, st in
                            let cur = pos == script.cursor.idx
                            VStack(alignment: .leading, spacing: 2) {
                                Text(st.text)
                                    .font(cur ? .headline : .body)
                                    .foregroundColor(pos < script.cursor.idx ? .secondary : .primary)
                                if let lm = st.landmark, !lm.isEmpty {
                                    Text("目印: " + lm)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .listRowBackground(cur ? Color.green.opacity(0.15) : Color.clear)
                        }
                    }
                }
                .listStyle(.plain)
                HStack(spacing: 10) {
                    Button("前") { model.scriptAction("prev", sync: true) }
                        .frame(maxWidth: .infinity)
                    Button("もう一回") { model.scriptAction("repeat", sync: true) }
                        .frame(maxWidth: .infinity)
                    Button("次") { model.scriptAction("next", sync: true) }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.borderedProminent)
                }
                .buttonStyle(.bordered)
                .padding(16)
            }
            .navigationTitle(script.info?.title ?? "台本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { model.closeScript() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 地図タブ（確認用）: 現在地・経路・手順点・ジオフェンス
struct MapTabView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: NavEngine
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                UserAnnotation()
                if nav.routeCoords.count > 1 {
                    MapPolyline(coordinates: nav.routeCoords)
                        .stroke(Color.blue, lineWidth: 5)
                }
                ForEach(nav.steps, id: \.idx) { st in
                    Annotation(String(st.idx + 1), coordinate: CLLocationCoordinate2D(latitude: st.point.lat, longitude: st.point.lon)) {
                        Circle()
                            .fill(st.idx == nav.currentStepIdx ? Color.orange : Color.blue)
                            .frame(width: 12, height: 12)
                    }
                }
                ForEach(model.fences) { f in
                    MapCircle(center: CLLocationCoordinate2D(latitude: f.lat, longitude: f.lon), radius: f.radiusM)
                        .stroke(Color.green, lineWidth: 1)
                        .foregroundStyle(Color.green.opacity(0.2))
                }
                if let d = nav.destination {
                    Marker(d.name, coordinate: CLLocationCoordinate2D(latitude: d.lat, longitude: d.lon))
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .safeAreaInset(edge: .bottom) {
                Text(nav.statusText)
                    .font(.footnote)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
            }
            .navigationTitle("地図")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
