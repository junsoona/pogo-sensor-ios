import XCTest
@testable import PogoHome

/// Switching data sources (Mock ↔ Live, or another hub) versus the same source pausing: a
/// different source starts from nothing, the same source keeps its last values. The field bug:
/// Mock → Live with the hub off kept the Mock modules on screen, marked Normal.
@MainActor
final class AppModelSourceSwitchTests: XCTestCase {
    private let hubA = SensorSourceIdentity.hub(URL(string: "http://hub-a.local:8787")!)
    private let hubB = SensorSourceIdentity.hub(URL(string: "http://hub-b.local:8787")!)

    private var hubModuleIDs: Set<UUID> {
        Set(try! PogoSnapshotMapper.decodeSnapshot(from: PogoAPIFixtures.fullSnapshotJSON()).modules.map(\.id))
    }

    private var mockModuleIDs: Set<UUID> {
        Set(MockSensorFixtures.modules(referenceDate: Date()).map(\.id))
    }

    private func unreachableLiveSource() -> LiveSensorDataSource {
        LiveSensorDataSource(
            endpoint: PogoAPIEndpoint(baseURL: URL(string: "http://hub-a.local:8787")!),
            transport: ScriptedSensorAPITransport(snapshotScript: [.failure(URLError(.cannotConnectToHost))], eventScript: []),
            periodicRefreshInterval: nil
        )
    }

    private func reachableLiveSource(_ transport: ControllableSensorAPITransport, baseURL: String = "http://hub-a.local:8787") -> LiveSensorDataSource {
        LiveSensorDataSource(
            endpoint: PogoAPIEndpoint(baseURL: URL(string: baseURL)!),
            transport: transport,
            sleeper: RecordingSleeper(),
            livenessIdleTimeout: 5,
            periodicRefreshInterval: nil
        )
    }

    private func mockModel(store: HomeConfigurationStore = InMemoryHomeConfigurationStore(language: .korean)) async throws -> AppModel {
        let model = AppModel(
            dataSource: MockSensorDataSource(tickInterval: .milliseconds(20)),
            sourceIdentity: .simulated,
            configurationStore: store,
            language: .korean
        )
        model.start()
        try await waitUntil { !model.snapshot.modules.isEmpty }
        return model
    }

    // MARK: - Mock → Live

    func testMockThenUnreachableLiveDropsEveryMockModuleReadingAndSyncTimeAtOnce() async throws {
        let model = try await mockModel()
        XCTAssertNotNil(model.lastSyncAt)

        model.replace(dataSource: unreachableLiveSource(), identity: hubA)

        // Synchronously at the switch — never a frame of Mock data under the Live source.
        XCTAssertTrue(model.snapshot.modules.isEmpty)
        XCTAssertTrue(model.snapshot.modules.flatMap(\.readings).isEmpty)
        XCTAssertNil(model.lastSyncAt)
        XCTAssertFalse(model.isRegistryRecovering)
        XCTAssertEqual(model.sourceIdentity, hubA)
        XCTAssertEqual(model.health, .waitingForData)
        XCTAssertEqual(model.dataWait, .connecting)

        // The hub can't be reached: said so, and nothing simulated stands in for it.
        try await waitUntil {
            if case .failed = model.connectionStatus { return true }
            return false
        }
        XCTAssertEqual(model.dataWait, .unreachable)
        XCTAssertEqual(model.health, .waitingForData)
        XCTAssertTrue(model.snapshot.modules.isEmpty, "a failed Live connection never falls back to Mock data")
        XCTAssertNil(model.lastSyncAt)
        // Nothing for the Watch to name either.
        XCTAssertEqual(PhoneWatchSettings.moduleLabels(of: model.snapshot), [])
        model.stop()
    }

    func testReapplyingTheConfigurationAfterASwitchNeverBringsMockModulesBack() async throws {
        let model = try await mockModel()
        let mockModule = try XCTUnwrap(model.snapshot.modules.first)
        model.replace(dataSource: unreachableLiveSource(), identity: hubA)

        // Every configuration edit re-applies the configuration to the last source snapshot.
        try await model.updateHomeName(input: "작업실 집")
        let room = try await model.createRoom(name: "서재", symbolName: "books.vertical.fill")
        XCTAssertTrue(model.snapshot.modules.isEmpty)
        await XCTAssertThrowsErrorAsync(try await model.updateModule(id: mockModule.id, customName: "x", roomID: room.id)) { error in
            XCTAssertEqual(error as? HomeConfigurationError, .moduleNotFound)
        }
        XCTAssertNil(model.module(with: mockModule.id), "a detail screen for the old module finds nothing")
        model.stop()
    }

