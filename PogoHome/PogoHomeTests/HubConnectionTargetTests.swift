import XCTest
@testable import PogoHome

/// What the settings connect to once a hub can be picked from the network, and how the app tells
/// the same hub at a new address from a different data source — for the app itself, the widgets'
/// glance and the Watch settings.
@MainActor
final class HubConnectionTargetTests: XCTestCase {
    typealias F = HubFixtures

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "HubConnectionTargetTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Settings → target

    func testTypedAddressIsIdentifiedByItsAddressAsBefore() {
        let target = DataSourceFactory.target(mode: .live, liveBaseURLString: "http://192.168.1.50:8787", selectedHubValue: nil)
        XCTAssertEqual(target.identity, .hub(URL(string: "http://192.168.1.50:8787")!))
        XCTAssertEqual(target.address?.absoluteString, "http://192.168.1.50:8787")
        XCTAssertNil(target.selectedHub)
        XCTAssertEqual(target.identity, DataSourceFactory.identity(mode: .live, liveBaseURLString: "http://192.168.1.50:8787"))
    }

    func testAPickedHubIsIdentifiedByItsHubIDAtItsVerifiedAddress() {
        let selection = F.selection(url: F.urlA2)
        let target = DataSourceFactory.target(mode: .live, liveBaseURLString: "http://stale:1", selectedHubValue: selection.storedValue)
        XCTAssertEqual(target.identity, .hub(id: F.hubA))
        XCTAssertEqual(target.address, F.urlA2)
        XCTAssertEqual(target.selectedHub, selection)
    }

    func testMockIgnoresThePickedHub() {
        let target = DataSourceFactory.target(mode: .mock, liveBaseURLString: "http://x:1", selectedHubValue: F.selection().storedValue)
        XCTAssertEqual(target.identity, .simulated)
        XCTAssertNil(target.address)
        XCTAssertTrue(DataSourceFactory.makeDataSource(for: target) is MockSensorDataSource, "Mock never becomes Live")
    }

    func testADamagedStoredChoiceFallsBackToTheTypedAddress() {
        let target = DataSourceFactory.target(mode: .live, liveBaseURLString: "http://192.168.1.50:8787", selectedHubValue: "{broken")
        XCTAssertEqual(target.identity, .hub(URL(string: "http://192.168.1.50:8787")!))
    }

    func testApplyingAHubStoresTheChoiceAndItsAddressAndSelectsLive() {
        defaults.set(DataSourceMode.mock.rawValue, forKey: PogoSettingsKeys.dataSourceMode)
        DataSourceFactory.apply(F.selection(url: F.urlA), in: defaults)
        XCTAssertEqual(defaults.string(forKey: PogoSettingsKeys.liveBaseURL), F.urlA.absoluteString)
        XCTAssertEqual(defaults.string(forKey: PogoSettingsKeys.dataSourceMode), DataSourceMode.live.rawValue)
        XCTAssertEqual(DataSourceFactory.target(in: defaults).identity, .hub(id: F.hubA))
    }

    func testTheChoiceIsRememberedAcrossLaunches() {
        DataSourceFactory.apply(F.selection(url: F.urlA2), in: defaults)
        // A new launch reads only what was stored.
        let relaunched = UserDefaults(suiteName: suiteName)!
        let target = DataSourceFactory.target(in: relaunched)
        XCTAssertEqual(target.identity, .hub(id: F.hubA))
        XCTAssertEqual(target.address, F.urlA2)
    }

    func testHubIdentitiesNeverEqualEachOtherOrSimulated() {
        XCTAssertNotEqual(SensorSourceIdentity.hub(id: F.hubA), .hub(id: F.hubB))
        XCTAssertNotEqual(SensorSourceIdentity.hub(id: F.hubA), .hub(F.urlA))
        XCTAssertTrue(SensorSourceIdentity.hub(id: F.hubA).isHub)
        XCTAssertTrue(SensorSourceIdentity.hub(F.urlA).isHub)
        XCTAssertFalse(SensorSourceIdentity.simulated.isHub)
    }

    // MARK: - AppModel

    private func liveSource(_ transport: ControllableSensorAPITransport, _ url: URL) -> LiveSensorDataSource {
        LiveSensorDataSource(
            endpoint: PogoAPIEndpoint(baseURL: url),
            transport: transport,
            sleeper: RecordingSleeper(),
            livenessIdleTimeout: 5,
            periodicRefreshInterval: nil
        )
    }

    private var hubModuleIDs: Set<UUID> {
        Set(try! PogoSnapshotMapper.decodeSnapshot(from: PogoAPIFixtures.fullSnapshotJSON()).modules.map(\.id))
    }

