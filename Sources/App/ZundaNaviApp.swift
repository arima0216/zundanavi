import SwiftUI

@main
struct ZundaNaviApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(model.history)
                .environmentObject(model.battery)
                .onAppear {
                    model.bootstrap()
                }
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .active {
                model.becameActive()
            }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            NavView()
                .tabItem { Label("ナビ", systemImage: "location.fill") }
            HistoryView()
                .tabItem { Label("履歴", systemImage: "clock") }
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
        .tint(Color(red: 0.30, green: 0.69, blue: 0.31))
    }
}