    func testTheFirstLiveSnapshotShowsOnlyTheHubsModules() async throws {
        let model = try await mockModel()
        let transport = ControllableSensorAPITransport { PogoAPIFixtures.fullSnapshotJSON() }

        model.replace(dataSource: reachableLiveSource(transport), identity: hubA)
        try await waitUntil { !model.snapshot.modules.isEmpty }

        XCTAssertEqual(Set(model.snapshot.modules.map(\.id)), hubModuleIDs)
        XCTAssertTrue(Set(model.snapshot.modules.map(\.id)).isDisjoint(with: mockModuleIDs))
        XCTAssertNotNil(model.lastSyncAt)
        model.stop()
    }

    func testLiveMockLiveRepeatedlyAlwaysShowsOnlyTheCurrentSource() async throws {
        let transport = ControllableSensorAPITransport { PogoAPIFixtures.fullSnapshotJSON() }
        let model = AppModel(
            dataSource: reachableLiveSource(transport),
            sourceIdentity: hubA,
            configurationStore: InMemoryHomeConfigurationStore(language: .korean),
            language: .korean
        )
        model.start()

        for round in 0..<3 {
            try await waitUntil { Set(model.snapshot.modules.map(\.id)) == self.hubModuleIDs }

            model.replace(dataSource: MockSensorDataSource(tickInterval: .milliseconds(20)), identity: .simulated)
            XCTAssertTrue(model.snapshot.modules.isEmpty, "round \(round): Live modules left at the switch to Mock")
            try await waitUntil { Set(model.snapshot.modules.map(\.id)) == self.mockModuleIDs }

            model.replace(dataSource: reachableLiveSource(transport), identity: hubA)
            XCTAssertTrue(model.snapshot.modules.isEmpty, "round \(round): Mock modules left at the switch to Live")
            XCTAssertNil(model.lastSyncAt)
        }
        try await waitUntil { Set(model.snapshot.modules.map(\.id)) == self.hubModuleIDs }
        model.stop()
    }

    func testAnotherHubIsAnotherSource() async throws {
        let transportA = ControllableSensorAPITransport { PogoAPIFixtures.fullSnapshotJSON() }
        let model = AppModel(dataSource: reachableLiveSource(transportA), sourceIdentity: hubA)
        model.start()
        try await waitUntil { !model.snapshot.modules.isEmpty }

        let transportB = ControllableSensorAPITransport { PogoAPIFixtures.snapshotJSON(schemaVersion: 1) }
        model.replace(dataSource: reachableLiveSource(transportB, baseURL: "http://hub-b.local:8787"), identity: hubB)

        XCTAssertTrue(model.snapshot.modules.isEmpty, "hub A's modules are never shown as hub B's")
        XCTAssertNil(model.lastSyncAt)
        try await waitUntil { await transportB.snapshotFetchCount >= 1 }
        try await waitUntil { model.lastSyncAt != nil }
        XCTAssertTrue(model.snapshot.modules.isEmpty, "hub B reported no modules")
        model.stop()
    }

    // MARK: - Late events of the previous source

    func testLateUpdatesStatusesAndRefreshResultsOfThePreviousSourceAreIgnored() async throws {
        let old = GatedDataSource(initial: MockSensorFixtures.previewSnapshot, periodicRefreshInterval: 0.01)
        let model = AppModel(dataSource: old, sourceIdentity: .simulated)
        model.start()
        try await waitUntil { !model.snapshot.modules.isEmpty }
        // A periodic GET of the old source is in flight when the switch happens.
        try await waitUntil { old.hasPendingFetch }

        let new = GatedDataSource(initial: nil, status: .connecting)
        model.replace(dataSource: new, identity: hubA)
        try await waitUntil { model.connectionStatus == .connecting }

        old.updatesContinuation?.yield(MockSensorFixtures.previewSnapshot)
        old.statusContinuation?.yield(.connected)
        old.releaseFetch(with: MockSensorFixtures.previewSnapshot)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(model.snapshot.modules.isEmpty)
        XCTAssertNil(model.lastSyncAt)
        XCTAssertEqual(model.connectionStatus, .connecting)
        XCTAssertEqual(model.dataWait, .connecting)
        XCTAssertEqual(new.updatesCallCount, 1, "exactly one connection to the new source")
        model.stop()
    }