    func testTheSameHubAtANewAddressKeepsItsValuesAndReconnectsOnce() async throws {
        let old = ControllableSensorAPITransport { PogoAPIFixtures.fullSnapshotJSON() }
        let model = AppModel(dataSource: liveSource(old, F.urlA), sourceIdentity: .hub(id: F.hubA), sourceAddress: F.urlA)
        model.start()
        try await waitUntil { Set(model.snapshot.modules.map(\.id)) == self.hubModuleIDs }
        let lastSync = model.lastSyncAt

        let moved = ControllableSensorAPITransport { PogoAPIFixtures.fullSnapshotJSON() }
        model.replace(dataSource: liveSource(moved, F.urlA2), identity: .hub(id: F.hubA), address: F.urlA2)

        XCTAssertEqual(Set(model.snapshot.modules.map(\.id)), hubModuleIDs, "the same hub's values stay")
        XCTAssertEqual(model.lastSyncAt, lastSync, "and keep their age until the new address answers")
        XCTAssertEqual(model.sourceAddress, F.urlA2)
        try await waitUntil { await moved.snapshotFetchCount >= 1 }
        try await waitUntil { await moved.hasOpenEventStream }
        let opened = await moved.eventStreamOpenCount
        XCTAssertEqual(opened, 1, "exactly one new SSE connection")
        try await waitUntil { await !old.hasOpenEventStream }

        // The same address again (a second window reporting the same change): nothing happens.
        model.replace(dataSource: liveSource(moved, F.urlA2), identity: .hub(id: F.hubA), address: F.urlA2)
        try await Task.sleep(for: .milliseconds(50))
        let openedAgain = await moved.eventStreamOpenCount
        XCTAssertEqual(openedAgain, 1)
        model.stop()
    }

    func testAnotherHubStartsFromNothing() async throws {
        let transportA = ControllableSensorAPITransport { PogoAPIFixtures.fullSnapshotJSON() }
        let model = AppModel(dataSource: liveSource(transportA, F.urlA), sourceIdentity: .hub(id: F.hubA), sourceAddress: F.urlA)
        model.start()
        try await waitUntil { !model.snapshot.modules.isEmpty }

        let transportB = ControllableSensorAPITransport { PogoAPIFixtures.snapshotJSON(schemaVersion: 1) }
        model.replace(dataSource: liveSource(transportB, F.urlB), identity: .hub(id: F.hubB), address: F.urlB)
        XCTAssertTrue(model.snapshot.modules.isEmpty, "hub A's values are never shown as hub B's")
        XCTAssertNil(model.lastSyncAt)
        XCTAssertEqual(model.sourceIdentity, .hub(id: F.hubB))
        model.stop()
    }

    func testAnotherHubAtTheOldHubsAddressStillStartsFromNothing() async throws {
        let transportA = ControllableSensorAPITransport { PogoAPIFixtures.fullSnapshotJSON() }
        let model = AppModel(dataSource: liveSource(transportA, F.urlA), sourceIdentity: .hub(id: F.hubA), sourceAddress: F.urlA)
        model.start()
        try await waitUntil { !model.snapshot.modules.isEmpty }

        let transportB = ControllableSensorAPITransport { PogoAPIFixtures.snapshotJSON(schemaVersion: 1) }
        model.replace(dataSource: liveSource(transportB, F.urlA), identity: .hub(id: F.hubB), address: F.urlA)
        XCTAssertTrue(model.snapshot.modules.isEmpty, "two hub_ids are two sources, whatever their addresses")
        model.stop()
    }

    func testPickingTheHubAlreadyReachedByItsTypedAddressKeepsTheConnection() async throws {
        let transport = ControllableSensorAPITransport { PogoAPIFixtures.fullSnapshotJSON() }
        let model = AppModel(dataSource: liveSource(transport, F.urlA), sourceIdentity: .hub(F.urlA), sourceAddress: F.urlA)
        model.start()
        try await waitUntil { await transport.hasOpenEventStream }
        try await waitUntil { !model.snapshot.modules.isEmpty }

        model.replace(dataSource: liveSource(ControllableSensorAPITransport { PogoAPIFixtures.fullSnapshotJSON() }, F.urlA), identity: .hub(id: F.hubA), address: F.urlA)
        XCTAssertEqual(model.sourceIdentity, .hub(id: F.hubA))
        XCTAssertEqual(Set(model.snapshot.modules.map(\.id)), hubModuleIDs)
        try await Task.sleep(for: .milliseconds(50))
        let opened = await transport.eventStreamOpenCount
        XCTAssertEqual(opened, 1, "the running connection is kept, not reopened")
        model.stop()
    }

