import SwiftUI

struct AppRootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppleHomeModel.self) private var appleHome
    @Environment(AppNavigator.self) private var navigator
    /// `nil` in previews: nothing is written for widgets there.
    @Environment(HomeGlancePublisher.self) private var glancePublisher: HomeGlancePublisher?
    /// `nil` in previews: nothing is written for Control Center there.
    @Environment(AppleHomePowerCatalogPublisher.self) private var powerCatalogPublisher: AppleHomePowerCatalogPublisher?

    var body: some View {
        @Bindable var navigator = navigator
        // A tab bar on iPhone and in narrow iPad windows; on a wide iPad the tab bar can become a
        // sidebar, and on the Mac it is one.
        TabView(selection: $navigator.selectedTab) {
            Tab("홈", systemImage: "house.fill", value: AppNavigator.Tab.home) {
                DashboardView()
                    .placesNavigationBarInMacTitleBar()
            }

            Tab("방", systemImage: "square.grid.2x2", value: AppNavigator.Tab.rooms) {
                RoomsView()
                    .placesNavigationBarInMacTitleBar()
            }

            Tab("기기", systemImage: "sensor.fill", value: AppNavigator.Tab.devices) {
                DevicesView()
                    .placesNavigationBarInMacTitleBar()
            }

            Tab("설정", systemImage: "gearshape.fill", value: AppNavigator.Tab.settings) {
                SettingsView()
                    .placesNavigationBarInMacTitleBar()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .task {
            // Idempotent: a second iPad/Mac window changes nothing here. Pausing and resuming
            // when every window leaves or one returns is `PogoHomeApp`'s job (the app-wide phase).
            appModel.start()
            // Independent of the POGO data source; resumes only if the user turned it on.
            appleHome.startIfEnabled()
            glancePublisher?.resume()
            powerCatalogPublisher?.start()
        }
        // A tapped widget (`HomeGlanceLink`).
        .onOpenURL { url in
            navigator.open(url)
        }
    }
}

/// One window's content. Every window (iPad multitasking, Mac) keeps its own tab and navigation
/// — its own `AppNavigator` — while the models are shared, so all windows show the same data.
struct AppSceneRoot: View {
    @State private var navigator = AppNavigator()

    var body: some View {
        AppRootView()
            .environment(navigator)
            // The key window's navigator, for the menu bar / keyboard shortcuts (`PogoHomeCommands`).
            .focusedSceneValue(\.appNavigator, navigator)
            .macMinimumWindowSize(CGSize(width: 480, height: 560))
    }
}

#Preview {
    AppRootView()
        .environment(AppModel.preview)
        .environment(AppleHomeModel.preview)
        .environment(AppNavigator())
}
