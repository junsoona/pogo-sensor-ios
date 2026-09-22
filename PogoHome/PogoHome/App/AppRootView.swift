import SwiftUI

struct AppRootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("홈", systemImage: "house.fill") }

            RoomsView()
                .tabItem { Label("방", systemImage: "square.grid.2x2") }

            DevicesView()
                .tabItem { Label("기기", systemImage: "sensor.fill") }

            SettingsView()
                .tabItem { Label("설정", systemImage: "gearshape.fill") }
        }
        .task {
            appModel.start()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                appModel.stop()
            case .active:
                appModel.start()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}

#Preview {
    AppRootView()
        .environment(AppModel.preview)
}