    func testTypingThePickedHubsOwnAddressKeepsTheConnection() async throws {
        let transport = ControllableSensorAPITransport { PogoAPIFixtures.fullSnapshotJSON() }
        let model = AppModel(dataSource: liveSource(transport, F.urlA), sourceIdentity: .hub(id: F.hubA), sourceAddress: F.urlA)
        model.start()
        try await waitUntil { await transport.hasOpenEventStream }
        try await waitUntil { !model.snapshot.modules.isEmpty }

        model.replace(dataSource: liveSource(ControllableSensorAPITransport { PogoAPIFixtures.fullSnapshotJSON() }, F.urlA), identity: .hub(F.urlA), address: F.urlA)
        XCTAssertEqual(model.sourceIdentity, .hub(F.urlA))
        XCTAssertEqual(Set(model.snapshot.modules.map(\.id)), hubModuleIDs)
        model.stop()
    }

    func testTypingAnAddressInPlaceOfAPickedHubAtAnotherAddressIsAnotherSource() async throws {
        let transport = ControllableSensorAPITransport { PogoAPIFixtures.fullSnapshotJSON() }
        let model = AppModel(dataSource: liveSource(transport, F.urlA), sourceIdentity: .hub(id: F.hubA), sourceAddress: F.urlA)
        model.start()
        try await waitUntil { !model.snapshot.modules.isEmpty }

        model.replace(dataSource: liveSource(ControllableSensorAPITransport { PogoAPIFixtures.fullSnapshotJSON() }, F.urlB), identity: .hub(F.urlB), address: F.urlB)
        XCTAssertTrue(model.snapshot.modules.isEmpty)
        model.stop()
    }

    func testSwitchingFromAPickedHubToMockDropsItAndMockNeverReachesLive() async throws {
        let transport = ControllableSensorAPITransport { PogoAPIFixtures.fullSnapshotJSON() }
        let model = AppModel(dataSource: liveSource(transport, F.urlA), sourceIdentity: .hub(id: F.hubA), sourceAddress: F.urlA)
        model.start()
        try await waitUntil { !model.snapshot.modules.isEmpty }

        model.replace(dataSource: MockSensorDataSource(tickInterval: .milliseconds(20)), identity: .simulated, address: nil)
        XCTAssertTrue(model.snapshot.modules.isEmpty)
        try await waitUntil { !model.snapshot.modules.isEmpty }
        let mockIDs = Set(model.snapshot.modules.map(\.id))

        let back = ControllableSensorAPITransport { PogoAPIFixtures.snapshotJSON(schemaVersion: 1) }
        model.replace(dataSource: liveSource(back, F.urlA), identity: .hub(id: F.hubA), address: F.urlA)
        XCTAssertTrue(model.snapshot.modules.isEmpty, "simulated modules never carry over into Live")
        try await waitUntil { model.lastSyncAt != nil }
        XCTAssertTrue(Set(model.snapshot.modules.map(\.id)).isDisjoint(with: mockIDs))
        model.stop()
    }

    // MARK: - Widgets and Watch

    func testTheWatchIsToldTheHubIDAndTheAddressTheAppUses() {
        defaults.set("http://typed:8787", forKey: PogoSettingsKeys.liveBaseURL)
        var settings = PhoneWatchSettings.make(defaults: defaults, snapshot: .init(timestamp: .now, rooms: [], modules: []), now: .now)
        XCTAssertNil(settings.hubID)
        XCTAssertEqual(settings.pogoSource, .hub(URL(string: "http://typed:8787")!))

        DataSourceFactory.apply(F.selection(url: F.urlA2), in: defaults)
        settings = PhoneWatchSettings.make(defaults: defaults, snapshot: .init(timestamp: .now, rooms: [], modules: []), now: .now)
        XCTAssertEqual(settings.hubID, F.hubA)
        XCTAssertEqual(settings.hubBaseURL, F.urlA2.absoluteString)
        XCTAssertEqual(settings.pogoSource, .hub(id: F.hubA), "the Watch files values under the same source as the app")
    }

    func testWatchSettingsFromAnOlderIPhoneStillDecode() throws {
        let old = #"{"schemaVersion":1,"updatedAt":0,"dataSourceMode":"live","hubBaseURL":"http://192.168.50.129:8787","selectedValueIDs":[],"moduleLabels":[]}"#
        let settings = try JSONDecoder().decode(WatchSettings.self, from: Data(old.utf8))
        XCTAssertNil(settings.hubID)
        XCTAssertEqual(settings.pogoSource, .hub(F.urlA))
    }

    func testAGlanceFromTheSameHubAtANewAddressIsKeptAndAnotherHubsIsDropped() {
        let glance = GlanceFixtures.build(
            pogo: GlanceFixtures.pogoInput(GlanceFixtures.home([GlanceFixtures.climate()]), source: .hub(id: F.hubA)),
            appleHome: GlanceFixtures.appleHomeInput(state: .ready),
            now: GlanceFixtures.t0
        )
        XCTAssertEqual(glance.keepingPogo(from: .hub(id: F.hubA)), glance, "a new address of the same hub keeps the widgets' values")
        XCTAssertTrue(glance.keepingPogo(from: .hub(id: F.hubB)).pogoSensors.isEmpty, "another hub's values are dropped")
    }
}
