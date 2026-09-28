import SwiftUI
import WatchKit

@main
struct PogoHomeWatchApp: App {
    @State private var model = WatchAppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model.sync)
                .environment(model.power)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.sync.phoneLinkDidChange(model.phone.linkStatus)
                model.sync.startForegroundUpdates()
                Task { await model.power.load() }
            case .background:
                model.sync.stopForegroundUpdates()
                model.scheduleBackgroundRefresh()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        // The iPhone handed something over while the app wasn't running (complication update).
        .backgroundTask(.watchConnectivity) {
            await WatchAppModel.shared.phone.waitForPendingContent()
        }
        // Budgeted by watchOS (a few an hour with a complication on the face): the bridge directly
        // only — this can bring new values only on the bridge's network.
        .backgroundTask(.appRefresh(WatchAppModel.refreshTaskIdentifier)) {
            await WatchAppModel.shared.backgroundRefresh()
        }
    }
}

/// The Watch app's long-lived objects, shared by the UI and background tasks.
@MainActor
final class WatchAppModel {
    static let shared = WatchAppModel()
    static let refreshTaskIdentifier = "com.junsoona.PogoHome.watch.refresh"
    /// How often a background refresh is asked for; watchOS decides when it actually runs.
    static let backgroundRefreshInterval: TimeInterval = 20 * 60

    let phone: WatchPhoneLink
    let sync: WatchSyncEngine
    let power: WatchPowerController

    private init() {
        let phone = WatchPhoneLink()
        let sync = WatchSyncEngine(
            store: WatchStateStore.shared(),
            hub: WatchHubClient(),
            phone: phone,
            reloader: WatchWidgetReloader()
        )
        phone.onPayload = { [weak sync] payload in sync?.receivePush(payload) }
        phone.onLinkChange = { [weak sync] status in sync?.phoneLinkDidChange(status) }
        phone.activate()
        self.phone = phone
        self.sync = sync
        // One HomeKit connection for the Watch's Apple Home page; each action still reads the device.
        self.power = WatchPowerController(
            gateway: HomeKitPowerControlGateway(homesTimeout: .seconds(10), readTimeout: 8, writeTimeout: 10, reusesHomeManager: true)
        )
        #if DEBUG
        Self.applyDebugSettings(to: sync)
        #endif
    }

    func backgroundRefresh() async {
        await sync.refresh(allowsPhone: false)
        scheduleBackgroundRefresh()
    }

    func scheduleBackgroundRefresh() {
        // Only worth it when there is a bridge the Watch could reach by itself.
        guard sync.settings?.directHubURL != nil else { return }
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date(timeIntervalSinceNow: Self.backgroundRefreshInterval),
            userInfo: Self.refreshTaskIdentifier as NSString
        ) { _ in }
    }

    #if DEBUG
    /// Simulator testing without a paired iPhone: `-PogoWatchDebugHubURL http://127.0.0.1:8787`
    /// (and optionally `-PogoWatchDebugSelection <id,id>`) stand in for the iPhone's settings when
    /// none were ever received.
    private static func applyDebugSettings(to sync: WatchSyncEngine) {
        let defaults = UserDefaults.standard
        guard sync.settings == nil, let url = defaults.string(forKey: "PogoWatchDebugHubURL") else { return }
        let selection = defaults.string(forKey: "PogoWatchDebugSelection")?.split(separator: ",").map(String.init) ?? []
        sync.receivePush(WatchSyncPayload(
            sentAt: Date(),
            glance: nil,
            settings: WatchSettings(updatedAt: .distantPast, dataSourceMode: .live, hubBaseURL: url, selectedValueIDs: selection, moduleLabels: [])
        ))
    }
    #endif
}
