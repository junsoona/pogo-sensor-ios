import Observation
import SwiftUI
import os

@main
struct PogoHomeApp: App {
    @AppStorage(PogoSettingsKeys.dataSourceMode) private var dataSourceModeRaw = DataSourceMode.live.rawValue
    @AppStorage(PogoSettingsKeys.liveBaseURL) private var liveBaseURLString = PogoAPIEndpoint.defaultBaseURLString
    @AppStorage(PogoSettingsKeys.selectedHub) private var selectedHubValue = ""

    @State private var appModel: AppModel
    /// Separate from `appModel` so nothing about Apple Home can affect POGO sensor data.
    @State private var appleHomeModel: AppleHomeModel
    /// Keeps the widgets' stored copy of the home in step with the two models above.
    @State private var glancePublisher: HomeGlancePublisher
    /// Keeps the Control Center power controls' target list and states in step with Apple Home.
    @State private var powerCatalogPublisher: AppleHomePowerCatalogPublisher
    /// Hands the home's state and the Watch settings to the Apple Watch, and answers its refresh
    /// requests. Inactive where no Watch can be paired (iPad, Mac).
    @State private var watchRelay: PhoneWatchRelay
    /// Finds the hub picked in "Find hubs" again when its address changes.
    @State private var hubRelocator: HubRelocator
    /// Read here, in the `App`, this is the phase of the app as a whole: `.active` while any
    /// window is, `.background` only once every window is. A per-window phase would stop the
    /// POGO connection when one iPad/Mac window goes away while another is still on screen.
    @Environment(\.scenePhase) private var scenePhase

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.junsoona.PogoHome",
        category: "PogoHomeApp"
    )

    init() {
        let initialTarget = DataSourceFactory.target(in: .standard)
        let initialDataSource = DataSourceFactory.makeDataSource(for: initialTarget)
        let configurationStore: HomeConfigurationStore
        var configurationStoreLaunchError: String?
        do {
            configurationStore = try SwiftDataHomeConfigurationStore()
        } catch {
            // A damaged or unavailable local store must not prevent live sensor data from
            // opening. The in-memory fallback keeps the app usable for this launch, but the
            // failure itself must still be visible — logged here, and surfaced to the user
            // via AppModel.configurationError (shown in Settings) rather than swallowed.
            let message = error.localizedDescription
            Self.logger.fault("failed to open persistent configuration store, falling back to in-memory: \(message, privacy: .public)")
            configurationStore = InMemoryHomeConfigurationStore()
            configurationStoreLaunchError = String(
                localized: "방·기기 설정을 기기에 저장할 수 없습니다. 이번 실행 동안의 변경사항은 앱을 종료하면 사라집니다. (\(message))",
                comment: "Shown in Settings when the on-device configuration store can't be opened"
            )
        }
        let appModel = AppModel(
            dataSource: initialDataSource,
            sourceIdentity: initialTarget.identity,
            sourceAddress: initialTarget.address,
            configurationStore: configurationStore,
            configurationStoreLaunchError: configurationStoreLaunchError,
            // Keychain credentials and a per-hub cache of the hub's settings.
            sharedSettings: SharedSettingsController()
        )
        let appleHomeModel = AppleHomeModel(provider: AppleHomeProviderFactory.makeDefault())
        _appModel = State(initialValue: appModel)
        _appleHomeModel = State(initialValue: appleHomeModel)
        let glancePublisher = HomeGlancePublisher(
            appModel: appModel,
            appleHome: appleHomeModel,
            store: HomeGlanceStore.shared(),
            reloader: WidgetCenterReloader(),
            isSimulatedData: {
                DataSourceMode(rawValue: UserDefaults.standard.string(forKey: PogoSettingsKeys.dataSourceMode) ?? "") == .mock
            }
        )
        _glancePublisher = State(initialValue: glancePublisher)
        // Activated here, not in a view: iOS may launch the app in the background only to answer
        // the Watch, without ever creating a window.
        let watchRelay = PhoneWatchRelay(appModel: appModel, publisher: glancePublisher)
        glancePublisher.onStored = { [weak watchRelay] glance in watchRelay?.glanceWasStored(glance) }
        watchRelay.activate()
        _watchRelay = State(initialValue: watchRelay)
        let hubRelocator = HubRelocator(
            selection: { DataSourceFactory.target(in: .standard).selectedHub },
            onRelocate: { hub in DataSourceFactory.apply(hub, in: .standard) }
        )
        _hubRelocator = State(initialValue: hubRelocator)
        Self.observeConnectionStatus(of: appModel, for: hubRelocator)
        _powerCatalogPublisher = State(
            initialValue: AppleHomePowerCatalogPublisher(
                appleHome: appleHomeModel,
                store: AppleHomePowerStore.shared(),
                reloader: ControlCenterPowerReloader()
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            AppSceneRoot()
                .environment(appModel)
                .environment(appleHomeModel)
                .environment(glancePublisher)
                .environment(powerCatalogPublisher)
                .environment(watchRelay)
                .onChange(of: dataSourceModeRaw) { _, _ in
                    reconnect()
                    watchRelay.settingsDidChange()
                }
                .onChange(of: liveBaseURLString) { _, _ in
                    reconnect()
                    watchRelay.settingsDidChange()
                }
                .onChange(of: selectedHubValue) { _, _ in
                    reconnect()
                    hubRelocator.selectionDidChange()
                    watchRelay.settingsDidChange()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                // First, while the connection state is still the real one: stopping below is
                // the app going away, not the connection failing.
                glancePublisher.suspend()
                appModel.stop()
                hubRelocator.suspend()
            case .active:
                appModel.start()
                // Rooms or names edited in the Home app meanwhile; reads no device.
                appleHomeModel.resynchronize()
                glancePublisher.resume()
                // A Watch app installed or removed meanwhile may not have been reported.
                watchRelay.recheck()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .commands {
            PogoHomeCommands()
        }
    }

    /// Cancels the current data source and starts exactly one new connection reflecting
    /// the latest mode/URL from Settings — unless they still name the source already in use
    /// (each open window reports the same change; an edit may resolve to the same hub), which
    /// keeps its connection and values.
    ///
    /// The same hub (by `hub_id`) at a new address moves the connection but keeps its values;
    /// anything else that is a different source starts from nothing (`AppModel.replace`).
    private func reconnect() {
        let target = DataSourceFactory.target(
            mode: DataSourceMode(rawValue: dataSourceModeRaw) ?? .live,
            liveBaseURLString: liveBaseURLString,
            selectedHubValue: selectedHubValue
        )
        guard target.identity != appModel.sourceIdentity || target.address != appModel.sourceAddress else { return }
        appModel.replace(dataSource: DataSourceFactory.makeDataSource(for: target), identity: target.identity, address: target.address)
    }

    /// Hands every Live connection status to `relocator`, independent of any window (so it also
    /// works when the app only runs for the Watch).
    private static func observeConnectionStatus(of appModel: AppModel, for relocator: HubRelocator) {
        let status = withObservationTracking {
            appModel.connectionStatus
        } onChange: { [weak appModel, weak relocator] in
            Task { @MainActor in
                guard let appModel, let relocator else { return }
                observeConnectionStatus(of: appModel, for: relocator)
            }
        }
        relocator.connectionStatusDidChange(status)
    }
}
