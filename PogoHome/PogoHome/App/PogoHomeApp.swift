import SwiftUI

@main
struct PogoHomeApp: App {
    @AppStorage(PogoSettingsKeys.dataSourceMode) private var dataSourceModeRaw = DataSourceMode.live.rawValue
    @AppStorage(PogoSettingsKeys.liveBaseURL) private var liveBaseURLString = PogoAPIEndpoint.defaultBaseURLString

    @State private var appModel: AppModel

    init() {
        let mode = DataSourceMode(rawValue: UserDefaults.standard.string(forKey: PogoSettingsKeys.dataSourceMode) ?? "") ?? .live
        let urlString = UserDefaults.standard.string(forKey: PogoSettingsKeys.liveBaseURL) ?? PogoAPIEndpoint.defaultBaseURLString
        let initialDataSource = DataSourceFactory.makeDataSource(mode: mode, liveBaseURLString: urlString)
        _appModel = State(initialValue: AppModel(dataSource: initialDataSource))
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(appModel)
                .onChange(of: dataSourceModeRaw) { _, _ in reconnect() }
                .onChange(of: liveBaseURLString) { _, _ in reconnect() }
        }
    }

    /// Cancels the current data source and starts exactly one new connection reflecting
    /// the latest mode/URL from Settings.
    private func reconnect() {
        let mode = DataSourceMode(rawValue: dataSourceModeRaw) ?? .live
        let newDataSource = DataSourceFactory.makeDataSource(mode: mode, liveBaseURLString: liveBaseURLString)
        appModel.replace(dataSource: newDataSource)
    }
}
