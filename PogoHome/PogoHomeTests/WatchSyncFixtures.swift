import Foundation
@testable import PogoHome

/// Scripted stand-ins for the Watch's bridge client, iPhone link, store and widget reloader.
enum WatchFixtures {
    typealias F = GlanceFixtures

    static let hubURL = "http://192.168.50.129:8787"

    static func settings(
        updatedAt: Date = F.t0,
        mode: WatchSettings.DataSourceMode = .live,
        hubURL: String? = hubURL,
        selection: [HomeGlanceValueID] = [F.temperatureID],
        labels: [WatchModuleLabel] = []
    ) -> WatchSettings {
        WatchSettings(updatedAt: updatedAt, dataSourceMode: mode, hubBaseURL: hubURL, selectedValueIDs: selection.map(\.stringValue), moduleLabels: labels)
    }

    /// The iPhone's glance: POGO confirmed at `at`, Apple Home read at `at`.
    static func phoneGlance(at: Date, temperature: Double = 23.4, appleHome: AppleHomeAccessState = .ready) -> HomeGlanceSnapshot {
        F.build(
            pogo: F.pogoInput(F.home([F.climate(temperature: temperature), F.air()]), lastSyncAt: at, sessionStartedAt: at.addingTimeInterval(-10)),
            appleHome: F.appleHomeInput(state: appleHome),
            now: at
        )
    }

    static func payload(glance: HomeGlanceSnapshot?, settings: WatchSettings = settings(), sentAt: Date = F.t0) -> WatchSyncPayload {
        WatchSyncPayload(sentAt: sentAt, glance: glance, settings: settings)
    }

    /// The bridge's own answer: catalog names, no user rooms.
    static func hubSnapshot(temperature: Double = 24.0, climateOnline: Bool = true, airReadings: Bool = true) -> HomeSnapshot {
        let climate = F.climate(online: climateOnline, temperature: temperature, name: "SGP41 가스 센서")
        let air = F.air(readings: airReadings)
        let unspecified = ModuleCatalog.unspecifiedRoom(in: .korean)
        func placed(_ module: SensorModule) -> SensorModule {
            SensorModule(id: module.id, name: module.name, roomID: unspecified.id, readings: module.readings, isOnline: module.isOnline, lastSeen: module.lastSeen)
        }
        return HomeSnapshot(timestamp: F.t0, rooms: [unspecified], modules: [placed(climate), placed(air)])
    }
}

final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
final class ScriptedHub: WatchHubFetching {
    var results: [Result<HomeSnapshot, Error>]
    private(set) var fetchCount = 0
    private(set) var urls: [URL] = []

    init(_ results: [Result<HomeSnapshot, Error>] = []) {
        self.results = results
    }

    func fetchSnapshot(from baseURL: URL) async throws -> HomeSnapshot {
        fetchCount += 1
        urls.append(baseURL)
        guard !results.isEmpty else { throw URLError(.timedOut) }
        return try (results.count > 1 ? results.removeFirst() : results[0]).get()
    }
}

@MainActor
final class ScriptedPhone: WatchPhoneRelaying {
    var isPhoneReachable: Bool
    var replies: [Result<WatchRelayReply, Error>]
    private(set) var requestCount = 0

    init(reachable: Bool = false, _ replies: [Result<WatchRelayReply, Error>] = []) {
        self.isPhoneReachable = reachable
        self.replies = replies
    }

    func requestRefresh() async throws -> WatchRelayReply {
        requestCount += 1
        guard !replies.isEmpty else { throw WatchPhoneRelayError.timedOut }
        return try (replies.count > 1 ? replies.removeFirst() : replies[0]).get()
    }
}

final class InMemoryWatchStore: WatchStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: WatchStoredState
    private(set) var saveCount = 0

    init(_ state: WatchStoredState = .empty) {
        stored = state
    }

    var state: WatchStoredState { lock.withLock { stored } }

    func load() -> WatchStoredState { lock.withLock { stored } }

    func save(_ state: WatchStoredState) throws {
        lock.withLock {
            stored = state
            saveCount += 1
        }
    }
}

@MainActor
final class CountingWatchReloader: WatchWidgetReloading {
    private(set) var count = 0
    func reloadWidgets() { count += 1 }
}