    // MARK: - The same source

    func testTheSameLiveHubStoppingAndStartingKeepsItsLastValues() async throws {
        let transport = ControllableSensorAPITransport { PogoAPIFixtures.fullSnapshotJSON() }
        let model = AppModel(dataSource: reachableLiveSource(transport), sourceIdentity: hubA)
        model.start()
        try await waitUntil { await transport.hasOpenEventStream }
        await transport.sendLine(": heartbeat")
        try await waitUntil { model.health.isCurrentStateVerified }
        let lastSync = model.lastSyncAt

        // Background.
        model.stop()
        XCTAssertEqual(Set(model.snapshot.modules.map(\.id)), hubModuleIDs, "the last values stay on screen")
        XCTAssertEqual(model.lastSyncAt, lastSync)
        XCTAssertEqual(model.health, .reconnecting, "but aren't presented as current")

        // Foreground.
        let opened = await transport.eventStreamOpenCount
        model.start()
        try await waitUntil { await transport.hasOpenEventStream(after: opened) }
        XCTAssertEqual(Set(model.snapshot.modules.map(\.id)), hubModuleIDs)
        await transport.sendLine(": heartbeat")
        try await waitUntil { model.health.isCurrentStateVerified }
        model.stop()
    }

    func testReplacingWithTheSameSourceKeepsTheConnectionAndItsValues() async throws {
        let transport = ControllableSensorAPITransport { PogoAPIFixtures.fullSnapshotJSON() }
        let model = AppModel(dataSource: reachableLiveSource(transport), sourceIdentity: hubA)
        model.start()
        try await waitUntil { !model.snapshot.modules.isEmpty }
        let snapshot = model.snapshot
        let lastSync = model.lastSyncAt

        // The same address written differently, reported once per open window.
        let sameHub = SensorSourceIdentity.hub(URL(string: "HTTP://Hub-A.local:8787/")!)
        XCTAssertEqual(sameHub, hubA)
        let unused = GatedDataSource(initial: nil)
        model.replace(dataSource: unused, identity: sameHub)
        model.replace(dataSource: unused, identity: sameHub)

        XCTAssertEqual(unused.updatesCallCount, 0, "no second connection")
        XCTAssertEqual(model.snapshot, snapshot)
        XCTAssertEqual(model.lastSyncAt, lastSync)
        let fetches = await transport.snapshotFetchCount
        XCTAssertEqual(fetches, 1)
        model.stop()
    }

    // MARK: - User data

    func testSwitchingKeepsTheHomeNameRoomsAndModuleNamesAndPlacement() async throws {
        let store = InMemoryHomeConfigurationStore(language: .korean)
        let model = try await mockModel(store: store)
        try await model.updateHomeName(input: "작업실 집")
        let room = try await model.createRoom(name: "서재", symbolName: "books.vertical.fill")
        let module = try XCTUnwrap(model.snapshot.modules.first)
        try await model.updateModule(id: module.id, customName: "책상 센서", roomID: room.id)
        let rooms = model.editableRooms

        model.replace(dataSource: unreachableLiveSource(), identity: hubA)
        XCTAssertEqual(model.homeName, "작업실 집")
        XCTAssertEqual(model.editableRooms, rooms)
        XCTAssertEqual(model.snapshot.rooms.map(\.id), rooms.map(\.id), "rooms stay listed, just without modules")
        XCTAssertEqual(model.customName(forModule: module.id), "책상 센서")

        // Back to Mock: the same module gets its saved name and room again.
        model.replace(dataSource: MockSensorDataSource(tickInterval: .milliseconds(20)), identity: .simulated)
        try await waitUntil { model.module(with: module.id) != nil }
        XCTAssertEqual(model.module(with: module.id)?.name, "책상 센서")
        XCTAssertEqual(model.module(with: module.id)?.roomID, room.id)
        model.stop()
    }

    // MARK: - Identity

    func testSourceIdentityNormalizesOnlyWhatReachesTheSameHub() {
        func hub(_ string: String) -> SensorSourceIdentity { .hub(URL(string: string)!) }
        XCTAssertEqual(hub("http://192.168.50.129:8787"), hub("http://192.168.50.129:8787/"))
        XCTAssertEqual(hub("http://Hub.local"), hub("http://hub.local:80"))
        XCTAssertEqual(hub("https://hub.local/"), hub("https://hub.local:443"))
        XCTAssertNotEqual(hub("http://192.168.50.129:8787"), hub("http://192.168.50.130:8787"))
        XCTAssertNotEqual(hub("http://hub.local:8787"), hub("http://hub.local:8788"))
        XCTAssertNotEqual(hub("http://hub.local"), hub("https://hub.local"))
        XCTAssertNotEqual(hub("http://hub.local"), .simulated)
        XCTAssertEqual(DataSourceFactory.identity(mode: .mock, liveBaseURLString: "http://hub.local"), .simulated)
        XCTAssertEqual(
            DataSourceFactory.identity(mode: .live, liveBaseURLString: " not a url "),
            hub(PogoAPIEndpoint.defaultBaseURLString),
            "an unusable address falls back to the default hub, as the data source does"
        )
        XCTAssertNotEqual(SensorSourceIdentity.unique(), SensorSourceIdentity.unique())
    }

    func testDataWaitDistinguishesConnectingUnreachableAndNoModules() {
        let empty = HomeSnapshot(timestamp: Date(), rooms: [], modules: [])
        XCTAssertEqual(HomeHealthEvaluator.dataWait(snapshot: empty, connectionStatus: .idle), .connecting)
        XCTAssertEqual(HomeHealthEvaluator.dataWait(snapshot: empty, connectionStatus: .connecting), .connecting)
        XCTAssertEqual(HomeHealthEvaluator.dataWait(snapshot: empty, connectionStatus: .failed("x")), .unreachable)
        XCTAssertEqual(HomeHealthEvaluator.dataWait(snapshot: empty, connectionStatus: .reconnecting(attempt: 2)), .unreachable)
        XCTAssertEqual(HomeHealthEvaluator.dataWait(snapshot: empty, connectionStatus: .connected), .noModulesYet)
        XCTAssertNil(HomeHealthEvaluator.dataWait(snapshot: MockSensorFixtures.previewSnapshot, connectionStatus: .failed("x")))
    }
}

/// A data source the test drives by hand, whose `currentSnapshot()` (the periodic GET) waits until
/// the test releases it — to land a result after the source was already replaced.
@MainActor
private final class GatedDataSource: SensorDataSource {
    private let initial: HomeSnapshot?
    private let status: DataSourceConnectionStatus
    let periodicRefreshInterval: Double?
    private(set) var updatesContinuation: AsyncStream<HomeSnapshot>.Continuation?
    private(set) var statusContinuation: AsyncStream<DataSourceConnectionStatus>.Continuation?
    private(set) var updatesCallCount = 0
    private var pendingFetch: CheckedContinuation<HomeSnapshot, Error>?

    init(initial: HomeSnapshot?, status: DataSourceConnectionStatus = .connected, periodicRefreshInterval: Double? = nil) {
        self.initial = initial
        self.status = status
        self.periodicRefreshInterval = periodicRefreshInterval
    }

    var hasPendingFetch: Bool { pendingFetch != nil }

    func releaseFetch(with snapshot: HomeSnapshot) {
        pendingFetch?.resume(returning: snapshot)
        pendingFetch = nil
    }

    func currentSnapshot() async throws -> HomeSnapshot {
        try await withCheckedThrowingContinuation { pendingFetch = $0 }
    }

    func updates() -> AsyncStream<HomeSnapshot> {
        updatesCallCount += 1
        return AsyncStream { continuation in
            updatesContinuation = continuation
            if let initial { continuation.yield(initial) }
        }
    }

    func connectionStatusUpdates() -> AsyncStream<DataSourceConnectionStatus> {
        AsyncStream { continuation in
            statusContinuation = continuation
            continuation.yield(status)
        }
    }
}
